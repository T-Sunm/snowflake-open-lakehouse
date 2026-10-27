# Iceberg storage trên S3 và Snowflake

Chạy từ thư mục gốc của repo. Các bước dưới đây tạo nơi lưu file Iceberg trên S3, cho Snowflake quyền ghi vào đó, rồi tạo database `AQ_LAKEHOUSE` với các thiết lập Iceberg mặc định. Phải làm xong trước khi tạo connector Openflow, vì bảng Bronze nhận thiết lập của database tại lúc được tạo.

Phần AWS chạy trong terminal, phần Snowflake chạy trong Snowsight (Projects → Workspaces → SQL file). Vì hai bên cần thông tin của nhau, thực hiện lần lượt trên AWS, Snowflake, AWS rồi Snowflake.

Trong runbook, `<account-id>` là số tài khoản AWS 12 chữ số và `<snowflake-iam-user-arn>` là giá trị Snowflake trả về ở bước tạo External Volume.

## Xác định region

Chạy trong Snowsight:

```sql
SELECT CURRENT_REGION();
```

Kết quả `AWS_US_EAST_2` tương ứng với region AWS `us-east-2`. Mọi tài nguyên AWS của project đặt ở region này để tránh phí truyền dữ liệu giữa các region.

## Đăng nhập AWS CLI

Cần AWS CLI 2.32.0 trở lên và một IAM user có quyền `AdministratorAccess`. Không dùng tài khoản root.

```bash
aws --version
aws login
aws sts get-caller-identity
```

Khi `aws login` hỏi region, nhập `us-east-2`. Ở trang đăng nhập, chọn **Sign into new session** và đăng nhập bằng IAM user. Bước này hoàn thành khi dòng `Arn` của `get-caller-identity` kết thúc bằng `:user/<tên-user>`, không phải `:root`.

Phiên đăng nhập dùng được tối đa 12 giờ. Hết hạn thì chạy lại `aws login`.

## Tạo bucket và IAM role (deploy lần 1)

```bash
aws cloudformation deploy --template-file infra/cloudformation/iceberg-storage.yaml --stack-name aq-iceberg-storage --capabilities CAPABILITY_NAMED_IAM --region us-east-2
```

Template tạo bucket `aq-lakehouse-<account-id>-us-east-2` (chặn truy cập công khai, mã hóa sẵn, chỉ nhận kết nối HTTPS) và IAM role `snowflake-iceberg-aq-iceberg-storage`, chỉ được đọc ghi trong thư mục `lakehouse/`. Sau lần deploy đầu, trust policy chỉ tin tưởng chính tài khoản AWS nên Snowflake chưa dùng được role. Lần deploy thứ hai sẽ cập nhật trust policy.

Xem các giá trị đầu ra:

```bash
aws cloudformation describe-stacks --stack-name aq-iceberg-storage --region us-east-2 --query "Stacks[0].Outputs" --output table
```

| Output | Giá trị | Dùng cho |
| --- | --- | --- |
| `StorageBaseUrl` | `s3://aq-lakehouse-<account-id>-us-east-2/lakehouse/` | `STORAGE_BASE_URL` |
| `RoleArn` | `arn:aws:iam::<account-id>:role/snowflake-iceberg-aq-iceberg-storage` | `STORAGE_AWS_ROLE_ARN` |
| `ExternalId` | `snowflake-open-lakehouse` | `STORAGE_AWS_EXTERNAL_ID` |
| `TrustReady` | `false` | Chưa tới lần deploy 2 |

## Tạo External Volume

Mở `snowflake/01_external_volume.sql` trong Snowsight, điền ba giá trị `StorageBaseUrl`, `RoleArn`, `ExternalId` vào chỗ `<...>`, rồi chạy **Part A**. Chỉ điền giá trị ở bản trong Snowsight; file trong repo giữ nguyên `<...>`.

Câu lệnh cuối của Part A trả về:

| `snowflake_iam_user_arn` | `external_id` |
| --- | --- |
| `arn:aws:iam::<số tài khoản của Snowflake>:user/...` | `snowflake-open-lakehouse` |

Số tài khoản trong ARN này là của Snowflake, khác với `<account-id>` của bạn. Sao chép `snowflake_iam_user_arn` cho bước tiếp theo.

## Cho IAM role tin tưởng Snowflake (deploy lần 2)

```bash
aws cloudformation deploy --template-file infra/cloudformation/iceberg-storage.yaml --stack-name aq-iceberg-storage --capabilities CAPABILITY_NAMED_IAM --region us-east-2 --parameter-overrides SnowflakeIamUserArn=<snowflake-iam-user-arn>
```

CloudFormation chỉ cập nhật trust policy của role, bucket và role được giữ nguyên. Kiểm tra:

```bash
aws cloudformation describe-stacks --stack-name aq-iceberg-storage --region us-east-2 --query "Stacks[0].Outputs[?OutputKey=='TrustReady'].OutputValue" --output text
```

Bước này hoàn thành khi kết quả là `true`.

## Kiểm tra External Volume

Chạy **Part B** của `snowflake/01_external_volume.sql`. Hàm kiểm tra đã trả về:

```json
{"success":true,"writeResult":"PASSED","readResult":"PASSED","listResult":"PASSED","deleteResult":"PASSED","awsRoleArnValidationResult":"PASSED"}
```

Nếu `success` là `false`, chờ khoảng một phút rồi chạy lại, vì thay đổi trust policy cần vài chục giây để có hiệu lực. Nếu vẫn lỗi, kiểm tra ARN trong lần deploy 2 và external ID hai bên có khớp không.

Part B cũng cấp quyền dùng volume cho role `SYSADMIN`.

## Tạo database và chạy thử

Chạy toàn bộ `snowflake/02_database.sql` bằng **Run all** (`Ctrl + Shift + Enter`). File tạo warehouse `AQ_WH` (XSMALL, tự tạm dừng sau 60 giây), database `AQ_LAKEHOUSE`, rồi tạo bảng thử `SMOKE_TEST.HELLO_ICEBERG` và ghi một dòng.

Thiết lập của database phải hiện:

| `key` | `value` | `level` |
| --- | --- | --- |
| `EXTERNAL_VOLUME` | `AQ_ICEBERG_VOL` | `DATABASE` |
| `STORAGE_SERIALIZATION_POLICY` | `COMPATIBLE` | `DATABASE` |
| `ICEBERG_VERSION_DEFAULT` | `3` | `DATABASE` |

Xem file của bảng thử trên S3:

```bash
aws s3 ls s3://aq-lakehouse-<account-id>-us-east-2/lakehouse/smoke_test/ --recursive --region us-east-2
```

Lần chạy thử tạo năm file sau:

| File | Vai trò |
| --- | --- |
| `data/.../*.parquet` | File dữ liệu (một dòng) |
| `metadata/00000-*.metadata.json` | Metadata lúc bảng vừa tạo |
| `metadata/00001-*.metadata.json` | Metadata hiện tại, sau lệnh `INSERT` |
| `metadata/snap-*.avro` | Manifest list của snapshot hiện tại |
| `metadata/*-m0.avro` | Manifest liệt kê file dữ liệu |

Thư mục bảng có hậu tố ngẫu nhiên do Snowflake thêm, ví dụ `hello_iceberg.OwngKGgQ`. Lấy đường dẫn file metadata hiện tại từ kết quả `SYSTEM$GET_ICEBERG_TABLE_INFORMATION` trong file SQL, rồi kiểm tra version (PowerShell):

```powershell
aws s3 cp <metadataLocation> - --region us-east-2 | Select-String '"format-version"'
```

Kết quả phải chứa `"format-version":3`.

Xem xong, xóa bảng thử trong Snowsight:

```sql
DROP SCHEMA AQ_LAKEHOUSE.SMOKE_TEST;
```

Dừng tại đây. Bước tiếp theo là triển khai Openflow BYOC trong `us-east-2`. Khi tạm dừng project, giữ nguyên stack `aq-iceberg-storage`: S3 gần như không tốn phí, và giữ stack thì không phải làm lại hai lần deploy.
