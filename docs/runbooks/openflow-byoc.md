# Openflow BYOC: PostgreSQL CDC vào Bronze

Chạy từ thư mục gốc của repo. Runbook này dựng Openflow BYOC trong VPC của `postgres-ec2.md`. Sau đó, bạn tạo runtime và connector PostgreSQL để ghi vào các bảng Iceberg của `AQ_LAKEHOUSE`, rồi kiểm tra snapshot và CDC. Phần cuối là dọn dẹp.

Cần làm xong trước:

- `iceberg-storage.md`: bucket `aq-lakehouse-<account-id>-us-east-2`, external volume `AQ_ICEBERG_VOL`, database `AQ_LAKEHOUSE`, warehouse `AQ_WH`.
- `postgres-ec2.md`: stack `aq-postgres-ec2` ở trạng thái `CREATE_COMPLETE`.

Openflow không có trên tài khoản trial. Nếu menu **Ingestion** của Snowsight không có **Openflow**, nâng tài khoản lên trả phí (Admin → Billing). Phần credit trial còn lại vẫn được dùng trước.

Các lệnh `aws` trong runbook được viết cho PowerShell. Các lệnh SQL chạy trong worksheet của Snowsight.

## 1. Role và quyền trên Snowflake

Openflow không cho phép đăng nhập bằng `ACCOUNTADMIN` hoặc các role quản trị khác, nên các thao tác Openflow dùng role riêng `openflow_admin`. Runtime chạy dưới role `OPENFLOW_AQ_RUNTIME_EXECUTE_AS_RL`, cần quyền ghi vào `AQ_LAKEHOUSE` và đọc secret chứa mật khẩu PostgreSQL.

Mở `snowflake/02b_openflow_access.sql` trong Snowsight và chạy toàn bộ bằng **Run all** (`Ctrl + Shift + Enter`). File chạy lại được và không cần sửa gì: tên user của bạn được lấy bằng `CURRENT_USER()`. File làm các việc sau:

1. Tạo role `openflow_admin` và cấp quyền tạo deployment, database và integration.
2. Tạo database `AQ_OPENFLOW` và schema `CONTROL`, nơi chứa runtime, connector và secret, tách khỏi `AQ_LAKEHOUSE`.
3. Tạo role `OPENFLOW_AQ_RUNTIME_EXECUTE_AS_RL` cho runtime, cấp quyền dùng `AQ_OPENFLOW.CONTROL`, warehouse `AQ_WH`, `AQ_LAKEHOUSE` (kèm quyền tạo schema, vì connector tạo schema `AQ`) và external volume `AQ_ICEBERG_VOL`.
4. Gán `openflow_admin` cho user của bạn và đặt làm role mặc định. Role phụ phải để trống, nếu không `ACCOUNTADMIN` bị gửi kèm và trang đăng nhập Openflow bị chặn.
5. Tạo secret `aq_pg_replicator_password` chứa mật khẩu của `openflow_replicator` (giá trị `replicator123` lúc deploy stack PostgreSQL), rồi cấp `READ` trên secret cho role runtime. Runtime cần `READ` để lấy mật khẩu, quyền `USAGE` không đủ. `CREATE OR REPLACE` làm mất các quyền đã cấp trước đó, nên file luôn cấp lại `READ` sau khi tạo secret.

Đăng xuất rồi đăng nhập lại Snowsight để role mới có hiệu lực. Góc dưới bên trái phải hiện `OPENFLOW_ADMIN`.

Kiểm tra (chạy trong một file SQL mới; biến `$me` chỉ tồn tại trong phiên đã khai báo nó nên phải `SET` lại):

```sql
SET me = CURRENT_USER();
SHOW GRANTS TO USER IDENTIFIER($me);
SHOW SECRETS IN SCHEMA AQ_OPENFLOW.CONTROL;
```

Kết quả đúng: `SHOW GRANTS` có dòng `OPENFLOW_ADMIN`, `SHOW SECRETS` có `AQ_PG_REPLICATOR_PASSWORD` với chủ sở hữu `OPENFLOW_ADMIN`.

## 2. Tạo deployment

1. Trong Snowsight, dùng role `OPENFLOW_ADMIN`, vào **Ingestion** → **Openflow**. Lần đầu, trang hiện nút **Launch Openflow**; bấm nút này để mở giao diện Openflow. Nếu menu không có Openflow hoặc nút bị khóa, tài khoản trial cần được nâng lên trả phí (Admin → Billing) trước. Sau đó vào tab **Deployments** → **Create deployment**.
2. Đặt tên `aq_openflow_aws`, chọn **BYOC** trên **AWS**, region `us-east-2`, và chọn **Bring your own VPC**.
3. Tải template CloudFormation về `infra/cloudformation/aq-openflow-aws.yaml`.

Template đã có sẵn cấu hình của deployment (khóa, URL, OAuth). Bạn chỉ cần truyền VPC, hai private subnet và security group, đều lấy từ đầu ra của stack `aq-postgres-ec2`.

Template chứa secret OAuth của deployment. **Không commit file này.** Thêm dòng sau vào `.gitignore`:

```
infra/cloudformation/aq-openflow-aws.yaml
```

Deploy:

```powershell
$env:AWS_PAGER = ""
$env:AWS_CLI_FILE_ENCODING = "UTF-8"

$out = aws cloudformation describe-stacks --stack-name aq-postgres-ec2 --region us-east-2 --query "Stacks[0].Outputs" | ConvertFrom-Json
$o = @{}; $out | ForEach-Object { $o[$_.OutputKey] = $_.OutputValue }

aws cloudformation deploy --template-file infra/cloudformation/aq-openflow-aws.yaml --stack-name aq-openflow --capabilities CAPABILITY_IAM CAPABILITY_NAMED_IAM --region us-east-2 --parameter-overrides InfraVPC=$($o.VpcId) PrivateSubnet1=$($o.PrivateSubnetAId) PrivateSubnet2=$($o.PrivateSubnetBId) PrivateSecurityGroup=$($o.OpenflowSecurityGroupId)
```

`PrivateSubnet1` là private subnet A, cùng subnet với EC2 PostgreSQL. Template không hỏi public subnet: Openflow tự tìm hai public subnet có tag `kubernetes.io/role/elb`, đã được gắn sẵn trong stack PostgreSQL.

Stack đạt `CREATE_COMPLETE` sau vài phút. Sau đó, agent EC2 trong stack tiếp tục dựng EKS, RDS và load balancer. Đây là bước chờ lâu nhất của runbook, khoảng 45 phút, bạn có thể làm việc khác trong lúc chờ. Theo dõi tab **Deployments** đến khi `aq_openflow_aws` chuyển sang **Active**, hoặc:

```sql
USE ROLE openflow_admin;
SHOW OPENFLOW DEPLOYMENTS;
```

## 3. Tạo runtime

Tên deployment được lưu ở dạng chữ thường nên phải đặt trong dấu nháy kép:

```sql
USE ROLE openflow_admin;
USE SCHEMA AQ_OPENFLOW.CONTROL;

CREATE OPENFLOW RUNTIME aq_runtime
  IN DEPLOYMENT "aq_openflow_aws"
  NODE_TYPE = SMALL
  NODE_TYPE_TIER = 'S1'
  MIN_NODES = 1
  MAX_NODES = 1
  EXECUTE_AS_ROLE = OPENFLOW_AQ_RUNTIME_EXECUTE_AS_RL
  DISPLAY_NAME = 'AQ Runtime';

SHOW OPENFLOW RUNTIMES;
```

Runtime chuyển từ `CREATING` sang `ACTIVE` sau khoảng 5 phút. Khi đó, vào lại **Openflow** → tab **Runtimes** và mở `AQ Runtime`. Snowflake sẽ hỏi cấp quyền cho ứng dụng `SF$OAUTH$OPENFLOW_RUNTIME_...` với role `OPENFLOW_ADMIN`. Bấm **Allow**.

## 4. Tạo connector PostgreSQL

Connector cần driver JDBC của PostgreSQL. Tải bản **Java 8** mới nhất (`postgresql-42.7.x.jar`) từ [jdbc.postgresql.org/download](https://jdbc.postgresql.org/download/).

Vào tab **Connector library**, chọn thẻ **PostgreSQL** có nhãn **Gen 2**, bấm **Install**, rồi làm theo thứ tự:

1. Ở **Select runtime**, chọn `AQ Runtime`.
2. Đặt tên connector là `aq_postgres_cdc`, rồi bấm **Begin installation**. Các bước cấu hình chỉ hiện sau khi bấm nút này.

Bỏ qua gợi ý dùng CoCo để kiểm tra điều kiện, vì các điều kiện đã có từ bước 1 và `postgres-ec2.md`.

Mỗi bước của wizard có nút **Verify configuration**. Bấm nút này trước khi sang bước tiếp. Các mục không nhắc dưới đây để mặc định.

### Source

| Mục | Giá trị |
| --- | --- |
| Source Database Connection URL | `jdbc:postgresql://<PostgresPrivateIp>:5432/airquality` |
| Source Database Driver | File `.jar` vừa tải |
| Source Database User | `openflow_replicator` |
| Source Database Password | Secret `AQ_PG_REPLICATOR_PASSWORD` |
| Source Database Publication Name | `openflow_aq_pub` |
| Configure Logical Keys | `Default Primary Key Support` |

`Default Primary Key Support` dùng khóa chính của bảng nguồn làm khóa để gộp thay đổi; chỉ cần đổi khi bảng không có khóa chính.

Lấy `<PostgresPrivateIp>`:

```powershell
aws cloudformation describe-stacks --stack-name aq-postgres-ec2 --region us-east-2 --query "Stacks[0].Outputs[?OutputKey=='PostgresPrivateIp'].OutputValue" --output text
```

Ô Password chỉ liệt kê secret mà runtime đọc được. Nếu ô trống, xem lại quyền `READ` ở bước 1 rồi bấm nút làm mới cạnh ô.

> **[HÌNH 1]** Bước Source của wizard sau khi Verify configuration thành công.

### Replication schemas/tables và Columns

Để mặc định cả hai màn: **Manual selection**, schema `aq` với hai bảng `stations` và `measurements` đã được chọn (2/2), và giữ tất cả cột. Bấm **Verify configuration** rồi **Next** ở mỗi màn. Các bảng phải có trong publication; bảng nào không có sẽ bị bỏ qua mà không báo lỗi.

### Destination details

| Mục | Giá trị |
| --- | --- |
| Snowflake Destination Database | `AQ_LAKEHOUSE` |
| Snowflake Warehouse | `AQ_WH` |
| Destination Schema Strategy | `{schema}` |
| Table Storage Format | `Iceberg` |
| Iceberg Version | `Version 3` |

Ô Iceberg Version chỉ hiện sau khi chọn `Iceberg`. Form không hỏi external volume. Các mục còn lại để mặc định.

Với `{schema}`, schema nguồn `aq` thành schema `AQ_LAKEHOUSE.AQ`. Destination Schema Strategy, Object Identifier Resolution, Legacy Format Support và Iceberg Version không đổi được sau khi connector chạy.

> **[HÌNH 2]** Bước Destination details với Table Storage Format = Iceberg.

### Tuning

Để mặc định. **Merge Task Schedule CRON** đã là `0 * * * * ?` (gộp mỗi phút), mỗi lần gộp dùng warehouse `AQ_WH`. Concurrent Snapshot Queries và Enable Advanced Configuration giữ nguyên.

### Migration

| Mục | Giá trị |
| --- | --- |
| Ingestion Type | `Full` |
| Replication Slot Name | `openflow_aq_slot` |

`Full` chạy snapshot toàn bộ dữ liệu rồi chuyển sang CDC. Ô Replication Slot Name để trống theo mặc định, nên phải điền; slot chưa tồn tại thì connector tạo mới với tên này. Tên cố định giúp theo dõi và dọn slot trên PostgreSQL.

> **[HÌNH 3]** Bước Migration với Ingestion Type = Full và slot `openflow_aq_slot`.

### Bật connector

Sau bước Migration, bấm **Verify configuration** lần cuối, đợi thông báo thành công rồi bấm **Apply**. Connector khởi tạo xong thì chuyển sang trạng thái **Stopped**; chỉ khi đó mới start được. Vào tab **Installed connectors**, mở menu ba chấm của `aq_postgres_cdc` và bấm **Start**, rồi chờ trạng thái chuyển sang **Running**.

## 5. Kiểm tra snapshot

Sau vài phút:

```sql
USE ROLE openflow_admin;
USE WAREHOUSE AQ_WH;

SHOW ICEBERG TABLES IN SCHEMA AQ_LAKEHOUSE.AQ;

SELECT
  (SELECT COUNT(*) FROM AQ_LAKEHOUSE.AQ.STATIONS)     AS stations,
  (SELECT COUNT(*) FROM AQ_LAKEHOUSE.AQ.MEASUREMENTS) AS measurements;
```

| `stations` | `measurements` |
| ---: | ---: |
| 23 | 2117 |

Cả hai bảng có `is_iceberg = Y` trong kết quả `SHOW TABLES`. Lúc này chưa có bảng journal nào: snapshot ban đầu được nạp thẳng vào bảng đích, còn journal của một bảng chỉ được tạo khi bảng đó có thay đổi CDC đầu tiên (xem bước 6).

Trên EC2, slot đã được tạo và đang được đọc:

```powershell
$id = aws cloudformation describe-stacks --stack-name aq-postgres-ec2 --region us-east-2 --query "Stacks[0].Outputs[?OutputKey=='InstanceId'].OutputValue" --output text
aws ssm start-session --target $id --region us-east-2
```

```bash
sudo docker exec aq-postgres psql -U postgres -d airquality -c "SELECT slot_name, active FROM pg_replication_slots;"
```

Kết quả có `openflow_aq_slot` với `active = t`. Lệnh trên chạy trong phiên Session Manager của EC2, không chạy được trong Snowsight.

## 6. Kiểm tra CDC

Chạy từng script trong phiên Session Manager. Sau mỗi script, đợi 1 đến 2 phút cho lần merge kế tiếp, kiểm tra trên Snowflake rồi mới chạy script sau.

**Insert:** thêm dòng `measurement_id = 2118`.

```bash
sudo docker exec aq-postgres psql -U postgres -d airquality -f /workspace/postgres/04_cdc_insert.sql
```

```sql
SELECT COUNT(*) FROM AQ_LAKEHOUSE.AQ.MEASUREMENTS;   -- 2118
```

**Update:** đổi `aqi` và `pm25` của dòng `measurement_id = 320` thành 275.

```bash
sudo docker exec aq-postgres psql -U postgres -d airquality -f /workspace/postgres/05_cdc_update.sql
```

```sql
SELECT MEASUREMENT_ID, MEASURED_AT, AQI, PM25
FROM AQ_LAKEHOUSE.AQ.MEASUREMENTS
WHERE MEASUREMENT_ID = 320;   -- AQI = PM25 = 275.00
```

`MEASURED_AT` hiển thị theo múi giờ của phiên Snowsight (ví dụ `05:00 -0800`), là cùng thời điểm `13:00 UTC` ở PostgreSQL.

**Delete:** xóa dòng `measurement_id = 434`.

```bash
sudo docker exec aq-postgres psql -U postgres -d airquality -f /workspace/postgres/06_cdc_delete.sql
```

```sql
SELECT MEASUREMENT_ID, _SNOWFLAKE_DELETED
FROM AQ_LAKEHOUSE.AQ.MEASUREMENTS
WHERE MEASUREMENT_ID = 434;   -- TRUE
```

Connector không xóa dòng mà đánh dấu bằng cột `_SNOWFLAKE_DELETED`. Khi đọc Bronze ở các tầng sau, lọc `WHERE NOT _SNOWFLAKE_DELETED`.

**Journal so với bảng đích:** sau insert, bảng journal của `MEASUREMENTS` mới xuất hiện (`STATIONS` chưa có vì chưa có thay đổi nào). Lấy tên journal:

```sql
SHOW TABLES LIKE '%JOURNAL%' IN SCHEMA AQ_LAKEHOUSE.AQ;
```

Tên có dạng `MEASUREMENTS_JOURNAL_<epoch>_<số>`. Sau cả ba thao tác, thay `<tên-journal>` bằng tên này rồi so sánh ba dòng ở journal và ở bảng đích:

```sql
SELECT PRIMARY_KEY__MEASUREMENT_ID, PAYLOAD__AQI, EVENT_TYPE, SEEN_AT
FROM AQ_LAKEHOUSE.AQ."<tên-journal>"
ORDER BY SEEN_AT;

SELECT MEASUREMENT_ID, AQI, _SNOWFLAKE_UPDATED_AT, _SNOWFLAKE_DELETED
FROM AQ_LAKEHOUSE.AQ.MEASUREMENTS
WHERE MEASUREMENT_ID IN (2118, 320, 434);
```

Journal có ba dòng, với `EVENT_TYPE` lần lượt là `IncrementalInsertRows` (2118), `IncrementalUpdateRows` (320, kèm giá trị mới, `PAYLOAD__AQI = 275`) và `IncrementalDeleteRows` (434, chỉ có khóa chính, các cột `PAYLOAD__*` để trống). Journal giữ lại các dòng sau khi đã gộp, còn bảng đích chỉ giữ một dòng cho mỗi khóa: dòng 434 vẫn còn, mang `_SNOWFLAKE_DELETED = TRUE` và giá trị cuối cùng trước khi xóa.

Các cột của journal:

| Cột | Ý nghĩa |
| --- | --- |
| `PRIMARY_KEY__*` | Khóa chính của dòng |
| `PAYLOAD__*` | Giá trị các cột của dòng sau thay đổi (trống với delete) |
| `LEAST_SIGNIFICANT_POSITION`, `MOST_SIGNIFICANT_POSITION` | Vị trí của thay đổi trong transaction log |
| `EVENT_TYPE` | `IncrementalInsertRows`, `IncrementalUpdateRows` hoặc `IncrementalDeleteRows` |
| `SEEN_AT` | Thời điểm connector nhận thay đổi |
| `SF_METADATA` | Metadata, gồm `offset_token` |

Không sửa cấu trúc hoặc xóa journal khi connector đang chạy, vì connector dùng chúng để cập nhật bảng đích.

## Dọn dẹp

Bảng Bronze là bảng Iceberg nằm trong bucket S3 của bạn, không thuộc hạ tầng Openflow. Xóa Openflow và stack PostgreSQL không làm mất dữ liệu Bronze. Bạn vẫn có thể xây dựng các tầng Silver và Gold hoặc truy vấn dữ liệu bằng DuckDB mà không cần Openflow chạy. **Không xóa stack `aq-iceberg-storage`**, vì stack này giữ bucket và IAM role của `AQ_ICEBERG_VOL`.

Chỉ nghỉ vài giờ thì không cần dọn hết: dừng connector (**Stop**) và dừng EC2 PostgreSQL bằng `aws ec2 stop-instances`. Hạ tầng Openflow (EKS, RDS, NAT Gateway) vẫn tính phí theo giờ khi còn tồn tại, nên nghỉ lâu hơn thì dọn theo thứ tự dưới đây.

### 1. Connector và runtime

Trong tab **Installed connectors**: **Stop**, rồi **Delete** connector `aq_postgres_cdc`. Trong tab **Runtimes**: xóa `AQ Runtime`. Hoặc dùng SQL, `CASCADE` gỡ luôn connector:

```sql
USE ROLE openflow_admin;
ALTER OPENFLOW RUNTIME aq_runtime TERMINATE CASCADE;
-- Đợi SHOW OPENFLOW RUNTIMES báo TERMINATED
DROP OPENFLOW RUNTIME aq_runtime;
```

### 2. Dỡ hạ tầng Openflow bằng `destroy.sh`

Phải chạy `destroy.sh` trên agent EC2 trước khi xóa stack, nếu không EKS và RDS bị bỏ lại và vẫn tính phí. Khi thử nghiệm, agent không đăng ký với Session Manager. Kết nối qua EC2 Instance Connect Endpoint theo hướng dẫn của Snowflake. Trên Windows, khóa tạm mà AWS CLI tự tạo bị `ssh` từ chối vì quyền file, nên tạo khóa riêng:

```powershell
$agent = aws cloudformation describe-stack-resources --stack-name aq-openflow --region us-east-2 --query "StackResources[?ResourceType=='AWS::EC2::Instance'].PhysicalResourceId" --output text

$key = "$HOME\.ssh\aq_agent"
if (-not (Test-Path "$HOME\.ssh")) { New-Item -ItemType Directory "$HOME\.ssh" | Out-Null }
if (-not (Test-Path $key)) { ssh-keygen -t ed25519 -f $key -q -N '""' }
icacls $key /inheritance:r /grant:r "$($env:USERNAME):(R)" | Out-Null

aws ec2-instance-connect send-ssh-public-key --instance-id $agent --instance-os-user ec2-user --ssh-public-key "file://$key.pub" --region us-east-2
aws ec2-instance-connect ssh --instance-id $agent --connection-type eice --private-key-file $key --os-user ec2-user --region us-east-2
```

Khóa đẩy lên agent chỉ có hiệu lực 60 giây, nên hai lệnh cuối phải chạy liền nhau. Trong agent:

```bash
./destroy.sh
```

Script chạy khá lâu vì phải dỡ EKS và RDS, và chạy xong khi in `delete successful`. Nếu mất kết nối, script vẫn chạy nền. Kết nối lại và theo dõi bằng `journalctl -u docker -f -n 250`. Xong thì gõ `exit` để thoát.

### 3. Stack, deployment và stack PostgreSQL

```powershell
aws cloudformation delete-stack --stack-name aq-openflow --region us-east-2
aws cloudformation wait stack-delete-complete --stack-name aq-openflow --region us-east-2
```

Deployment chuyển sang **Terminated**. Trong tab **Deployments**, mở menu ba chấm của `aq_openflow_aws` → **Drop** → **Yes**.

```powershell
aws cloudformation delete-stack --stack-name aq-postgres-ec2 --region us-east-2
aws cloudformation wait stack-delete-complete --stack-name aq-postgres-ec2 --region us-east-2
```

### 4. Kiểm tra không còn tài nguyên tính phí

```powershell
aws cloudformation list-stacks --region us-east-2 --stack-status-filter CREATE_COMPLETE UPDATE_COMPLETE DELETE_FAILED --query "StackSummaries[].StackName" --output text
aws eks list-clusters --region us-east-2 --output text
aws rds describe-db-instances --region us-east-2 --query "DBInstances[].DBInstanceIdentifier" --output text
aws ec2 describe-nat-gateways --region us-east-2 --filter Name=state,Values=available --query "NatGateways[].NatGatewayId" --output text
aws ec2 describe-addresses --region us-east-2 --query "Addresses[].PublicIp" --output text
aws ec2 describe-instances --region us-east-2 --filters Name=instance-state-name,Values=running,stopped --query "Reservations[].Instances[].InstanceId" --output text
aws elbv2 describe-load-balancers --region us-east-2 --query "LoadBalancers[].LoadBalancerName" --output text
```

Trong các kết quả trên không được còn tài nguyên của project này. Stack `aq-iceberg-storage` vẫn được giữ lại.

Nếu lệnh `wait` báo lỗi, xem tài nguyên nào chặn việc xóa:

```powershell
aws cloudformation describe-stack-events --stack-name <tên-stack> --region us-east-2 --query "StackEvents[?ResourceStatus=='DELETE_FAILED'].[LogicalResourceId,ResourceStatusReason]" --output text
```

Xóa các file `$HOME\.ssh\aq_agent`, `$HOME\.ssh\aq_agent.pub` và `infra/cloudformation/aq-openflow-aws.yaml` trên máy local. Template gắn với deployment đã xóa nên không dùng lại được. Lần dựng sau tạo deployment mới và tải template mới.

Các đối tượng Snowflake (`AQ_OPENFLOW`, role, secret, bảng Bronze) được giữ lại và dùng lại được ở lần dựng sau.

Dừng tại đây. Bước tiếp theo là tầng Silver trên các bảng `AQ_LAKEHOUSE.AQ`, trong `silver-candidate.md`.