# Horizon Catalog và quyền truy cập cho external engine

Chạy từ thư mục gốc của repo. Runbook này cấu hình để một engine bên ngoài Snowflake (ở bài này là DuckDB) đăng nhập vào Horizon Catalog và thấy các bảng Iceberg của project. Kết thúc khi script kiểm tra liệt kê được bảng Silver, Gold và Sandbox qua Horizon.

Điều kiện: đã làm xong `silver-candidate.md`, `silver-audit-publish.md` và `gold-iceberg.md` (có schema `SILVER`, `GOLD`, `SILVER_CANDIDATE` và pipeline `uv run wap/run.py` chạy được). Phần Snowflake chạy trong Snowsight, phần kiểm tra chạy bằng terminal với `uv`.

## Khái niệm cần có

Catalog giữ trạng thái: bảng nào tồn tại và file metadata hiện tại của mỗi bảng nằm ở đâu. Catalog không chứa dữ liệu. Engine bên ngoài phải biết ba điều: catalog ở đâu (endpoint), mình là ai (token), và lấy file trên S3 bằng cách nào (khóa S3 tạm thời do catalog cấp, gọi là *vended credentials*).

Hai khái niệm của runbook này:

- **PAT (Programmatic Access Token)** là chuỗi ký tự Snowflake cấp cho một user để chương trình đăng nhập, thay cho mật khẩu và mã MFA mà chương trình không nhập được. Ai cầm chuỗi này được coi là user đó, nên phải giữ kín như mật khẩu.
- **SANDBOX** là một schema riêng, nơi engine bên ngoài được phép ghi. Silver chỉ thay đổi qua Write-Audit-Publish và Gold được dựng từ Silver, nên role bên ngoài chỉ đọc hai schema đó, còn quyền đọc và ghi đầy đủ chỉ nằm trên `SANDBOX`.

Endpoint của Horizon có dạng `https://<account-identifier>.snowflakecomputing.com/polaris/api/catalog`. Tên catalog là **tên database** (`AQ_LAKEHOUSE`, viết hoa), không phải tên warehouse.

## Thiết kế quyền

| Đối tượng | Giá trị |
| --- | --- |
| Role | `AQ_EXTERNAL` |
| User | `AQ_DUCKDB` (`TYPE = SERVICE`: user dành cho máy, không có mật khẩu và không hỏi MFA) |
| Token | `duckdb_token`, giới hạn ở role `AQ_EXTERNAL`, hết hạn sau 30 ngày |
| Silver, Gold | Chỉ `SELECT` |
| `SILVER_CANDIDATE` | Chỉ `SELECT` (xem ghi chú bên dưới) |
| `SANDBOX.DUCKDB_NOTES` | `SELECT`, `INSERT`, `UPDATE`, `DELETE`, `TRUNCATE` |

Dùng một role và một token cho cả đọc lẫn ghi. Nếu token bị lộ, người cầm nó không đụng được vào Bronze và không sửa được Silver hay Gold.

`SILVER_CANDIDATE` được cấp quyền đọc vì pipeline clone `FACT_AQI` và `DIM_STATION` vào schema này. Lý do đầy đủ nằm ở mục tiếp theo.

## Clone, vended credentials và schema SILVER_CANDIDATE

DuckDB đọc bảng bằng khóa S3 tạm thời (*vended credentials*) do Horizon cấp cho từng bảng. Có một điều kiện khi cấp khóa liên quan đến các bản clone mà pipeline ở phần 3 tạo ra, nên cấu hình của `SILVER_CANDIDATE` cần chú ý.

### Ba khái niệm

- **Vended credentials** là khóa S3 ngắn hạn. DuckDB không có sẵn quyền vào bucket, nên mỗi lần đọc một bảng nó xin Horizon khóa cho đúng thư mục của bảng đó. Horizon chỉ cấp khi role đủ điều kiện.
- **Clone** (Zero Copy Clone) là bản sao không sao chép dữ liệu: bản gốc và bản clone dùng chung các file Parquet trên S3. Mỗi lần chạy, bước Write của pipeline chạy `CREATE OR REPLACE ICEBERG TABLE ... CLONE` để dựng `SILVER_CANDIDATE.FACT_AQI` và `SILVER_CANDIDATE.DIM_STATION` từ hai bảng Silver cùng tên. Chỉ hai bảng này được clone, vì chỉ chúng thay đổi theo Bronze.
- **Time Travel** giữ lại bảng đã xóa một thời gian (mặc định 1 ngày) để có thể khôi phục. Bảng bị `CREATE OR REPLACE` thay thế cũng được giữ. Xem bằng `SHOW TABLES HISTORY IN SCHEMA SILVER_CANDIDATE;` (cột `dropped_on`).

### Quy tắc của Horizon

Tài liệu Horizon nêu: với bảng có clone, nếu role không có quyền trên bảng gốc hoặc *các bản clone khác* của nó thì yêu cầu cấp khóa bị từ chối với HTTP 403. Vì vậy `FACT_AQI` và `DIM_STATION` ở `SILVER` chỉ đọc được qua DuckDB khi `AQ_EXTERNAL` cũng truy cập được các bản clone của chúng ở `SILVER_CANDIDATE`. Ba bảng còn lại của Silver và toàn bộ Gold không bị clone nên không chịu quy tắc này.

### Cấu hình đã áp dụng

- **Quyền đọc cho clone.** `snowflake/05_horizon_access.sql` cấp cho `AQ_EXTERNAL` `USAGE` trên `SILVER_CANDIDATE` và `SELECT` trên `ALL` và `FUTURE ICEBERG TABLES` của schema đó. Quyền `FUTURE` cần vì pipeline tạo bản clone mới ở mỗi lần chạy, và bảng mới không thừa hưởng quyền của bảng cũ. Quyền này chỉ để đọc, role không sửa được candidate hay Silver.
- **Candidate không giữ lịch sử.** `wap/01_write_candidate.sql` tạo `SILVER_CANDIDATE` với `DATA_RETENTION_TIME_IN_DAYS = 0`. Candidate chỉ là bản nháp dựng lại mỗi lần chạy nên không cần Time Travel: bản clone bị thay thì xóa hẳn, không còn nằm lại như một bảng đã xóa mà role chưa từng có quyền.

### Dấu hiệu khi cấu hình chưa đúng

Khi `duckdb/read.py` (xem `duckdb-read-write.md`) đọc `SILVER.FACT_AQI` hoặc `SILVER.DIM_STATION`, DuckDB báo:

```
HTTP Error: GetTableInformation endpoint returned response code Forbidden_403 with message "Authorization failed"
```

Các bảng Gold và `DIM_CITY` vẫn đọc bình thường. `scripts/diag_load_table.py` gọi thẳng endpoint của một bảng hai lần, có và không có vended credentials, rồi in mã HTTP (không in token):

```bash
uv run scripts/diag_load_table.py SILVER FACT_AQI
```

Bảng đọc được cho kết quả `HTTP 200` ở cả hai lần và dòng `storage credentials returned: yes`. Mẫu `without vended credentials: 200` nhưng `with vended credentials: 403` đúng là dấu hiệu của vấn đề này.

### Nếu vẫn gặp 403

Kiểm tra theo thứ tự: `SHOW GRANTS TO ROLE AQ_EXTERNAL` có `SELECT` trên hai bảng của `SILVER_CANDIDATE`; `SHOW SCHEMAS LIKE 'SILVER_CANDIDATE'` có `retention_time = 0`; rồi chạy `scripts/diag_load_table.py` như trên.

Nếu vẫn `403`, gốc rễ có thể là các bản clone cũ đã bị xóa nhưng còn trong Time Travel từ trước khi retention được đặt về 0 hoặc trước khi `AQ_EXTERNAL` có quyền. Cách xử lý đã chạy pass là tạo lại hai bảng Silver để chúng không còn gắn với các bản clone cũ:

```sql
USE ROLE openflow_admin;
USE DATABASE AQ_LAKEHOUSE;
DROP ICEBERG TABLE IF EXISTS SILVER.FACT_AQI;
DROP ICEBERG TABLE IF EXISTS SILVER.DIM_STATION;
```

Rồi chạy lại `snowflake/03_silver_schema.sql` (tạo lại hai bảng rỗng) và `uv run wap/run.py` (dựng lại Silver từ Bronze). Bronze còn nguyên nên không mất dữ liệu. Phần giải thích về bản clone cũ là suy luận; tài liệu Snowflake chỉ nêu quy tắc về bản gốc và các bản clone khác.

## Chọn đúng role ở từng bước

File SQL tự chuyển role bằng `USE ROLE` ở những chỗ cần, nên bạn không phải đổi tay khi chạy. Hai lưu ý khi làm việc với user sau đó:

- Tạo role, user, policy và token dùng `ACCOUNTADMIN`. Phần tạo schema `SANDBOX` và bảng dùng `OPENFLOW_ADMIN`, vì bảng phải do role này sở hữu (xem bên dưới).
- `OPENFLOW_ADMIN` chỉ thấy tên user, không thấy chi tiết (các cột `type`, `default_role` hiện `NULL`). Muốn xem thông tin user, chạy `USE ROLE ACCOUNTADMIN;` trước.

## Chạy file

Mở `snowflake/05_horizon_access.sql` trong Snowsight và chạy toàn bộ bằng **Run all** (`Ctrl + Shift + Enter`). Chạy một lần, từ trên xuống. File gồm ba phần.

**Phần A: role, user và quyền đọc.** Trong phần này file:

1. Tạo role `AQ_EXTERNAL`, cấp `USAGE` trên database `AQ_LAKEHOUSE` và các schema `SILVER`, `GOLD`.
2. Cấp `SELECT` trên bảng Silver và Gold bằng `ALL ICEBERG TABLES` và `FUTURE ICEBERG TABLES`. Bảng Iceberg là một loại đối tượng riêng: `ALL TABLES` **không** gồm chúng, và câu `GRANT ... ON ALL TABLES` chạy không báo lỗi nhưng không cấp gì.
3. Cấp `USAGE` trên schema `SILVER_CANDIDATE` và `SELECT` trên `ALL` và `FUTURE ICEBERG TABLES` của schema đó. Quyền `FUTURE` cần vì pipeline dựng lại clone mỗi lần chạy, và bảng mới không thừa hưởng quyền của bảng cũ.
4. Tạo user `AQ_DUCKDB` (`TYPE = SERVICE`, `DEFAULT_ROLE = AQ_EXTERNAL`) và gán role cho user.
5. Cho `ACCOUNTADMIN` quyền tạo authentication policy trong schema `CONTROL`. Schema này do `OPENFLOW_ADMIN` sở hữu, nên chính role đó phải cấp (file tự chuyển role cho bước này). Thiếu bước này, câu tạo policy báo `Insufficient privileges to operate on schema 'CONTROL'`.
6. Tạo authentication policy `AQ_PAT_POLICY` cho phép user dùng PAT mà không cần network policy, rồi gán policy cho `AQ_DUCKDB`. Mặc định PAT bắt buộc có network policy. Bỏ yêu cầu đó để kết nối được từ máy cá nhân chỉ phù hợp cho tutorial; môi trường thật nên tạo network policy cho các máy được phép.

**Phần B: vùng ghi SANDBOX.** File tạo schema `SANDBOX` và bảng Iceberg `SANDBOX.DUCKDB_NOTES` (`note_id`, `note`, `written_by`, `written_at`, `BASE_LOCATION = 'sandbox/duckdb_notes'`), rồi cấp cho `AQ_EXTERNAL` quyền `USAGE` trên schema và năm quyền `SELECT`, `INSERT`, `UPDATE`, `DELETE`, `TRUNCATE` trên bảng. Cuối phần này là câu `SHOW GRANTS TO ROLE AQ_EXTERNAL;`.

Bảng do Snowflake tạo bằng role `OPENFLOW_ADMIN` chứ không để DuckDB tự tạo. Horizon yêu cầu role sở hữu bảng phải có `USAGE` trên External Volume (role này có qua `OPENFLOW_AQ_RUNTIME_EXECUTE_AS_RL`), nếu không DuckDB sẽ lỗi khi xin khóa S3.

**Phần C: token.** Câu cuối cùng của file tạo PAT `duckdb_token` cho `AQ_DUCKDB`, giới hạn ở role `AQ_EXTERNAL` và hết hạn sau 30 ngày. Vì là câu cuối, kết quả hiện ở cửa sổ kết quả sau khi Run all xong chính là kết quả của câu này.

Chuỗi bí mật nằm trong cột `token_secret` và **chỉ hiện một lần**. Chép giá trị đó thẳng vào `.env` ở thư mục gốc, thành một dòng (không có dấu nháy hay khoảng trắng quanh dấu `=`):

```
HORIZON_PAT=<giá trị của cột token_secret>
```

Tên cột là `token_secret`, còn tên biến trong `.env` là `HORIZON_PAT`. Đừng dán token vào chat, ticket hay commit. Thêm dòng `HORIZON_PAT=` để trống vào `.env.example`. Nếu làm mất chuỗi, hoặc token đã hết hạn sau 30 ngày (lúc đó `scripts/check_horizon.py` và các script DuckDB báo lỗi lấy token), xóa và tạo lại bằng cùng đoạn dưới đây (dùng `ACCOUNTADMIN`), rồi cập nhật `HORIZON_PAT` trong `.env`:

```sql
USE ROLE ACCOUNTADMIN;
ALTER USER AQ_DUCKDB REMOVE PAT duckdb_token;

ALTER USER AQ_DUCKDB ADD PAT duckdb_token
  ROLE_RESTRICTION = 'AQ_EXTERNAL'
  DAYS_TO_EXPIRY = 30
  COMMENT = 'DuckDB tutorial token';
```

### Kiểm tra quyền

Chạy từng câu (dùng `ACCOUNTADMIN`):

```sql
USE ROLE ACCOUNTADMIN;
DESC USER AQ_DUCKDB;
SHOW GRANTS TO USER AQ_DUCKDB;
SHOW GRANTS TO ROLE AQ_EXTERNAL;
```

- `DESC USER`: `TYPE = SERVICE`, `DEFAULT_ROLE = AQ_EXTERNAL`.
- `SHOW GRANTS TO USER`: một dòng với `role` là `AQ_EXTERNAL`.
- `SHOW GRANTS TO ROLE`: xem bảng dưới.

| Đối tượng | Quyền |
| --- | --- |
| Database `AQ_LAKEHOUSE` | `USAGE` |
| Schema `SILVER`, `GOLD`, `SANDBOX`, `SILVER_CANDIDATE` | `USAGE` |
| 5 bảng Silver, 5 bảng Gold | `SELECT` (với `granted_on = ICEBERG_TABLE`) |
| `SILVER_CANDIDATE.DIM_STATION`, `SILVER_CANDIDATE.FACT_AQI` | `SELECT` |
| `SANDBOX.DUCKDB_NOTES` | `SELECT`, `INSERT`, `UPDATE`, `DELETE`, `TRUNCATE` |

Không được có `INSERT`, `UPDATE` hay `DELETE` trên bất kỳ bảng Silver hay Gold nào.

## Kiểm tra client bên ngoài thấy bảng

Script `scripts/check_horizon.py` đóng vai một client bên ngoài. Nó đọc `.env`, đổi PAT lấy access token ngắn hạn (giới hạn ở role `AQ_EXTERNAL`), hỏi catalog cấu hình, rồi liệt kê schema và bảng. Script chỉ dùng thư viện chuẩn và `python-dotenv`, và không in PAT hay token ra màn hình.

```bash
uv run scripts/check_horizon.py
```

Kết quả đúng:

```
Endpoint: https://<account-identifier>.snowflakecomputing.com/polaris/api/catalog
[PASS] token exchange
[PASS] catalog config (prefix: AQ_LAKEHOUSE)
[PASS] namespaces: GOLD, SANDBOX, SILVER, SILVER_CANDIDATE
  GOLD: 5 tables  AQI_CITY_RANKING, AQI_DAILY_SUMMARY, AQI_HOURLY_PATTERN, AQI_SEASONAL_SUMMARY, STATION_SUMMARY
  SANDBOX: 1 tables  DUCKDB_NOTES
  SILVER: 5 tables  DIM_CITY, DIM_DATE, DIM_STATION, DIM_TIME, FACT_AQI
  SILVER_CANDIDATE: 2 tables  DIM_STATION, FACT_AQI

== Horizon is reachable. 13 tables visible to role AQ_EXTERNAL.
```

Schema `AQ` (Bronze) và `CONTROL` không xuất hiện, vì role không có quyền trên chúng.

Bước này hoàn thành khi script in dòng "Horizon is reachable" với 13 bảng. Tiếp theo là `duckdb-read-write.md`, nơi DuckDB đọc và ghi các bảng này.