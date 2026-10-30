# Silver: Audit bằng Soda và Publish

Chạy từ thư mục gốc của repo. Runbook này làm hai bước còn lại của Write-Audit-Publish: **Audit** kiểm tra Silver Candidate bằng Soda, **Publish** đưa candidate đã qua kiểm tra thành Silver hiện tại.

Điều kiện: đã làm xong `silver-candidate.md`, tức là `SILVER_CANDIDATE.FACT_AQI` có 2117 dòng, đăng nhập key-pair và `.env` đã sẵn sàng, các thư viện đã cài bằng `uv`.

Ý tưởng của hai bước: không bao giờ ghi thẳng vào Silver. Candidate được kiểm tra trước; nếu có kiểm tra **fail**, Publish không chạy và Silver hiện tại giữ nguyên.

## Audit: kiểm tra candidate bằng Soda

Audit gồm ba file:

| File | Vai trò |
| --- | --- |
| `soda/configuration.yml` | Kết nối Snowflake của Soda (data source `aq`), đọc giá trị từ biến môi trường trong `.env`, trỏ vào schema `SILVER_CANDIDATE` |
| `soda/checks/silver_candidate.yml` | 22 kiểm tra trên `FACT_AQI` (viết bằng SodaCL) |
| `wap/02_audit.py` | Nạp `.env`, chạy Soda, in từng kết quả, ghi vào `CONTROL.DQ_RESULTS` |

Soda kết nối bằng key pair (`authenticator: SNOWFLAKE_JWT`), không dùng mật khẩu nên không bị hỏi mã MFA.

### Các kiểm tra

Mỗi kiểm tra có kết quả **pass**, **warn** hoặc **fail**. Fail chặn Publish, warn chỉ được ghi lại và báo cáo.

| Nhóm | Kiểm tra | Kết quả khi vi phạm |
| --- | --- | --- |
| Kích thước | `row_count >= 10` | fail |
| Đối soát | Số dòng candidate bằng số dòng Bronze đang sống (đếm trực tiếp từ Bronze), nên phát hiện việc `JOIN` làm rơi dòng mà không báo lỗi | fail |
| Trùng lặp | `measurement_id` duy nhất; mỗi cặp (`station_key`, `measured_at`) chỉ một dòng | fail |
| Khóa không được null | `measurement_id`, `date_key`, `time_key`, `city_key`, `station_key`, `measured_at`, `source` | fail |
| Số đo được phép null có trần | Tỷ lệ null của `aqi` và `pm25` không quá 30%, của `pm10` không quá 40%. Dữ liệu thật có khoảng 23% null AQI, 19% null PM2.5, 31% null PM10 | warn |
| Giá trị hợp lệ | `aqi` trong [0, 500]; `source` chỉ là `kaggle` hoặc `api`; các chất ô nhiễm và độ ẩm, áp suất không âm | fail |
| Quy tắc nghiệp vụ | `pollution_level` khớp với `AQI_CATEGORY(aqi)` | fail |
| Toàn vẹn tham chiếu | Mọi dòng fact tìm được đủ bốn dimension; thành phố của fact bằng thành phố của trạm; mọi thành phố trong `CITY_REFERENCE` đều có dữ liệu | fail |
| Độ mới | `ingested_at` không cũ hơn 2 ngày | warn |

Kiểm tra độ mới chỉ là cảnh báo. Dữ liệu là mẫu năm 2021 và `ingested_at` là thời điểm Bronze thay đổi dòng đó lần cuối, nên kiểm tra này sẽ chuyển sang `WARN` khi quá 2 ngày không có thay đổi mới ở Bronze. Đây là hành vi bình thường.

Soda Core v3 (SodaCL v3, bản 3.5.6) là phiên bản đang dùng trong repo này.

### Chạy Audit

```bash
uv run wap/02_audit.py
```

Mỗi kiểm tra in một dòng `[PASS]`, `[WARN]` hoặc `[FAIL]` kèm tên. Lần chạy đã thực hiện cho kết quả 22/22 `PASS`.

Mã thoát của script là thứ `wap/run.py` dựa vào để quyết định có Publish hay không:

| Mã thoát | Ý nghĩa |
| --- | --- |
| 0 | Mọi kiểm tra pass, hoặc chỉ có warn: được Publish |
| 1 | Có ít nhất một kiểm tra fail: không Publish |
| 2 | Soda không chạy được (cấu hình, kết nối hoặc cú pháp kiểm tra sai) |

Kết quả của mỗi lần chạy còn được ghi vào `AQ_LAKEHOUSE.CONTROL.DQ_RESULTS` (cột `run_id`, `layer`, `check_name`, `severity`, `passed`, `detail`, `checked_at`), nên có thể xem lại lịch sử kiểm tra:

```sql
SELECT run_id, check_name, severity, passed, checked_at
FROM AQ_LAKEHOUSE.CONTROL.DQ_RESULTS
ORDER BY checked_at DESC
LIMIT 30;
```

Bước này hoàn thành khi script in 22 dòng `PASS` và mã thoát là 0.

## Publish: đưa candidate thành Silver hiện tại

Mở `wap/03_publish.sql` trong Snowsight và chạy toàn bộ. **Chỉ chạy sau khi Audit đã pass**: file này không tự kiểm tra gì cả. Khi dùng `uv run wap/run.py` thì script tự chặn Publish nếu Audit fail.

File chạy hai câu, theo thứ tự:

```sql
INSERT OVERWRITE INTO SILVER.DIM_STATION SELECT * FROM SILVER_CANDIDATE.DIM_STATION;
INSERT OVERWRITE INTO SILVER.FACT_AQI    SELECT * FROM SILVER_CANDIDATE.FACT_AQI;
```

- `INSERT OVERWRITE` thay toàn bộ nội dung bảng trong **một** câu lệnh: người đọc thấy hoặc nội dung cũ hoặc nội dung mới, không bao giờ thấy trạng thái nửa vời. Bảng giữ nguyên tên, chỗ lưu trên S3 và quyền, nên Gold và DuckDB đọc qua Horizon không phải đổi gì.
- Cách này ghi lại các file dữ liệu. Với kích thước hiện tại việc đó mất vài giây. Tài liệu Snowflake không xác nhận `SWAP WITH` cho bảng Iceberg nên tutorial không dùng cách đó.
- `DIM_STATION` đi trước `FACT_AQI`. Trạm đã có giữ nguyên `station_key` (bước Write dùng `MERGE`, không đánh số lại), nên giữa hai câu lệnh bảng fact vẫn nối được với dimension mới.
- `SELECT *` an toàn vì candidate là bản clone của Silver nên hai bảng có cùng cột.

### Kiểm tra kết quả

Chạy từng câu ở cuối file (sau dòng `-- CHECKS`):

**A. Silver hiện tại bằng candidate.** Ở lần Publish đầu tiên:

| `silver_fact_rows` | `candidate_fact_rows` | `silver_stations` | `candidate_stations` |
| --- | --- | --- | --- |
| 2117 | 2117 | 23 | 23 |

**B. Ba thay đổi CDC đã nằm trong Silver.** Truy vấn trả về 2 dòng: `320` với `aqi = 275` và `2118`. Dòng `434` không có.

**C. Silver và candidate giống hệt nhau.** `differing_rows` phải là `0`.

**D. Star schema trả lời được câu hỏi từ đầu đến cuối.** Câu truy vấn gom theo thành phố và mùa, trả về tối đa 10 dòng, thấy đủ 11 thành phố trong dữ liệu, Hà Nội có nhiều lượt đo nhất. Nha Trang có `avg_aqi` rỗng: trạm này không có số đo AQI nào (0 trên 113 dòng). Silver vẫn giữ các dòng đó, vì chúng là dữ liệu thật; Gold sẽ xử lý riêng (xem `gold-iceberg.md`). Huế, Hạ Long và Lào Cai cũng rất ít dữ liệu AQI.

Bước này hoàn thành khi A, B, C khớp và D trả về kết quả theo từng thành phố. Tiếp theo là `gold-iceberg.md`.
