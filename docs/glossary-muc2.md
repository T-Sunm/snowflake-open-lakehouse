## Bảng thuật ngữ

Các thuật ngữ được xếp theo thứ tự xuất hiện trong mục 2.

| Thuật ngữ | Giải thích |
| --- | --- |
| Operational database | Cơ sở dữ liệu mà ứng dụng liên tục đọc và ghi, ở đây là PostgreSQL |
| CDC (change data capture) | Nhóm kỹ thuật phát hiện thay đổi ở hệ thống nguồn rồi áp dụng sang bản sao dữ liệu |
| Initial snapshot | Bản sao toàn bộ dữ liệu nguồn lúc bắt đầu, khác với snapshot của Iceberg |
| Transaction log (WAL) | Nhật ký ghi mọi `INSERT`, `UPDATE` và `DELETE` theo thứ tự xảy ra, PostgreSQL gọi là write-ahead log |
| Logical replication | Cơ chế PostgreSQL giải mã WAL thành thay đổi của từng dòng rồi phát đi |
| Publisher, subscriber | Bên phát thay đổi (operational database) và bên đọc thay đổi (dịch vụ CDC) |
| Publication | Tập bảng có thay đổi được phát ra |
| Replication slot | Lưu vị trí subscriber đã đọc đến trong log |
| Replica identity | Định danh dòng mà mỗi thay đổi mang theo, mặc định là khóa chính |
| Change log (journal) | Bảng phụ cạnh bảng Bronze, ghi từng thay đổi nhận từ nguồn trước khi gộp |
| Merge | Áp dụng các thay đổi trong change log vào bảng Bronze theo khóa chính |
| Soft delete | Đánh dấu dòng đã xóa thay vì xóa vật lý khỏi Bronze |
| External volume | Đối tượng Snowflake lưu vị trí bucket S3 và IAM role để Snowflake đọc, ghi file |
| Deployment | Hạ tầng nền của Openflow BYOC trong VPC của bạn (EKS, RDS, load balancer) |
| Runtime | Môi trường bên trong deployment nơi connector chạy, dưới một role Snowflake |
