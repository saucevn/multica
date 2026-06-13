# Migration: Hira v1 → fork hiện tại (giữ data, bỏ knowledge-graph/admin)

Tài liệu vận hành để chuyển VPS production từ **Hira v1** (`saucevn/app-hira`, deploy bằng
source build, app.hira.vn) sang **fork này** (`saucevn/multica` — Multica + Việt hóa + brand
Hira, sync-friendly). Giữ toàn bộ dữ liệu người dùng; bỏ 2 subsystem v1 tự thêm
(knowledge-graph + admin) vì fork này không có.

> Đọc kèm [`../../BRANDING.md`](../../BRANDING.md) (chiến lược fork) và
> [`../../SELF_HOSTING.md`](../../SELF_HOSTING.md) (chi tiết self-host).

---

## 0. Hiểu mô hình deploy (quan trọng nhất)

`docker-compose.selfhost.yml` mặc định **PULL image dựng sẵn của upstream**
(`ghcr.io/multica-ai/multica-backend` / `-web`) — **những image này là Multica tiếng Anh,
KHÔNG chứa Việt hóa/brand Hira** (locale được biên dịch vào image lúc build).

→ **Bắt buộc deploy fork bằng `make selfhost-build`** (build from source, qua
`docker-compose.selfhost.build.yml` + `Dockerfile`/`Dockerfile.web`). Đây đúng là cách v1
đang chạy (`multica-backend:latest` / `multica-frontend:latest` build local).

---

## 1. Vì sao không adopt thẳng DB của v1

v1 và fork này **chung lineage Multica** (bảng tên số ít: `user`/`workspace`/`issue`…, PK
UUID `gen_random_uuid()`, **không có sequence**). NHƯNG lịch sử migration **không tương thích**:

- v1: 68 migration (001–049 + custom **050–054** = pgvector/knowledge/admin của app-hira).
- fork này: **152 migration (001–119)** theo đánh số upstream — khác hẳn 050+ của v1.

Trỏ backend fork này vào DB v1 → migrator thấy "050 đã áp" (nhưng là 050 của app-hira) →
**bỏ qua 050–054 của upstream** → schema thiếu → app vỡ. Vì vậy: **DB mới rỗng + copy DATA**.

---

## 2. Phân tích tương thích schema (đã đối chiếu dump v1)

Tin tốt: schema lõi gần như trùng. Khác biệt:

| Loại | Cụ thể | Xử lý |
|---|---|---|
| Cột fork mới có, v1 thiếu | `user.language` (Việt hóa dựa vào đây), `user.timezone`, + cột do ~84 migration thêm | Tự nhận **DEFAULT** khi load. `user.language` NULL → tự match `vi` qua Accept-Language ✓ |
| Cột/bảng v1 có, fork mới không | `user.is_super_admin`, `admin_audit_log`, `knowledge_*` (6 bảng) | **Bỏ** (đúng quyết định) |
| Bảng upstream mới (v1 không có) | `lark_*`, `sys_cron_executions`, … | Để rỗng |
| PK | UUID toàn bộ, không serial | Port thẳng, **không reset sequence** ✓ |

Công cụ ETL (`scripts/migrate-v1-data.sh`) copy theo **giao cột động** nên tự xử lý mọi drift
cộng dồn. Rủi ro còn lại duy nhất: fork mới thêm **cột NOT NULL không default** vào bảng chung
→ `check` mode phát hiện trước khi load.

---

## 3. Chuẩn bị (không downtime)

1. **Backup v1 ngay trước** (ngoài daily R2 đã có):
   ```bash
   docker exec multica-postgres-1 pg_dump -U multica -d multica --clean --if-exists \
     | gzip -9 > ~/backups/pre-migration-$(date +%Y%m%d-%H%M).sql.gz
   ```
2. **Checkout fork mới** vào path riêng, không đụng v1:
   ```bash
   git clone git@github-hira:saucevn/multica.git ~/hira-new && cd ~/hira-new
   git config merge.ours.driver true     # bảo vệ brand assets khi sync sau này
   ```
3. **Tạo `.env`** cho stack mới — carry-over có chọn lọc từ v1 (`~/hira/hira/.env`):

   | Giữ NGUYÊN | Sửa cho đúng | Đổi MỚI |
   |---|---|---|
   | `JWT_SECRET` (để session + PAT/daemon token không vỡ) | `MULTICA_APP_URL=https://app.hira.vn` (bỏ `:3000`/http) | `POSTGRES_PASSWORD` (bỏ `multica:multica`) |
   | `RESEND_API_KEY`, `RESEND_FROM_EMAIL=noreply@hira.vn` | `FRONTEND_ORIGIN=https://app.hira.vn` | `DATABASE_URL` (mật khẩu mới) |
   | R2: `AWS_ACCESS_KEY_ID/SECRET`, `AWS_ENDPOINT_URL`, `S3_BUCKET=hira-uploads`, `S3_REGION=auto` | `CORS_ALLOWED_ORIGINS=https://app.hira.vn` (bỏ admin nếu không dùng) | (đặt port tạm để chạy cạnh v1, xem bước 4) |
   | `CLOUDFRONT_DOMAIN=files.hira.vn` | bỏ `GOOGLE_REDIRECT_URI` localhost stale | |
   | | `APP_ENV=production` | |

   AI keys (`ANTHROPIC_API_KEY`…) chỉ cần nếu dùng knowledge-extraction — **đang bỏ KG nên không cần**.

---

## 4. Dựng stack fork mới song song v1 (DB mới rỗng)

Chạy cạnh v1 bằng **project name + port khác** để không đụng nhau (RAM VPS chỉ ~571MB free —
nếu build Next.js OOM, tạm dừng arkon workers hoặc thêm swap):

```bash
cd ~/hira-new
# ví dụ: backend 8081, web 3001, postgres 5433  (đặt trong .env: PORT/FRONTEND_PORT/POSTGRES_PORT)
COMPOSE_PROJECT_NAME=hira2 make selfhost-build
```

Stack mới khởi động → **152 migration chạy sạch** trên DB rỗng. Kiểm tra:
```bash
curl -s localhost:8081/health        # {"status":"ok"}
docker exec hira2-postgres-1 psql -U multica -d multica -c "SELECT count(*) FROM schema_migrations;"  # 152
```

---

## 5. Copy dữ liệu (ETL)

`scripts/migrate-v1-data.sh` đã có trong repo. Cần cả 2 DB reachable.

```bash
export OLD_URL='postgres://multica:multica@127.0.0.1:5432/multica'        # v1 (mật khẩu cũ)
export NEW_URL='postgres://multica:<new-pass>@127.0.0.1:5433/multica'     # fork mới

scripts/migrate-v1-data.sh check    # 1) xem cột bị drop + FLAG cột NOT NULL-no-default (breaker)
scripts/migrate-v1-data.sh run      # 2) copy (1 transaction, tắt FK trigger khi load)
scripts/migrate-v1-data.sh verify   # 3) đối chiếu row count old vs new
```

Kỳ vọng `verify`: `user` 14 · `workspace` 10 · `issue` 546 · `comment` 1062 · `attachment` 47.

Nếu `check` báo breaker (cột NOT NULL-no-default fork mới thêm mà v1 không có) → dừng, backfill
cột đó (hoặc thêm default) rồi mới `run`.

> Không copy: `knowledge_*`, `admin_audit_log`, `verification_code`, `schema_migrations` (giữ của fork mới).
> Attachment ở **R2** (cùng bucket/creds) → 47 row trỏ thẳng object cũ, **không cần move file**.

---

## 6. Verify trên port tạm

- Mở `http://<vps>:3001` (hoặc tunnel) → login user cũ bằng **email + mã Resend**.
- Duyệt workspace/issue/comment; mở 1 attachment (load từ `files.hira.vn`).
- Đổi ngôn ngữ sang **Tiếng Việt** trong Settings → UI Việt + brand indigo.

---

## 7. Cutover (đổi Caddy)

Sửa `/etc/caddy/Caddyfile`: `app.hira.vn` và `api.hira.vn` reverse_proxy sang **port stack mới**
(8081/3001). Rồi:
```bash
sudo caddy validate --config /etc/caddy/Caddyfile && sudo systemctl reload caddy
```
Dừng v1 (giữ lại, **không xóa**) để nhường tài nguyên:
```bash
cd ~/hira/hira && docker compose -f docker-compose.selfhost.yml stop
```
(Tùy chọn: đổi port stack mới về 8080/3000 cho gọn, rồi sửa Caddy lại.)

**Rollback:** trỏ Caddy về port v1 (8080/3000) + `docker compose ... start` v1. DB v1 nguyên vẹn.

---

## 8. Hardening (làm ngay sau cutover)

Báo cáo khảo sát VPS phát hiện các vấn đề **cần xử lý**:

- **Bind tất cả port về `127.0.0.1`** (v1 đang phơi `0.0.0.0` cho backend/web/**Postgres**). Trong
  compose dùng `127.0.0.1:8080:8080` thay vì `8080:8080`. Caddy là cổng public duy nhất.
- **Đổi mật khẩu Postgres** (v1 dùng `multica:multica`) — đã làm ở bước 3.
- **Rotate** `JWT_SECRET` (theo kế hoạch, sẽ buộc login lại), `RESEND_API_KEY`, R2 keys — vì
  từng nằm sau port public.
- **Xóa token Meta/Facebook plaintext trong crontab** (`crontab -e`, job `28 4 *` gọi
  `/tmp/enable_campaigns_midnight.py`) — rò rỉ credential, không liên quan Hira.
- Copy cron **backup** (`~/bin/backup.sh` → R2 `r2:hira-backups`) sang trỏ DB/stack mới.

---

## 9. Sau migration — duy trì & cập nhật

Từ giờ fork này cập nhật upstream an toàn bằng `scripts/sync-upstream.sh` (xem BRANDING.md).
Mỗi lần có release mới: sync → dịch chuỗi `vi` mới (parity net chỉ ra) → rebuild image
(`make selfhost-build`) → redeploy. **Không** quay lại mô hình refactor-nặng như v1.
