# Gold trên Iceberg và pipeline một lệnh

Chạy từ thư mục gốc của repo. Runbook này tạo năm bảng Gold dạng Iceberg, nạp chúng từ Silver đã được kiểm tra, rồi chạy cả chu trình Write, Audit, Publish, Gold bằng **một lệnh**.

Điều kiện: đã làm xong `silver-candidate.md` và `silver-audit-publish.md`.

## Tạo năm bảng Gold

Mở `snowflake/04_gold_schema.sql` trong Snowsight và chạy toàn bộ. File dùng `CREATE ICEBERG TABLE IF NOT EXISTS`, nên chạy lại không xóa dữ liệu. Bảng nhận `EXTERNAL_VOLUME` và phiên bản Iceberg (v3) từ thiết lập mặc định của database, vì thế file chỉ khai báo `CATALOG = 'SNOWFLAKE'` và `BASE_LOCATION`.

| Bảng | Mỗi dòng là | Vị trí trên S3 (`BASE_LOCATION`) |
| --- | --- | --- |
| `AQI_DAILY_SUMMARY` | Một thành phố trong một ngày | `gold/aqi_daily_summary` |
| `AQI_CITY_RANKING` | Một thành phố trong một tháng, có xếp hạng | `gold/aqi_city_ranking` |
| `STATION_SUMMARY` | Một trạm trong một tháng, có xếp hạng trong thành phố | `gold/station_summary` |
| `AQI_HOURLY_PATTERN` | Một thành phố theo một giờ trong ngày | `gold/aqi_hourly_pattern` |
| `AQI_SEASONAL_SUMMARY` | Một thành phố theo một mùa | `gold/aqi_seasonal_summary` |

Cột `city_slug`, `station_id`, `full_date` dùng cùng tên với Silver. Trong `AQI_CITY_RANKING`, `record_count` là số lượt đo, còn `days_observed` là số ngày có dữ liệu. Trong `AQI_SEASONAL_SUMMARY`, `first_date` và `last_date` cho biết dữ liệu phủ được bao nhiêu phần của mùa đó.

Câu cuối của file là `SHOW ICEBERG TABLES IN SCHEMA AQ_LAKEHOUSE.GOLD;`. Kết quả phải liệt kê **5 bảng** Iceberg. Các bảng còn trống.

## Nạp Gold từ Silver

`wap/04_load_gold.sql` nạp cả năm bảng, mỗi bảng bằng một `INSERT OVERWRITE`. Mỗi bảng được thay trong một câu lệnh nên người đọc thấy bản tổng hợp cũ hoặc bản mới, không bao giờ thấy bảng dựng dở.

Quy tắc tính toán:

- Xếp hạng tính theo từng tháng (`PARTITION BY year, month`), dùng `DENSE_RANK`.
- Trung bình `NULL` thì **không có hạng** và xếp cuối. Nhờ vậy thành phố không có AQI nào (Nha Trang) không bị xếp là ô nhiễm nhất.
- Xếp hạng thành phố theo tháng lấy trung bình của các trung bình theo ngày, để mỗi ngày có trọng số như nhau dù có bao nhiêu trạm báo cáo.
- Bảng theo mùa gom theo `season_year`, nên mùa khô qua năm mới nằm trọn trong một dòng.
- Mức ô nhiễm của một ngày lấy từ AQI lớn nhất trong ngày (`AQI_CATEGORY(MAX(aqi))`); AQI `NULL` không có mức.

## Chạy cả chu trình bằng một lệnh

```bash
uv run wap/run.py
```

Script đọc `.env`, kết nối bằng key pair và chạy bốn bước theo thứ tự:

| Bước | File | Việc làm |
| --- | --- | --- |
| 1/4 WRITE | `wap/01_write_candidate.sql` | Dựng Silver Candidate từ Bronze |
| 2/4 AUDIT | `wap/02_audit.py` | Soda kiểm tra candidate |
| 3/4 PUBLISH | `wap/03_publish.sql` | Chỉ chạy nếu Audit không fail |
| 4/4 GOLD | `wap/04_load_gold.sql` | Nạp năm bảng Gold từ Silver mới |

Với mỗi file `.sql`, script chỉ chạy phần trước dòng bắt đầu bằng `-- CHECKS`; phần sau là các câu kiểm tra thủ công.

Kết quả đúng: bước Audit in 22 dòng `[PASS]`, và dòng cuối là:

```
== Done. Silver and Gold are updated.
```

Nếu Audit fail, Publish và Gold **không chạy**, Silver hiện tại giữ nguyên, và script thoát với mã `1`. Mã thoát: `0` hoàn thành, `1` Audit fail (chưa publish gì), `2` lỗi.

Khi Bronze có thay đổi mới, chỉ cần chạy lại đúng lệnh trên. Candidate luôn dựng lại từ đầu, `MERGE` chỉ áp những gì đã đổi.

## Kiểm tra kết quả

Chạy từng câu trong Snowsight.

**A. Mọi bảng tổng hợp phản ánh đủ dữ liệu Silver.** Tổng `record_count` của cả năm bảng Gold phải bằng số dòng của `SILVER.FACT_AQI`:

```sql
SELECT
    (SELECT COUNT(*)          FROM AQ_LAKEHOUSE.SILVER.FACT_AQI)                  AS silver_rows,
    (SELECT SUM(record_count) FROM AQ_LAKEHOUSE.GOLD.AQI_DAILY_SUMMARY)           AS daily,
    (SELECT SUM(record_count) FROM AQ_LAKEHOUSE.GOLD.AQI_CITY_RANKING)            AS city_ranking,
    (SELECT SUM(record_count) FROM AQ_LAKEHOUSE.GOLD.STATION_SUMMARY)             AS station_summary,
    (SELECT SUM(record_count) FROM AQ_LAKEHOUSE.GOLD.AQI_HOURLY_PATTERN)          AS hourly,
    (SELECT SUM(record_count) FROM AQ_LAKEHOUSE.GOLD.AQI_SEASONAL_SUMMARY)        AS seasonal;
```

Kết quả: sáu số đều là **2117**.

**B. Xếp hạng tháng 1/2021.** Câu truy vấn ở mục B cuối `wap/04_load_gold.sql`: mỗi tháng xếp hạng thành phố từ 1, còn Nha Trang có `aqi_rank` rỗng và đứng cuối danh sách.

**C. Mùa không bị cắt ở năm mới.** Mục C cuối `wap/04_load_gold.sql`, với Hà Nội, phải cho ba dòng:

| `season_year` | `season` | Ý nghĩa |
| --- | --- | --- |
| 2020 | Dry | Mùa khô bắt đầu năm 2020, dữ liệu phủ tháng 1 đến tháng 4/2021 |
| 2021 | Rainy | Mùa mưa 2021 |
| 2021 | Dry | Mùa khô bắt đầu tháng 11/2021, dữ liệu mới có tháng 11 |

**D. Mẫu theo giờ.** Mục D, với Hà Nội: một dòng cho mỗi giờ có dữ liệu, cột `record_count` và `avg_aqi`.

**E. Ba thay đổi CDC và Nha Trang** (kiểm tra cuối cùng của phần 3):

```sql
SELECT
    (SELECT COUNT(*) FROM AQ_LAKEHOUSE.SILVER.FACT_AQI WHERE measurement_id = 2118)                AS has_insert,
    (SELECT COUNT(*) FROM AQ_LAKEHOUSE.SILVER.FACT_AQI WHERE measurement_id = 434)                 AS has_deleted_row,
    (SELECT aqi      FROM AQ_LAKEHOUSE.SILVER.FACT_AQI WHERE measurement_id = 320)                 AS updated_aqi,
    (SELECT COUNT(*) FROM AQ_LAKEHOUSE.GOLD.AQI_CITY_RANKING WHERE city_slug = 'nha-trang')        AS nha_trang_rows,
    (SELECT COUNT(*) FROM AQ_LAKEHOUSE.GOLD.AQI_CITY_RANKING
        WHERE city_slug = 'nha-trang' AND aqi_rank IS NOT NULL)                                    AS nha_trang_ranked;
```

Kết quả: `has_insert = 1`, `has_deleted_row = 0`, `updated_aqi = 275`, `nha_trang_rows = 11`, `nha_trang_ranked = 0`. Nha Trang có dòng trong bảng xếp hạng nhưng không có hạng nào, vì trạm này không có số đo AQI.

Bước này hoàn thành khi sáu số ở mục A đều là 2117 và mục E trả về `1, 0, 275, 11, 0`.

## Dữ liệu cần biết khi đọc Gold

Nha Trang không có AQI hay PM2.5 nào (0 trên 113 dòng). Huế, Hạ Long và Lào Cai chỉ có rất ít dữ liệu AQI. Silver giữ nguyên các dòng này, còn Gold không xếp hạng những thành phố đó ở những tháng không có trung bình.

Tiếp theo là phần Horizon Catalog và DuckDB.
