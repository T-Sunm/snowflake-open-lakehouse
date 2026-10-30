# Silver Candidate: schema Silver và bước Write

Chạy từ thư mục gốc của repo. Runbook này tạo star schema Silver trên Iceberg, thiết lập đăng nhập cho pipeline, rồi chạy bước **Write** của Write-Audit-Publish: dựng *Silver Candidate* từ Bronze mà không đụng vào Silver hiện tại.

Điều kiện: Bronze (`AQ_LAKEHOUSE.AQ.STATIONS`, `AQ_LAKEHOUSE.AQ.MEASUREMENTS`) đã có dữ liệu, và External Volume `AQ_ICEBERG_VOL` đã kiểm tra thành công (xem `iceberg-storage.md`). Bronze lúc này có 2117 dòng đang sống, gồm ba thay đổi CDC đã thực hiện ở phần Openflow: thêm dòng 2118, sửa dòng 320 (AQI 275), xóa mềm dòng 434.

Phần Snowflake chạy trong Snowsight. Phần pipeline chạy bằng terminal, dùng `uv`.

## Tạo schema Silver

Mở `snowflake/03_silver_schema.sql` trong Snowsight và chạy toàn bộ bằng **Run all** (`Ctrl + Shift + Enter`). File an toàn khi chạy lại: bảng Silver dùng `IF NOT EXISTS`, các dimension nạp bằng `MERGE`, nên chạy lần nữa không xóa hay nhân đôi dữ liệu.

File tạo:

| Schema | Nội dung |
| --- | --- |
| `SILVER` | `DIM_DATE`, `DIM_TIME`, `DIM_CITY`, `DIM_STATION`, `FACT_AQI` (bảng Iceberg), hàm `AQI_CATEGORY` |
| `GOLD` | Schema trống, dùng ở runbook Gold |
| `CONTROL` | `CITY_MAP`, `STATION_CITY_OVERRIDE`, `CITY_REFERENCE`, `DQ_RESULTS`, hai sequence tạo surrogate key |

Quy tắc mô hình hóa:

- Thành phố của một trạm lấy từ URL của trạm (`aqicn.org/city/vietnam/<slug>/...`), vì cột `location` trong CSV là tọa độ chứ không phải tên thành phố. Trạm `13252` có URL không khớp thành phố nên được gán thẳng vào `cao-bang` qua `CONTROL.STATION_CITY_OVERRIDE`.
- `DIM_STATION` khóa theo `station_id`, thành phố là thuộc tính của trạm.
- `DIM_DATE` có thêm `season_year`, để mùa khô kéo dài qua năm mới (tháng 11 đến tháng 4) vẫn thuộc một mùa. Mùa khô là tháng 11 đến tháng 4, mùa mưa là tháng 5 đến tháng 10.
- `FACT_AQI` giữ `measurement_id` để Silver có thể `MERGE` với Bronze.
- `AQI_CATEGORY(NULL)` trả về `NULL`: không có AQI thì không có mức ô nhiễm.

Cuối file có ba câu kiểm tra. Chạy từng câu (bôi đen rồi `Ctrl + Enter`):

1. Số dòng các dimension phải là:

   | `dim_date` | `dim_time` | `dim_city` |
   | --- | --- | --- |
   | 4383 | 24 | 11 |

2. Câu tìm trạm chưa xác định được thành phố phải trả về **0 dòng**.
3. Số trạm theo thành phố: `ha-noi` 11, `bac-ninh` 3, chín thành phố còn lại mỗi nơi 1 trạm, tổng 23.

`DIM_STATION` và `FACT_AQI` còn trống ở bước này. Bước Write sẽ điền vào candidate, bước Publish mới đưa sang Silver.

## Đăng nhập cho pipeline

Người dùng đăng nhập Snowsight bằng mật khẩu và mã TOTP từ app Authenticator. Pipeline chạy không có người ngồi nhập mã, nên dùng **key pair**: Snowflake giữ khóa công khai, máy bạn giữ khóa riêng.

**1. Chặn khóa riêng bị commit.** Thêm vào `.gitignore` (nếu chưa có):

```
.keys/
.env
```

**2. Tạo cặp khóa:**

```bash
uv run --with cryptography python scripts/make_keypair.py <snowflake-user>
```

`<snowflake-user>` là tên user Snowflake của bạn, ví dụ `TSUNM`. Script ghi khóa riêng vào `.keys/snowflake_rsa_key.p8` và in ra một câu lệnh `ALTER USER ... SET RSA_PUBLIC_KEY = '...'`. Script không ghi đè khóa đã có.

**3. Đăng ký khóa công khai.** Trong Snowsight, đổi role thành `SECURITYADMIN`, rồi chạy câu `ALTER USER` vừa in ra. Role `SECURITYADMIN` là role quản lý user, nên lệnh `ALTER USER` được chạy bằng role này.

**4. Khai báo biến môi trường.** Tạo `.env` ở thư mục gốc (đã nằm trong `.gitignore`), và tạo `.env.example` với giá trị để trống để người khác biết cần điền gì:

```
SNOWFLAKE_ACCOUNT=<account-identifier>
SNOWFLAKE_USER=<snowflake-user>
SNOWFLAKE_PRIVATE_KEY_PATH=.keys/snowflake_rsa_key.p8
SNOWFLAKE_ROLE=OPENFLOW_ADMIN
SNOWFLAKE_WAREHOUSE=AQ_WH
```

`SNOWFLAKE_ACCOUNT` có dạng `<organization>-<account-name>`, ví dụ `QZHBKRK-BS40861`. Đây không phải locator và không phải tên account đứng riêng (`BS40861`). Xem trong Snowsight ở menu tài khoản, mục thông tin account.

**5. Cài thư viện bằng `uv`:**

```bash
uv add soda-core-snowflake python-dotenv snowflake-connector-python
uv add setuptools
```

`setuptools` cần vì Soda Core 3.5.6 vẫn import `distutils`, mà `distutils` đã bị bỏ khỏi Python từ 3.12. Thiếu gói này thì Soda báo `ModuleNotFoundError: No module named 'distutils'`. Commit cả `pyproject.toml` và `uv.lock`.

Bước này hoàn thành khi `uv run wap/02_audit.py` (ở runbook sau) kết nối được. Không có cách thử riêng: lỗi kết nối sẽ hiện ngay ở bước Audit.

## Write: dựng Silver Candidate

Mở `wap/01_write_candidate.sql` trong Snowsight và chạy toàn bộ. (Khi đã có pipeline một lệnh, `uv run wap/run.py` chạy file này thay bạn; chạy tay chỉ để hiểu từng bước.)

Cách file hoạt động:

```
Silver hiện tại --clone--> Candidate --MERGE với Bronze--> Candidate (đã cập nhật)
```

1. Tạo schema `SILVER_CANDIDATE`. Clone `DIM_STATION` và `FACT_AQI` từ Silver hiện tại bằng `CREATE OR REPLACE ICEBERG TABLE ... CLONE`. Clone không sao chép dữ liệu, chỉ dùng chung storage với bảng gốc. Chỉ hai bảng này được clone vì chúng đi theo Bronze; `DIM_DATE`, `DIM_TIME`, `DIM_CITY` là dữ liệu lịch và tham chiếu, được đọc thẳng từ `SILVER`.
2. `MERGE` vào `DIM_STATION` từ `AQ.STATIONS`, thành phố lấy từ URL.
3. `MERGE` vào `FACT_AQI` từ `AQ.MEASUREMENTS`, nối với `DIM_STATION` của candidate, `DIM_DATE` (theo ngày giờ Việt Nam) và `DIM_TIME` (theo giờ):

| Trạng thái dòng ở Bronze | Hành động trong Silver Candidate |
| --- | --- |
| Dòng mới | `INSERT` |
| Dòng đã đổi (`_SNOWFLAKE_UPDATED_AT` khác `ingested_at`) | `UPDATE` |
| Dòng xóa mềm (`_SNOWFLAKE_DELETED = TRUE`) | `DELETE` |

Thời gian `measured_at` được đổi sang giờ Việt Nam bằng `CONVERT_TIMEZONE('Asia/Ho_Chi_Minh')`. Cột `source` được đổi tên: `kaggle_2021` thành `kaggle`, `waqi_api` thành `api`. Cột `dominant_pollutant` được làm sạch: giá trị rỗng, `-` và `aqi` thành `NULL`.

Vì candidate luôn được dựng lại từ đầu bằng `CREATE OR REPLACE`, chạy lại file bao nhiêu lần cũng được. Lần chạy đầu không đặc biệt: Silver hiện tại đang trống, bản clone trống, và `MERGE` chèn toàn bộ dòng Bronze còn sống.

### Kiểm tra kết quả

Chạy từng câu ở cuối file (sau dòng `-- CHECKS`):

**A. Không mất dòng nào.** Kết quả phải là hai số bằng nhau:

| `bronze_live_rows` | `candidate_rows` |
| --- | --- |
| 2117 | 2117 |

**B. Silver hiện tại chưa bị đụng tới.** `current_silver_fact_rows` phải là `0` ở lần chạy đầu. Silver chỉ có dữ liệu sau bước Publish.

**C. Ba thay đổi CDC.** Câu truy vấn trả về đúng 2 dòng: `320` với `aqi = 275` (dòng đã sửa) và `2118` (dòng thêm mới). Dòng `434` không được xuất hiện, vì đã xóa mềm ở Bronze.

**D. Số trạm và thành phố.** 11 thành phố, 23 trạm, tổng số dòng fact là 2117.

**E. Giá trị `dominant_pollutant` sau khi làm sạch:**

| `dominant_pollutant` | `n` |
| --- | --- |
| `pm25` | 1332 |
| `NULL` | 541 |
| `pm10` | 244 |

Bước này hoàn thành khi A, B, C, D, E đều khớp. Tiếp theo là `silver-audit-publish.md`.
