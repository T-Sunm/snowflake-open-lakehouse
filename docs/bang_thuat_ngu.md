# Bảng thuật ngữ

| Thuật ngữ | Giải thích |
| --- | --- |
| CDC (change data capture) | Nhóm kỹ thuật phát hiện thay đổi ở hệ thống nguồn rồi áp dụng sang bản sao dữ liệu |
| Initial snapshot | Bản sao toàn bộ dữ liệu nguồn ở thời điểm bắt đầu CDC |
| Logical replication | Cơ chế PostgreSQL giải mã WAL thành thay đổi của từng dòng rồi phát cho bên đọc |
| Publication | Tập bảng mà PostgreSQL phát thay đổi qua logical replication |
| Replication slot | Vị trí trong log mà bên đọc đã xử lý đến, giúp không bỏ sót thay đổi |
| Change log | Bảng ghi lại từng thay đổi nhận từ nguồn trước khi gộp vào bảng đích |
| Soft delete | Đánh dấu dòng đã xóa thay vì xóa vật lý khỏi bảng |
| External volume | Đối tượng Snowflake lưu vị trí object storage và quyền truy cập để Snowflake đọc, ghi file |
| BYOC (bring your own cloud) | Mô hình triển khai trong đó phần xử lý dữ liệu chạy trong tài khoản cloud của khách hàng |
| Write-Audit-Publish (WAP) | Quy trình ghi thay đổi vào một bản tách biệt, kiểm tra, và chỉ đưa vào sử dụng khi đạt kiểm tra |
| Zero-copy clone | Bản sao của bảng dùng chung file dữ liệu với bản gốc nhưng có metadata riêng |
| Horizon Catalog | Catalog Iceberg REST của Snowflake, cho engine bên ngoài truy cập bảng do Snowflake quản lý |
| Vended credentials | Khóa truy cập storage tạm thời mà catalog cấp cho client theo quyền của role |
