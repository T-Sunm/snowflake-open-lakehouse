# Open Lakehouse Plan
## 1. Giới thiệu

Bài viết xây dựng một lakehouse sử dụng Apache Iceberg làm table format và Amazon S3 làm storage. PostgreSQL đóng vai trò operational source, Snowflake Openflow thực hiện initial snapshot và CDC, dữ liệu được tổ chức qua Bronze, Silver và Gold, còn Horizon Catalog cho phép external processing engine truy cập cùng các bảng Iceberg.

Phần mở đầu sử dụng sơ đồ kiến trúc tổng thể để giới thiệu các thành phần và mối liên hệ giữa chúng ở mức vừa đủ để người chưa đọc bài trước vẫn theo được. Snowflake là processing engine chính, trong khi DuckDB được sử dụng ở cuối bài để minh họa khả năng đọc và ghi cùng dữ liệu Iceberg từ một engine khác.

Bài tập trung vào ba thay đổi chính:

1. Bronze được cập nhật liên tục từ PostgreSQL bằng CDC sau initial snapshot.
2. Silver được kiểm soát bằng quy trình Write Audit Publish trước khi downstream sử dụng.
3. Cùng các bảng Iceberg có thể được truy cập từ nhiều processing engine.

## 2. Đưa dữ liệu PostgreSQL vào Bronze Iceberg

Phần này xây dựng ingestion path từ PostgreSQL tới Bronze, bắt đầu bằng initial snapshot và tiếp tục bằng CDC.

### 2.1. Chuẩn bị hạ tầng

Bài chuẩn bị theo thứ tự: Amazon S3, IAM và External Volume cho Iceberg storage; sau đó VPC cùng PostgreSQL nguồn trên EC2; cuối cùng triển khai Snowflake Openflow theo mô hình BYOC bằng AWS CloudFormation trong chính VPC đó.

Ở phía Snowflake, bài cấu hình External Volume và database dùng cho Iceberg destination. Vì các bảng này sẽ được DuckDB đọc ở phần sau, storage serialization được cấu hình theo hướng tương thích với external engine bằng `STORAGE_SERIALIZATION_POLICY = COMPATIBLE`.

Các kiểm tra cần thiết được thực hiện ngay sau từng nhóm cấu hình để xác nhận Openflow runtime, S3 và kết nối Snowflake đã sẵn sàng.

### 2.2. Cấu hình PostgreSQL, Openflow và Bronze

PostgreSQL được chuẩn bị cho logical replication, bao gồm publication và các quyền cần thiết. Các bảng được chọn để minh họa CDC cần có replication key hợp lệ, chẳng hạn primary key, để connector có thể xử lý đầy đủ INSERT, UPDATE và DELETE.

Sau đó, bài tạo PostgreSQL Connector trong Openflow, chọn các source tables cần replicate và cấu hình Snowflake destination sử dụng Iceberg làm table storage format.

Khi connector khởi chạy, initial snapshot đưa dữ liệu hiện có từ PostgreSQL vào các Bronze tables. Kết quả snapshot được kiểm tra trực tiếp trên Bronze và đối chiếu với source trước khi chuyển sang incremental replication.

### 2.3. Quan sát initial snapshot và CDC

Sau initial snapshot, connector tiếp tục theo dõi các thay đổi từ PostgreSQL và cập nhật Bronze bằng incremental replication.

Openflow ghi các thay đổi vào journal trước khi áp dụng chúng vào Bronze. Bronze vẫn giữ các bản ghi đã bị xóa ở PostgreSQL và đánh dấu chúng bằng `_SNOWFLAKE_DELETED = TRUE`. Khi downstream cần trạng thái hiện tại của source, pipeline sử dụng các bản ghi có `_SNOWFLAKE_DELETED = FALSE`.

Bài lần lượt thực hiện một INSERT, một UPDATE và một DELETE trên PostgreSQL. Bronze được truy vấn sau mỗi thao tác để quan sát cách dữ liệu thay đổi và cách soft delete được biểu diễn.

## 3. Xây dựng trusted Silver và Gold

Bronze phản ánh dữ liệu được replicate từ source nhưng chưa mặc nhiên là dữ liệu trusted cho downstream. Phần này sử dụng Write Audit Publish để chuẩn bị một trạng thái Silver mới, kiểm tra trạng thái đó và chỉ đưa vào sử dụng khi dữ liệu đạt yêu cầu.

Một sơ đồ Write → Audit → Publish được sử dụng ở đầu phần để giới thiệu toàn bộ workflow. Các mục sau lần lượt triển khai từng bước của quy trình này.

### 3.1. Chuẩn bị Silver Candidate

Silver Candidate là trạng thái làm việc riêng trước khi một phiên bản Silver mới được đưa vào sử dụng.

Candidate luôn được khởi tạo từ Current Silver bằng Snowflake Zero Copy Clone; ở lần chạy đầu, Current Silver còn trống nên Candidate cũng trống và được điền từ Bronze. Candidate chưa trở thành trusted Silver cho đến khi vượt qua bước audit.

Sau khi clone, Candidate được đồng bộ với trạng thái Bronze hiện tại thông qua transformation hoặc merge phù hợp. Quá trình này cần xử lý cả record mới, record thay đổi và các record đã bị soft delete tại source.

Bài tái sử dụng Silver transformation logic phù hợp từ pipeline trước thay vì xây lại những business rules không thay đổi.

Sau khi xử lý, Current Silver và Silver Candidate được truy vấn để cho thấy trạng thái đang được downstream sử dụng vẫn giữ nguyên trong khi Candidate đã chứa dữ liệu của lần cập nhật mới.

### 3.2. Audit và publish Silver

Soda được sử dụng để kiểm tra Silver Candidate trước khi publish. Các quality checks được chọn theo dataset thực tế và có thể bao gồm:

- null và miền giá trị hợp lệ;
- duplicate hoặc uniqueness;
- referential integrity khi phù hợp;
- freshness;
- các business quality rules cần thiết.

Nếu Candidate không đạt yêu cầu, quy trình dừng và Current Silver tiếp tục được sử dụng.

Nếu Candidate đạt yêu cầu, Candidate được publish để trở thành trạng thái Silver mới cho downstream. Bước publish dùng `INSERT OVERWRITE` để thay toàn bộ nội dung Silver trong một câu lệnh.

Sau publish, Silver được truy vấn để xác nhận trạng thái mới đã sẵn sàng cho downstream.

### 3.3. Xây dựng Gold trên Iceberg

Trusted Silver được sử dụng để tạo Gold phục vụ analytics và downstream consumption.

Bài tiếp tục sử dụng Apache Iceberg cho Gold để Bronze, Silver và Gold cùng nằm trên một shared table format. Các transformation hoặc aggregate cần thiết được thực hiện từ Silver, sau đó kết quả được kiểm tra bằng các business checks và analytical queries phù hợp với dataset.

Phần này không so sánh lại toàn bộ Native Tables và Iceberg. Việc giữ Gold trên Iceberg được xem là một quyết định thiết kế của kiến trúc mới nhằm duy trì cùng table format xuyên suốt data lifecycle.

## 4. Chia sẻ Iceberg giữa nhiều processing engine

Phần này mở rộng kiến trúc từ một pipeline chủ yếu được xử lý bằng Snowflake sang khả năng truy cập cùng Iceberg tables từ external processing engine, cả đọc lẫn ghi.

Phần mở đầu nhắc lại ngắn sự tách biệt giữa processing engine, catalog, table format và storage. Processing engine sử dụng catalog để tìm table và xác định trạng thái hiện tại, còn Iceberg mô tả table trên các file được lưu trong S3. Phần lý thuyết chỉ giữ những kiến thức cần thiết cho external access, không trình bày lại toàn bộ metadata hierarchy của Iceberg.

### 4.1. Cấu hình Horizon Catalog và external access

Horizon Catalog được cấu hình làm interface để external engine truy cập các bảng Iceberg do pipeline tạo ra.

Phần này tập trung vào:

- Horizon Iceberg REST endpoint;
- authentication: một service user và một programmatic access token (PAT) gắn với một role duy nhất;
- permissions: role chỉ có quyền đọc trên Silver và Gold (và trên schema `SILVER_CANDIDATE`, vì Horizon yêu cầu role truy cập được các bản clone của bảng Silver mới cấp được khóa S3), vì Silver chỉ thay đổi qua Write Audit Publish và Gold được dựng từ Silver; quyền đọc và ghi đầy đủ chỉ được cấp trên một schema `SANDBOX` riêng;
- cấu hình external access;
- kiểm tra khả năng discover các Snowflake-managed Iceberg tables.

Phần thực hành kết thúc khi external client có thể nhìn thấy các bảng Silver, Gold và `SANDBOX` thông qua Horizon Catalog.

### 4.2. Đọc và ghi bằng DuckDB

DuckDB được sử dụng như một external processing engine. Bài cấu hình DuckDB kết nối qua Horizon Catalog bằng PAT và dùng hai script, một để đọc và một để ghi.

Chiều đọc: DuckDB truy vấn các bảng Silver hoặc Gold đã tạo ở mục 3, và kết quả được đối chiếu với Snowflake.

Chiều ghi: DuckDB `INSERT`, `UPDATE` và `DELETE` các dòng trong bảng `SANDBOX.DUCKDB_NOTES`, sau đó Snowflake đọc lại đúng bảng đó và thấy cùng kết quả. Thử ghi vào Silver bằng cùng token sẽ bị từ chối, vì dữ liệu trusted chỉ thay đổi qua Write Audit Publish.

Kết quả cần cho thấy Snowflake và DuckDB có thể đọc và ghi cùng dữ liệu Iceberg mà không cần tạo thêm một bản sao dữ liệu hoặc xây dựng một export pipeline riêng.

Trong phạm vi tutorial, Snowflake vẫn là processing engine chính cho ingestion, transformation và publishing. DuckDB đóng vai trò external engine đọc dữ liệu trusted và ghi vào vùng sandbox.