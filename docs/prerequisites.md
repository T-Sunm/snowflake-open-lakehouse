# Yêu cầu chuẩn bị

Trước khi đi vào thực hành, bạn cần chuẩn bị sẵn một số thứ sau. Tài liệu chính thức của từng công cụ đã hướng dẫn cách cài.

- **Tài khoản Snowflake trả phí** trên AWS, region `us-east-2`, và dùng được role `ACCOUNTADMIN`. Openflow không dùng được trên tài khoản trial.
- **Tài khoản AWS** cùng một IAM user có quyền `AdministratorAccess`. Tutorial không dùng tài khoản root.
- **AWS CLI** từ phiên bản 2.32.0 trở lên, kèm **Session Manager plugin** để kết nối vào EC2.
- **`uv`**, công cụ quản lý Python và thư viện cho các bước dùng Soda và DuckDB.
- **Repo `snowflake-open-lakehouse`** được clone về máy. Các lệnh trong tutorial chạy từ thư mục gốc của repo.

Sau khi cài xong, bạn đăng nhập AWS CLI với region `us-east-2` để các lệnh trong tutorial dùng được ngay.
