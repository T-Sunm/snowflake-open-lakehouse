# PostgreSQL trên EC2

Chạy từ thư mục gốc của repo. Các bước dưới đây dựng VPC và một EC2 chạy PostgreSQL trong `us-east-2`. EC2 tự cài Docker, nạp dữ liệu và chuẩn bị logical replication khi khởi động, nên chỉ cần đưa file lên S3, deploy một stack rồi kiểm tra. Phải làm xong trước khi triển khai Openflow BYOC.

Các lệnh `aws` chạy trong terminal trên máy bạn. Riêng phần kiểm tra chạy bên trong EC2 qua Session Manager, nên EC2 không cần IP công khai hoặc cổng SSH.

Trong runbook, `<account-id>` là số tài khoản AWS 12 chữ số, `<instance-id>` là giá trị `InstanceId` trong đầu ra của stack ở bước 2.

## Thiết kế mạng

Openflow BYOC cho phép dùng VPC có sẵn (**Bring your own VPC**), yêu cầu hai public subnet và hai private subnet ở hai availability zone khác nhau. Stack này tạo đúng VPC đó và đặt PostgreSQL vào private subnet 1. Khi tạo deployment Openflow, bạn chọn lại VPC và subnet này, nên Openflow và PostgreSQL cùng một mạng, không cần peering hay tunnel.

| Thành phần | Cấu hình | Lý do |
| --- | --- | --- |
| VPC | `10.20.0.0/16`, bật DNS hostnames | Yêu cầu của EKS |
| 2 public subnet | `/24`, tag `kubernetes.io/role/elb = 1`, route ra Internet Gateway | Openflow tạo Network Load Balancer ở đây |
| 2 private subnet | `/22`, route ra NAT Gateway | Openflow yêu cầu tối thiểu `/24` mỗi subnet |
| NAT Gateway | Ở public subnet A | Private subnet cần đường ra Snowflake và AWS |
| S3 Gateway Endpoint | Gắn vào route table private | Tải dữ liệu từ S3 qua mạng nội bộ AWS |
| EC2 PostgreSQL | `t3.small`, ổ gp3 20 GB mã hóa, private subnet 1 | Cùng private subnet 1, nơi runtime Openflow chạy |
| Security group | Chỉ nhận cổng 5432 từ hai private subnet | Không mở PostgreSQL ra Internet |
| Secrets Manager | Mật khẩu superuser và `openflow_replicator` | EC2 đọc lúc khởi động, mật khẩu không nằm trong script |

Template: `infra/cloudformation/postgres-ec2.yaml`.

## Việc EC2 tự làm khi khởi động

1. Cài Docker và Docker Compose.
2. Kéo `docker-compose.yml` và thư mục `postgres/` từ `s3://aq-lakehouse-<account-id>-us-east-2/postgres-transfer/` về `/opt/aq/`.
3. Đọc mật khẩu từ Secrets Manager và tạo `/opt/aq/.env`.
4. Chạy `docker compose up -d` và chờ container `aq-postgres` ở trạng thái `healthy`.
5. Chạy `01_schema.sql`, `02_load_kaggle.sql` và `03_replication.sql`.
6. Kiểm tra `wal_level = logical` và publication `openflow_aq_pub` có đủ hai bảng, rồi báo kết quả cho CloudFormation.

Stack chỉ đạt `CREATE_COMPLETE` khi cả sáu bước thành công. Nếu một bước lỗi, stack thất bại.

## 1. Đưa file lên S3

Script khởi động lấy file từ bucket `aq-lakehouse-<account-id>-us-east-2` được tạo theo `iceberg-storage.md`. Các file nằm dưới prefix `postgres-transfer/`, tách khỏi `lakehouse/`, nơi Snowflake ghi dữ liệu Iceberg:

```bash
aws s3 sync postgres s3://aq-lakehouse-<account-id>-us-east-2/postgres-transfer/postgres/ --region us-east-2
aws s3 cp docker-compose.yml s3://aq-lakehouse-<account-id>-us-east-2/postgres-transfer/docker-compose.yml --region us-east-2
aws s3 ls s3://aq-lakehouse-<account-id>-us-east-2/postgres-transfer/ --recursive --region us-east-2
```

Lệnh cuối phải liệt kê `docker-compose.yml`, các script `01` đến `06` và `data/historical_air_quality_2021_en.csv`. Thiếu file thì EC2 không khởi động xong và stack thất bại.

## 2. Deploy stack

```bash
aws cloudformation deploy --template-file infra/cloudformation/postgres-ec2.yaml --stack-name aq-postgres-ec2 --capabilities CAPABILITY_IAM --region us-east-2 --parameter-overrides PostgresPassword=<postgres-password> ReplicatorPassword=<replicator-password>
```

Hai mật khẩu phải từ 8 ký tự trở lên, chỉ gồm chữ cái và chữ số. `ReplicatorPassword` là mật khẩu role `openflow_replicator`, sẽ nhập vào connector Openflow. Lần deploy mất khoảng 8 đến 12 phút, phần lớn là chờ NAT Gateway và EC2 chạy script khởi động.

Xem các giá trị đầu ra:

```bash
aws cloudformation describe-stacks --stack-name aq-postgres-ec2 --region us-east-2 --query "Stacks[0].Outputs[].[OutputKey,OutputValue]" --output text
```

| Output | Dùng cho |
| --- | --- |
| `InstanceId` | Kết nối Session Manager |
| `PostgresPrivateIp` | Host PostgreSQL khi tạo connector Openflow |
| `VpcId` | Chọn VPC khi tạo deployment Openflow |
| `PublicSubnetAId`, `PublicSubnetBId` | Hai public subnet của Openflow |
| `PrivateSubnetAId`, `PrivateSubnetBId` | Hai private subnet của Openflow |
| `NatPublicIp` | Chỉ cần nếu Snowflake có network policy |
| `DbSecretArn` | Secret chứa hai mật khẩu |

Ghi lại cả bảng này, runbook Openflow sẽ dùng lại.

## 3. Kiểm tra

Cần cài [Session Manager plugin](https://docs.aws.amazon.com/systems-manager/latest/userguide/session-manager-working-with-install-plugin.html) cho AWS CLI (kiểm tra bằng lệnh `session-manager-plugin`).

```bash
aws ssm start-session --target <instance-id> --region us-east-2
```

Trong EC2:

```bash
sudo docker ps
sudo grep -A3 csv_rows /var/log/aq-bootstrap.log
sudo docker exec aq-postgres psql -U postgres -d airquality -c "SHOW wal_level;" -c "SELECT pubname, schemaname, tablename FROM pg_publication_tables;"
```

Kết quả đúng:

- Container `aq-postgres` ở trạng thái `healthy`.
- Kết quả nạp dữ liệu giống môi trường local:

| `csv_rows` | `skipped_no_id_or_time` | `stations` | `measurements` |
| ---: | ---: | ---: | ---: |
| 3415 | 793 | 23 | 2117 |

- `wal_level` là `logical`, publication `openflow_aq_pub` có `aq.measurements` và `aq.stations`.

Gõ `exit` hai lần để thoát phiên. Việc kết nối từ Openflow tới `<PostgresPrivateIp>:5432` chỉ kiểm tra được sau khi deployment Openflow chạy, nên nằm trong runbook Openflow.

## Mật khẩu

Hai mật khẩu nằm trong Secrets Manager. Muốn xem lại:

```bash
aws secretsmanager get-secret-value --secret-id <DbSecretArn> --region us-east-2 --query SecretString --output text
```

Nếu stack đã tạo mà cần đổi mật khẩu role replication, đổi ngay trong PostgreSQL:

```bash
sudo docker exec aq-postgres psql -U postgres -d airquality -c "ALTER ROLE openflow_replicator WITH PASSWORD '<mật-khẩu-mới>';"
```

Sau đó, chạy lại lệnh deploy ở bước 2 với `ReplicatorPassword` mới trong `--parameter-overrides`. CloudFormation sẽ cập nhật secret mà không thay thế EC2.

## Nếu stack thất bại

Mặc định CloudFormation xóa EC2 khi stack lỗi nên không còn log để xem. Xóa stack lỗi, chờ xóa xong, rồi chạy lại lệnh deploy ở bước 2 kèm `--disable-rollback` để giữ nguyên máy nếu lần deploy tiếp theo thất bại:

```bash
aws cloudformation delete-stack --stack-name aq-postgres-ec2 --region us-east-2
aws cloudformation wait stack-delete-complete --stack-name aq-postgres-ec2 --region us-east-2
```

Nếu lần deploy lại vẫn lỗi, vào EC2 qua Session Manager và đọc log bằng `sudo cat /var/log/aq-bootstrap.log`. Nguyên nhân thường gặp là thiếu file trên S3 (xem lại bước 1). Sửa xong thì xóa stack, bỏ cờ `--disable-rollback` và deploy lại.

## Các script CDC

`04_cdc_insert.sql`, `05_cdc_update.sql` và `06_cdc_delete.sql` đã nằm sẵn ở `/opt/aq/postgres/` trên EC2. Chạy trong phiên Session Manager, chỉ sau khi connector Openflow đã hoàn tất initial snapshot:

```bash
sudo docker exec aq-postgres psql -U postgres -d airquality -f /workspace/postgres/04_cdc_insert.sql
```

## Khi tạm dừng project

- **EC2:** dừng instance để không tốn phí tính toán (`aws ec2 stop-instances --instance-ids <instance-id> --region us-east-2`). Ổ đĩa và IP private được giữ nguyên, container tự chạy lại khi bật máy.
- **NAT Gateway:** tính phí theo giờ dù không có lưu lượng, là khoản tốn nhất của stack. Nếu nghỉ nhiều ngày, xóa stack `aq-postgres-ec2`. Dựng lại chỉ cần chạy lại bước 2 vì EC2 tự nạp dữ liệu, nhưng VPC, subnet và IP sẽ đổi nên phải lấy lại đầu ra.
- **Replication slot:** sau khi connector Openflow tạo slot, đừng dừng connector lâu mà vẫn để EC2 chạy. Slot không có consumer đọc sẽ giữ WAL và làm đầy ổ 20 GB. Theo dõi bằng:

```sql
SELECT slot_name, active, pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn)) AS retained_wal FROM pg_replication_slots;
```

Giữ prefix `postgres-transfer/` trên S3 chừng nào còn có thể dựng lại stack, vì EC2 mới cần kéo file từ đó.

Dừng tại đây. Bước tiếp theo là triển khai Openflow BYOC trong chính VPC này (chọn **Bring your own VPC** với các subnet ở đầu ra của stack).
