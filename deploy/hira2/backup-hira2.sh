#!/bin/bash
# Backup mọi database trong container Postgres dùng chung: dump cục bộ + đẩy offsite lên R2.
#
# Container `hira2-hira-db-1` phục vụ NHIỀU database — `multica` (stack hira2) và `apphira`
# (stack v1 app-hira). Chúng dùng chung một instance nhưng tách database và tách role, nên
# backup phải duyệt từng cái; dump mỗi database riêng để restore được độc lập.
#
# Đích PHẢI là bucket riêng, KHÔNG phải `hira-uploads`: bucket đó map ra CDN files.hira.vn
# nên mọi object trong nó tải được công khai — đó chính là cách bản dump production từng nằm
# trên Internet. Kèm theo: `endpoint` trong rclone.conf KHÔNG được có path.
#
# Cài:
#   scp deploy/hira2/backup-hira2.sh saucevn@<vps>:~/bin/ && chmod +x ~/bin/backup-hira2.sh
#   (crontab) 15 3 * * * /home/saucevn/bin/backup-hira2.sh >> /home/saucevn/backups/backup.log 2>&1
set -uo pipefail

BACKUP_DIR="${BACKUP_DIR:-$HOME/backups}"
CONTAINER="${CONTAINER:-hira2-hira-db-1}"
ADMIN_USER="${ADMIN_USER:-multica}"
DATABASES="${DATABASES:-multica apphira}"
R2_REMOTE="${R2_REMOTE:-r2:hira-backups}"
LOCAL_KEEP_DAYS="${LOCAL_KEEP_DAYS:-7}"
REMOTE_KEEP_DAYS="${REMOTE_KEEP_DAYS:-30}"
MIN_BYTES="${MIN_BYTES:-1000}"

log() { echo "$(date -Is) $*"; }
rc=0

mkdir -p "$BACKUP_DIR"
chmod 700 "$BACKUP_DIR"

for DB in $DATABASES; do
	if ! docker exec "$CONTAINER" psql -U "$ADMIN_USER" -d postgres -tAc \
		"SELECT 1 FROM pg_database WHERE datname='$DB'" | grep -q 1; then
		log "SKIP $DB: database chưa tồn tại"
		continue
	fi

	# Database đã tạo nhưng chưa có bảng nào (vừa CREATE DATABASE, chưa migrate) thì
	# dump chỉ vài trăm byte và sẽ trượt ngưỡng kích thước. Đó là trạng thái hợp lệ,
	# không phải lỗi — bỏ qua thay vì báo FAIL mỗi đêm.
	TABLES=$(docker exec "$CONTAINER" psql -U "$ADMIN_USER" -d "$DB" -tAc \
		"SELECT count(*) FROM information_schema.tables WHERE table_schema NOT IN ('pg_catalog','information_schema')" 2>/dev/null)
	if [ "${TABLES:-0}" -eq 0 ]; then
		log "SKIP $DB: chưa có bảng nào"
		continue
	fi

	# Reset theo TỪNG database: để sót giá trị của vòng trước sẽ so nhầm kích thước
	# dump của DB này với DB khác.
	PREV=""; PREV_SIZE=""
	FILE="$BACKUP_DIR/$DB-db-$(date +%Y%m%d-%H%M%S).sql.gz"

	# Ghi .partial trước: dump chết giữa chừng sẽ không để lại file .sql.gz trông như
	# hợp lệ để retention nhầm là bản tốt.
	if ! docker exec "$CONTAINER" pg_dump -U "$ADMIN_USER" -d "$DB" --clean --if-exists \
		| gzip -9 > "$FILE.partial"; then
		log "FAIL $DB: pg_dump lỗi"
		rm -f "$FILE.partial"; rc=1; continue
	fi

	SIZE=$(stat -c %s "$FILE.partial")

	# Ngưỡng tuyệt đối chỉ bắt được dump rỗng hẳn. Cái nguy hiểm hơn là dump BỊ CẮT
	# NGANG — vẫn vài MB, vẫn giải nén được, nhưng thiếu nửa cuối. So với bản gần nhất
	# của CHÍNH database đó bắt được cả hai, và tự thích nghi khi dữ liệu lớn dần.
	PREV=$(ls -t "$BACKUP_DIR/$DB-db-"*.sql.gz 2>/dev/null | head -1)
	FLOOR=$MIN_BYTES
	if [ -n "$PREV" ]; then
		PREV_SIZE=$(stat -c %s "$PREV")
		HALF=$((PREV_SIZE / 2))
		[ "$HALF" -gt "$FLOOR" ] && FLOOR=$HALF
	fi
	if [ "$SIZE" -lt "$FLOOR" ]; then
		log "FAIL $DB: dump $SIZE bytes < ngưỡng $FLOOR (bản trước ${PREV_SIZE:-n/a}) — giữ bản cũ"
		rm -f "$FILE.partial"; rc=1; continue
	fi

	if ! gzip -t "$FILE.partial" 2>/dev/null; then
		log "FAIL $DB: gzip hỏng"
		rm -f "$FILE.partial"; rc=1; continue
	fi

	# "Có kích thước" chưa đủ — kiểm tra đúng là dump Postgres.
	#
	# Lấy phần đầu qua command substitution chứ KHÔNG chấm thẳng vào `if`: `head` đóng
	# pipe sớm làm `gzip` nhận SIGPIPE, và với `pipefail` cả pipeline bị coi là thất bại
	# — bài kiểm tra sẽ luôn fail dù dump hoàn toàn tốt.
	HEAD50=$(gzip -cd "$FILE.partial" 2>/dev/null | head -50 || true)
	if ! printf '%s' "$HEAD50" | grep -q "PostgreSQL database dump"; then
		log "FAIL $DB: nội dung không giống dump Postgres"
		rm -f "$FILE.partial"; rc=1; continue
	fi

	mv "$FILE.partial" "$FILE"
	chmod 600 "$FILE"
	log "OK $DB: $(basename "$FILE") ($SIZE bytes)"

	find "$BACKUP_DIR" -name "$DB-db-*.sql.gz" -mtime "+$LOCAL_KEEP_DAYS" -delete

	# Backup nằm cùng máy với DB thì không phải backup. Hỏng bước này vẫn giữ bản cục bộ,
	# nhưng script thoát khác 0 để dòng log không im lặng.
	if ! command -v rclone >/dev/null 2>&1; then
		log "WARN $DB: chưa có rclone — offsite TẮT"; rc=1; continue
	fi
	if ! rclone copy "$FILE" "$R2_REMOTE" 2>/dev/null; then
		log "WARN $DB: upload $R2_REMOTE thất bại — offsite TẮT. Cần bucket PRIVATE + token"
		log "         có quyền ghi lên nó. TUYỆT ĐỐI không dùng hira-uploads (public qua CDN)."
		rc=1; continue
	fi
	rclone delete "$R2_REMOTE" --min-age "${REMOTE_KEEP_DAYS}d" --include "$DB-db-*" 2>/dev/null
	log "OK $DB: đã đẩy offsite $R2_REMOTE"
done

exit $rc
