#!/bin/bash
# Backup DB của stack hira2: dump cục bộ + đẩy offsite lên R2 bucket PRIVATE.
#
# Đích PHẢI là một bucket riêng, KHÔNG phải `hira-uploads`. Bucket uploads được map ra
# CDN files.hira.vn nên mọi object trong đó đều tải được công khai — đó chính là cách
# bản dump production từng nằm trên Internet không cần xác thực. Điều kiện đi kèm:
# `endpoint` trong rclone.conf KHÔNG được kèm path (kèm path thì r2:<bucket> bị hiểu
# thành prefix bên trong bucket ở path đó).
#
# Cài:
#   scp deploy/hira2/backup-hira2.sh saucevn@<vps>:~/bin/ && chmod +x ~/bin/backup-hira2.sh
#   (crontab) 15 3 * * * /home/saucevn/bin/backup-hira2.sh >> /home/saucevn/backups/backup.log 2>&1
set -uo pipefail

BACKUP_DIR="${BACKUP_DIR:-$HOME/backups}"
CONTAINER="${CONTAINER:-hira2-hira-db-1}"
DB_USER="${DB_USER:-multica}"
DB_NAME="${DB_NAME:-multica}"
R2_REMOTE="${R2_REMOTE:-r2:hira-backups}"
LOCAL_KEEP_DAYS="${LOCAL_KEEP_DAYS:-7}"
REMOTE_KEEP_DAYS="${REMOTE_KEEP_DAYS:-30}"
MIN_BYTES="${MIN_BYTES:-1000000}"

log() { echo "$(date -Is) $*"; }

mkdir -p "$BACKUP_DIR"
chmod 700 "$BACKUP_DIR"
FILE="$BACKUP_DIR/hira2-db-$(date +%Y%m%d-%H%M%S).sql.gz"

# --- 1. Dump ---------------------------------------------------------------
# Ghi ra .partial trước: dump chết giữa chừng sẽ KHÔNG để lại file .sql.gz trông
# như hợp lệ, và retention sẽ không nhầm nó là bản tốt.
if ! docker exec "$CONTAINER" pg_dump -U "$DB_USER" -d "$DB_NAME" --clean --if-exists \
	| gzip -9 > "$FILE.partial"; then
	log "FATAL: pg_dump thất bại"
	rm -f "$FILE.partial"
	exit 1
fi

SIZE=$(stat -c %s "$FILE.partial")
if [ "$SIZE" -lt "$MIN_BYTES" ]; then
	log "FATAL: dump chỉ $SIZE bytes (ngưỡng $MIN_BYTES) — giữ nguyên bản cũ, xoá bản lỗi"
	rm -f "$FILE.partial"
	exit 1
fi

if ! gzip -t "$FILE.partial" 2>/dev/null; then
	log "FATAL: file gzip hỏng"
	rm -f "$FILE.partial"
	exit 1
fi

# "Có kích thước" chưa đủ — kiểm tra đúng là dump Postgres. Một file gzip 14 MB
# toàn thông báo lỗi vẫn qua được hai bước trên.
#
# Lấy phần đầu qua command substitution chứ KHÔNG chấm trực tiếp vào `if`: `head`
# đóng pipe sớm làm `gzip` nhận SIGPIPE, và với `pipefail` thì cả pipeline bị coi
# là thất bại — bài kiểm tra sẽ luôn fail dù dump hoàn toàn tốt.
HEAD50=$(gzip -cd "$FILE.partial" 2>/dev/null | head -50 || true)
if ! printf '%s' "$HEAD50" | grep -q "PostgreSQL database dump"; then
	log "FATAL: nội dung không giống dump Postgres"
	rm -f "$FILE.partial"
	exit 1
fi

mv "$FILE.partial" "$FILE"
chmod 600 "$FILE"
log "dump OK: $FILE ($SIZE bytes)"

# --- 2. Retention cục bộ ---------------------------------------------------
find "$BACKUP_DIR" -name 'hira2-db-*.sql.gz' -mtime "+$LOCAL_KEEP_DAYS" -delete

# --- 3. Offsite ------------------------------------------------------------
# Backup chỉ nằm trên chính máy đang chạy DB thì không phải backup. Nếu bước này
# hỏng, script kết thúc với exit 1 để cron log thấy được — bản dump cục bộ vẫn giữ.
if ! command -v rclone >/dev/null 2>&1; then
	log "WARN: chưa có rclone — offsite BỊ TẮT, chỉ có bản cục bộ"
	exit 1
fi

if ! rclone lsd "$R2_REMOTE" >/dev/null 2>&1; then
	log "WARN: không truy cập được $R2_REMOTE — offsite BỊ TẮT, chỉ có bản cục bộ."
	log "      Cần bucket private + API token có quyền ghi lên nó. KHÔNG dùng hira-uploads."
	exit 1
fi

if ! rclone copy "$FILE" "$R2_REMOTE"; then
	log "WARN: upload lên $R2_REMOTE thất bại — chỉ có bản cục bộ"
	exit 1
fi

rclone delete "$R2_REMOTE" --min-age "${REMOTE_KEEP_DAYS}d" --include 'hira2-db-*'
log "offsite OK: $R2_REMOTE ($(basename "$FILE"))"
