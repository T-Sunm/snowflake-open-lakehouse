# DuckDB đọc và ghi Iceberg qua Horizon Catalog

Chạy từ thư mục gốc của repo. Runbook này dùng DuckDB làm engine bên ngoài: đọc Silver và Gold rồi đối chiếu với Snowflake, sau đó ghi vào bảng `SANDBOX.DUCKDB_NOTES` và để Snowflake đọc lại. Kết quả cho thấy hai engine dùng chung một bảng Iceberg trên S3, không có bản sao dữ liệu và không có pipeline export.

Điều kiện: đã làm xong `horizon-access.md` (có role `AQ_EXTERNAL`, user `AQ_DUCKDB`, bảng `SANDBOX.DUCKDB_NOTES`, và `HORIZON_PAT` trong `.env`; `scripts/check_horizon.py` ra 13 bảng) và pipeline `uv run wap/run.py` đã chạy xong. Phần DuckDB chạy bằng terminal với `uv`, phần đối chiếu chạy trong Snowsight.

## Cài DuckDB

Bảng của project là Iceberg v3, nên DuckDB phải từ **1.5.3 trở lên**.

```bash
uv add duckdb
uv run python -c "import duckdb; print(duckdb.__version__)"
```

Lệnh đầu thêm DuckDB vào `pyproject.toml` và `uv.lock` (commit cả hai). Phiên bản dùng trong runbook là `2.0.0`.

Script DuckDB nằm trong folder `duckdb/`. Đừng đặt file nào tên `duckdb.py` ở đó: Python ưu tiên thư mục chứa script, nên file đó sẽ che mất thư viện `duckdb` thật.

## Cách script kết nối

Cả hai script (`duckdb/read.py`, `duckdb/write.py`) kết nối giống nhau, riêng `write.py` có thêm một tùy chọn ở mục "Ghi vào SANDBOX":

1. Đổi PAT trong `.env` lấy một access token ngắn hạn, giới hạn ở role `AQ_EXTERNAL`.
2. Đưa token cho DuckDB dưới dạng secret kiểu `iceberg`.
3. `ATTACH` catalog với tên `lake`:

```sql
ATTACH 'AQ_LAKEHOUSE' AS lake (
    TYPE iceberg,
    SECRET horizon_secret,
    URI 'https://<account-identifier>.snowflakecomputing.com/polaris/api/catalog',
    ACCESS_DELEGATION_MODE 'vended_credentials'
);
```

Tên cần attach là **tên database** (`AQ_LAKEHOUSE`, viết hoa). `ACCESS_DELEGATION_MODE 'vended_credentials'` bảo DuckDB xin Horizon khóa S3 tạm thời cho từng bảng. Sau khi attach, bảng được gọi là `lake.<schema>.<bảng>`, ví dụ `lake.SILVER.FACT_AQI`. Script không in PAT hay token ra màn hình.

## Đọc Silver và Gold

```bash
uv run duckdb/read.py
```

Script chạy bốn truy vấn đọc. Kết quả đúng:

| Khối | Nội dung | Kết quả |
| --- | --- | --- |
| A | Số dòng `SILVER.FACT_AQI` | `2117` |
| B | Ba thay đổi CDC | Hai dòng: `320` với `aqi 275`, và `2118`. Không có `434` |
| C | Tổng `record_count` của `GOLD.AQI_CITY_RANKING` | `2117` |
| D | Xếp hạng thành phố tháng 1/2021 | Xem bên dưới |

Khối D phải ra 11 thành phố, hạng từ 1 đến 9, trong đó Đà Nẵng và Nha Trang không có hạng và đứng cuối:

| `CITY_NAME` | `avg_aqi` | `AQI_RANK` |
| --- | --- | --- |
| Cao Bang | 204.7 | 1 |
| Bac Ninh | 151.7 | 2 |
| Ha Noi | 150.2 | 3 |
| Lao Cai | 129.6 | 4 |
| Ho Chi Minh City | 101.4 | 5 |
| Ha Long | 46.2 | 6 |
| Thua Thien Hue | 34.0 | 7 |
| Gia Lai | 30.2 | 8 |
| Quang Ninh | 22.0 | 9 |
| Da Nang | NULL | NULL |
| Nha Trang | NULL | NULL |

### Đối chiếu với Snowflake

Chạy trong Snowsight và so với khối D:

```sql
USE ROLE openflow_admin;
SELECT city_name, ROUND(avg_aqi, 1) AS avg_aqi, aqi_rank, days_observed
FROM AQ_LAKEHOUSE.GOLD.AQI_CITY_RANKING
WHERE year = 2021 AND month = 1
ORDER BY aqi_rank NULLS LAST, city_name;
```

Kết quả phải giống từng dòng: cùng thành phố, cùng trung bình, cùng hạng, `days_observed = 9`. Nếu khối A đến C cũng khớp với `2117` và hai dòng CDC thì phía đọc xong.

Nếu DuckDB báo `403 Authorization failed` khi đọc `SILVER.FACT_AQI` hoặc `SILVER.DIM_STATION`, xem mục "Clone, vended credentials và schema SILVER_CANDIDATE" trong `horizon-access.md`.

## Ghi vào SANDBOX

```bash
uv run duckdb/write.py
```

Script thao tác trên bảng `SANDBOX.DUCKDB_NOTES` (cột `note_id`, `note`, `written_by`, `written_at`) và in bảng sau mỗi bước:

| Bước | Thao tác | Bảng sau bước |
| --- | --- | --- |
| 0 | `DELETE FROM` (để chạy lại được nhiều lần) | rỗng |
| 1 | `INSERT` 3 dòng | 3 dòng |
| 2 | `UPDATE` dòng 2 thành `second note, edited by DuckDB` | 3 dòng, dòng 2 đã sửa |
| 3 | `DELETE` dòng 3 | 2 dòng |

### Tùy chọn `DISABLE_MULTI_TABLE_COMMIT`

`ATTACH` trong `write.py` có thêm `DISABLE_MULTI_TABLE_COMMIT true`:

```sql
ATTACH 'AQ_LAKEHOUSE' AS lake (
    TYPE iceberg,
    SECRET horizon_secret,
    URI 'https://<account-identifier>.snowflakecomputing.com/polaris/api/catalog',
    ACCESS_DELEGATION_MODE 'vended_credentials',
    DISABLE_MULTI_TABLE_COMMIT true
);
```

Mặc định DuckDB commit qua endpoint "commit nhiều bảng cùng lúc" của Iceberg REST (`commitTransaction`). Tài liệu DuckDB mô tả tùy chọn này là để tắt endpoint đó, dành cho catalog từ chối nó ([iceberg_options](https://duckdb.org/docs/2.0/core_extensions/iceberg/iceberg_options.html): *"Disables the multi-table transactions/commit endpoint. Enable for catalogs that reject this endpoint."*). Tài liệu Snowflake về Horizon IRC ghi trong mục Limitations rằng `commitTransaction` không được hỗ trợ ([Horizon IRC](https://docs.snowflake.com/en/user-guide/externally-managed-iceberg-tables-access-horizon-irc)). Lưu ý trang đó nói về bảng quản lý ngoài; trang về engine bên ngoài đọc bảng Snowflake-managed ([access via external engine](https://docs.snowflake.com/en/user-guide/tables-iceberg-access-using-external-query-engine-snowflake-horizon)) không nhắc `commitTransaction`.

Quan sát trong lúc làm tutorial: khi chưa có tùy chọn này, `INSERT` thất bại ở bước commit với `403 Authorization failed`, dù role đã có đủ quyền `SELECT`, `INSERT`, `UPDATE`, `DELETE`, `TRUNCATE` trên bảng. Bật tùy chọn thì chạy được. Snowflake không giải thích mã `403` này là do multi-table commit, nên đây là quan sát chứ không phải điều tài liệu xác nhận.

### Lỗi `409 CommitConflict` khi ghi

Nếu một lệnh ghi báo `CommitConflictException` ("because it was concurrently modified"), đó là cơ chế *optimistic concurrency* của Iceberg: mỗi lần commit, DuckDB gửi kèm điều kiện "snapshot hiện tại vẫn là snapshot tôi đã đọc", và catalog trả `409` nếu bảng đã sang snapshot khác. DuckDB không tự thử lại `UPDATE` và `MERGE` khi gặp `409` ([issue #1162](https://github.com/duckdb/duckdb-iceberg/issues/1162)), nên lỗi hiện thẳng ra. Lỗi này xuất hiện một lần khi làm tutorial và không tái hiện lại được; chạy lại script là đủ.

### Đối chiếu với Snowflake

```sql
USE ROLE openflow_admin;
SELECT * FROM AQ_LAKEHOUSE.SANDBOX.DUCKDB_NOTES ORDER BY note_id;
```

Kết quả đúng là 2 dòng:

| `NOTE_ID` | `NOTE` | `WRITTEN_BY` |
| --- | --- | --- |
| 1 | `first note from DuckDB` | `duckdb` |
| 2 | `second note, edited by DuckDB` | `duckdb` |

Cột `WRITTEN_AT` là thời điểm DuckDB ghi, theo giờ máy của bạn.

## Thử ghi vào Silver

Role `AQ_EXTERNAL` chỉ có `SELECT` trên Silver. Để thấy điều đó trong thực tế, thêm cờ `--try-silver`:

```bash
uv run duckdb/write.py --try-silver
```

Script chạy lại các bước trên, rồi thử `INSERT INTO lake.SILVER.DIM_CITY ...`. Kết quả đúng là dòng cuối:

```
Refused, as expected: HTTP Error: HTTP PUT error uploading to 's3://.../silver/dim_city.../data/....parquet' (HTTP 403 Forbidden)
```

Lệnh bị từ chối ở bước tải file Parquet lên S3: khóa S3 tạm thời mà Horizon cấp cho role chỉ có `SELECT` là khóa chỉ đọc, nên DuckDB không ghi được file dữ liệu và không đi tới bước commit. Đây là suy ra từ nội dung lỗi; tài liệu Snowflake không mô tả cơ chế này. Nếu bạn thấy dòng `!! The write SUCCEEDED`, dừng lại: `SILVER.DIM_CITY` có thêm một dòng trùng và quyền của role đang sai.

Chưa thử ghi bằng DuckDB vào bảng v3 với thao tác khác ngoài `INSERT`, `UPDATE`, `DELETE`.

Bước này hoàn thành khi khối A đến D của `read.py` khớp Snowflake và Snowflake đọc lại đúng 2 dòng của `DUCKDB_NOTES`.