# PostgreSQL local

Chạy từ thư mục gốc của repo. Các lệnh dưới đây chuẩn bị PostgreSQL nguồn và nạp dữ liệu trước khi tạo connector Openflow.

## Khởi động PostgreSQL

```bash
docker compose up -d
docker compose ps
```

Chờ cột `STATUS` hiện `healthy` rồi mới chạy SQL. Các lệnh `psql` chạy trong container nên không cần nhập mật khẩu PostgreSQL.

## Tạo bảng

```bash
docker exec -it aq-postgres psql -U postgres -d airquality -f /workspace/postgres/01_schema.sql
```

`psql` sẽ in các kết quả như `CREATE SCHEMA`, `CREATE TABLE` và `CREATE INDEX`. Bước này hoàn thành khi lệnh thoát mà không báo lỗi.

## Nạp dữ liệu Kaggle

CSV ở `postgres/data/` và đã được Compose mount vào container tại `/workspace/postgres/data/`:

```bash
docker exec -it aq-postgres psql -U postgres -d airquality -v csv_path=/workspace/postgres/data/historical_air_quality_2021_en.csv -f /workspace/postgres/02_load_kaggle.sql
```

Lần nạp đã chạy thành công với kết quả:

| `csv_rows` | `skipped_no_id_or_time` | `stations` | `measurements` |
| ---: | ---: | ---: | ---: |
| 3415 | 793 | 23 | 2117 |

Kiểm tra CSV cho thấy 793 dòng bị bỏ qua đều rỗng mã trạm và thời gian; 23 mã trạm có dữ liệu đều đã vào bảng `stations`. Trong 2.622 dòng có dữ liệu, các cặp trạm/thời điểm trùng được gộp còn 2.117 lần đo.

## Chuẩn bị logical replication

Khi thiết lập database mới, tạo tài khoản Openflow với mật khẩu local `replicator123`:

```bash
docker exec -it aq-postgres psql -U postgres -d airquality -v replicator_password='replicator123' -f /workspace/postgres/03_replication.sql
```

Đã kiểm tra: `wal_level = logical`, `max_replication_slots = 10`, `max_wal_senders = 10`; publication `openflow_aq_pub` có `measurements` và `stations`; cả hai bảng có `has_primary_key = t`.

Script tạo role và publication, nên chỉ chạy một lần trên cùng database. Nếu cần đổi mật khẩu của role đã tồn tại:

```bash
docker exec -it aq-postgres psql -U postgres -d airquality -c "ALTER ROLE openflow_replicator WITH PASSWORD 'replicator123';"
```

Chỉ dùng mật khẩu mới khi lệnh đổi mật khẩu trả về `ALTER ROLE`.

Dừng tại đây. Chỉ chạy `04_cdc_insert.sql`, `05_cdc_update.sql` và `06_cdc_delete.sql` sau khi connector đã hoàn tất initial snapshot.
