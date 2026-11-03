# Mục 2. Đưa dữ liệu từ PostgreSQL vào Bronze

> **[HÌNH 1: tổng quan CDC từ cơ sở dữ liệu nguồn vào bảng Iceberg]** (`muc2-cdc-to-bronze.svg`)

Bronze là tầng chứa dữ liệu thô, giữ gần nguyên cấu trúc của hệ thống nguồn (source system). Khi nguồn là một operational database như PostgreSQL, nơi ứng dụng liên tục ghi dữ liệu, nội dung các bảng luôn thay đổi. Bronze, gồm các bảng Iceberg trên S3, cần theo kịp những thay đổi đó mà không phải sao chép lại toàn bộ bảng sau mỗi lần, và bài toán này được giải bằng kỹ thuật ghi nhận thay đổi dữ liệu (CDC), với nhiều cách tiếp cận khác nhau.

## CDC và các cách tiếp cận

Ở nguồn, dữ liệu thay đổi theo ba cách: dòng mới được thêm, dòng đang có được sửa và dòng bị xóa, và cả ba đều phải được phản ánh sang Bronze để dữ liệu ở đó khớp với nguồn. Trong ba loại này, thao tác xóa khó phát hiện nhất vì dòng bị xóa không còn tồn tại ở nguồn để so sánh.

> **CDC (change data capture)** là nhóm kỹ thuật phát hiện các thay đổi ở hệ thống nguồn rồi áp dụng chúng vào bản sao của dữ liệu ở một hệ thống khác, trong trường hợp này là Bronze.

Có bốn hướng phổ biến để giữ bản sao dữ liệu khớp với nguồn, được so sánh trong bảng sau.

| Cách tiếp cận | Cách hoạt động | Hạn chế chính |
| --- | --- | --- |
| Nạp lại toàn bộ | Sao chép lại toàn bộ bảng theo chu kỳ | Tốn tài nguyên và thời gian khi bảng lớn |
| Truy vấn theo thời gian | Định kỳ lấy các dòng có cột thời gian cập nhật mới hơn lần trước | Không thấy dòng đã bị xóa, và nguồn bắt buộc có cột thời gian luôn được cập nhật |
| Trigger | Trigger trên bảng nguồn ghi mỗi thay đổi vào một bảng phụ | Thêm chi phí cho mọi thao tác ghi ở nguồn |
| Đọc transaction log | Đọc log mà cơ sở dữ liệu đã ghi sẵn | Cần cấu hình ở nguồn, và log phải được giữ lại cho đến khi đọc xong |

So với ba cách còn lại, khi theo dõi thay đổi, đọc transaction log không tạo tải đọc trên các bảng nguồn, không đòi hỏi cột đặc biệt trong bảng và ghi nhận được cả thao tác xóa.

## Snapshot ban đầu và thay đổi liên tục

Một hệ thống CDC dựa trên log làm việc theo hai giai đoạn nối tiếp. Trước hết, snapshot ban đầu sao chép toàn bộ các dòng hiện có để tạo điểm xuất phát cho bảng Bronze (khác với snapshot của Iceberg), sau đó hệ thống chỉ theo dõi và áp dụng các thay đổi mới mà không đọc lại bảng nguồn. Bước sao chép ban đầu là cần thiết vì log chỉ ghi lại các thay đổi, không chứa dữ liệu đã có sẵn từ trước.

## Transaction log và logical replication

Giai đoạn thay đổi liên tục đọc thay đổi từ transaction log của cơ sở dữ liệu nguồn thay vì truy vấn các bảng. Log này vốn có sẵn trong operational database để phục hồi dữ liệu sau sự cố, và CDC tận dụng nó mà không cần can thiệp vào các bảng nguồn.

> **Transaction log** (gọi tắt là log) là nhật ký ghi lại mọi `INSERT`, `UPDATE` và `DELETE` theo đúng thứ tự xảy ra. Trong PostgreSQL, log này gọi là **WAL** (write-ahead log).

Để hệ thống bên ngoài đọc được log này, PostgreSQL cung cấp logical replication, cơ chế giải mã WAL thành các thay đổi của từng dòng rồi phát chúng đi. Cơ chế này theo mô hình publisher–subscriber: operational database là publisher, còn dịch vụ CDC trong bài là subscriber. Để xác định dòng nào bị cập nhật hoặc xóa, mỗi thay đổi mang theo định danh của dòng (replica identity), mặc định là khóa chính. Logical replication được thiết lập bằng hai đối tượng:

- **Publication** xác định tập bảng mà publisher phát thay đổi.
- **Replication slot** lưu vị trí mà subscriber đã đọc đến trong log. Cơ sở dữ liệu giữ lại phần log chưa được đọc, nên subscriber dừng rồi chạy lại vẫn không bỏ sót thay đổi nào, nhưng đổi lại, một slot không còn ai đọc sẽ khiến log tích lũy và chiếm dung lượng ổ đĩa của nguồn.

Ở phía subscriber, dịch vụ CDC thực hiện snapshot ban đầu, sau đó đọc luồng thay đổi từ slot để ghi vào Bronze, và xác nhận tiến độ để slot dịch vị trí lên phía trước.

> **[HÌNH 2: transaction log, publication và replication slot]** (`muc2-publication-replication-slot.png`)

## Từ transaction log đến Bronze

Log chỉ cho biết những gì đã thay đổi, còn việc đưa các thay đổi đó vào bảng Bronze do dịch vụ CDC đảm nhiệm qua hai bước tách biệt, gồm ghi nhận từng thay đổi rồi gộp chúng vào bảng theo khóa chính. Bước đầu ghi vào một bảng gọi là change log.

> **Change log** (connector Openflow gọi bảng này là journal) là bảng phụ nằm cạnh bảng Bronze, ghi lại từng thay đổi nhận từ nguồn cùng thao tác và giá trị của dòng tại thời điểm đó.

Ở bước thứ hai, theo một lịch định sẵn, các thay đổi chưa xử lý trong change log được gộp (merge) vào bảng Bronze, trong đó dòng chưa có thì được thêm còn dòng đã có thì được cập nhật theo khóa chính. Lịch gộp tạo ra độ trễ giữa lúc nhận thay đổi và lúc chúng xuất hiện trong Bronze, và lịch càng dày thì độ trễ càng ngắn.

## Xử lý thao tác xóa

Bước gộp ở trên áp dụng trực tiếp được cho `INSERT` và `UPDATE`, vì Bronze chỉ cần thêm hoặc sửa dòng tương ứng. Với `DELETE` thì không đơn giản như vậy, bởi xóa dòng khỏi Bronze sẽ làm mất dữ liệu mà các tầng sau có thể còn cần, nên cách xử lý thường gặp là soft delete.

> **Soft delete** là cách xử lý thao tác xóa bằng việc đánh dấu dòng đã bị xóa thay vì xóa vật lý khỏi Bronze.

Hệ quả là các tầng sau tự quyết định có giữ hay bỏ dòng đã xóa, và mọi truy vấn lấy trạng thái hiện tại phải loại các dòng có dấu xóa. Trong ví dụ ở hình dưới, dòng có key 7 vẫn còn trong Bronze nhưng mang dấu xóa, nên truy vấn trạng thái hiện tại chỉ trả về dòng có key 8.

> **[HÌNH 3: từ change log đến trạng thái hiện tại]** (`muc2-change-log-current-state.svg`)

## 2.1. Chuẩn bị hạ tầng

Trước khi bắt đầu nạp dữ liệu, pipeline cần hai thứ nằm sẵn trong tài khoản AWS của bạn: nơi Snowflake lưu các file Iceberg của Bronze và một PostgreSQL nguồn mà Openflow truy cập được. Cả hai đều được dựng bằng AWS CloudFormation, nên có thể dựng lại hoặc xóa riêng từng stack. Các lệnh đầy đủ của mục này nằm trong hai runbook `iceberg-storage.md` và `postgres-ec2.md`.

### Lưu trữ Iceberg trên S3

Một bảng Iceberg gồm các file dữ liệu Parquet và các file metadata mô tả chúng, và cả hai đều nằm trong object storage. Với Snowflake-managed Iceberg table, Snowflake là bên ghi các file này, còn bucket S3 thuộc tài khoản AWS của bạn, nên vị trí lưu trữ và quyền ghi phải được khai báo bằng một external volume.

> **External volume** là đối tượng của Snowflake lưu vị trí của một bucket S3 và IAM role mà Snowflake sẽ assume để đọc, ghi file trong bucket đó.

Mọi tài nguyên AWS của project đặt cùng region với tài khoản Snowflake (`us-east-2`) để tránh phí truyền dữ liệu giữa các region.

Stack `aq-iceberg-storage` tạo bucket `aq-lakehouse-<account-id>-us-east-2` và IAM role cho Snowflake. Bucket chặn truy cập công khai, mã hóa sẵn và chỉ nhận kết nối HTTPS. Role chỉ được đọc và ghi trong thư mục `lakehouse/`, nên các file khác trong bucket nằm ngoài phạm vi của Snowflake.

```bash
aws cloudformation deploy --template-file infra/cloudformation/iceberg-storage.yaml --stack-name aq-iceberg-storage --capabilities CAPABILITY_NAMED_IAM --region us-east-2
```

Việc cấp quyền giữa AWS và Snowflake phải được thiết lập theo hai chiều, và mỗi bên chỉ có thông tin cần thiết sau khi bên kia tạo xong. Role cần biết Snowflake sẽ assume nó bằng IAM user nào, nhưng IAM user này chỉ được Snowflake sinh ra khi external volume được tạo, mà external volume lại cần ARN của role. Vì vậy các bước đi theo thứ tự AWS, Snowflake, AWS, Snowflake, với số thứ tự như trong hình.

> **[HÌNH 4: Luồng cấp quyền giữa AWS và Snowflake, thiết lập (bước 1 đến 5) và ghi dữ liệu vào S3 (bước 6 đến 8)]** (`muc2-external-volume-aws-trust.svg`)

Lần deploy đầu cho ra ba giá trị `StorageBaseUrl`, `RoleArn` và `ExternalId`, trong đó `ExternalId` là chuỗi dùng chung mà role yêu cầu mỗi khi Snowflake assume nó. Ba giá trị này được điền vào Part A của `snowflake/01_external_volume.sql` để tạo external volume. Lần deploy thứ hai truyền `SnowflakeIamUserArn` (đọc từ external volume vừa tạo) để trust policy cho phép IAM user của Snowflake assume role, và output `TrustReady` chuyển từ `false` sang `true` khi lần này xong.

Chuỗi assume role khi chạy được kiểm tra bằng Part B của cùng file SQL. Trust policy cần vài chục giây để có hiệu lực sau lần deploy thứ hai, nên nếu `success` là `false` thì chờ khoảng một phút rồi chạy lại. Kết quả đúng là cả năm phép thử đều `PASSED`:

```json
{"success":true,"writeResult":"PASSED","readResult":"PASSED","listResult":"PASSED","deleteResult":"PASSED","awsRoleArnValidationResult":"PASSED"}
```

File `snowflake/02_database.sql` tạo warehouse `AQ_WH` (XSMALL, tự tạm dừng sau 60 giây) và database `AQ_LAKEHOUSE` với ba thiết lập mặc định cho Iceberg:

| Thiết lập | Giá trị | Vai trò |
| --- | --- | --- |
| `EXTERNAL_VOLUME` | `AQ_ICEBERG_VOL` | Bảng Iceberg tạo trong database tự dùng volume này |
| `STORAGE_SERIALIZATION_POLICY` | `COMPATIBLE` | File được ghi theo cách các engine khác đọc được, cần cho DuckDB ở mục 4 |
| `ICEBERG_VERSION_DEFAULT` | `3` | Bảng mới dùng Iceberg v3 |

Cũng trong file này, bảng thử `SMOKE_TEST.HELLO_ICEBERG` được tạo và ghi một dòng để xác nhận các thiết lập đã được áp dụng, với file metadata của bảng trong bucket chứa `"format-version":3`. Sau khi kiểm tra, xóa schema thử bằng `DROP SCHEMA AQ_LAKEHOUSE.SMOKE_TEST;`.

### PostgreSQL nguồn trên EC2

PostgreSQL chạy trong một container Docker trên EC2 `t3.small`, đặt trong VPC do stack `aq-postgres-ec2` tạo. Openflow ở mục 2.2 sẽ được triển khai vào chính VPC này (tùy chọn **Bring your own VPC**), nên hai bên cùng một mạng và không cần peering hay tunnel.

Openflow BYOC yêu cầu hai public subnet và hai private subnet ở hai availability zone khác nhau, và stack dựng cấu trúc đó:

| Thành phần | Cấu hình | Lý do |
| --- | --- | --- |
| VPC | `10.20.0.0/16`, bật DNS hostnames | Yêu cầu của EKS |
| 2 public subnet | `/24`, route ra Internet Gateway, tag `kubernetes.io/role/elb = 1` | Nơi Openflow tạo Network Load Balancer |
| 2 private subnet | `/22`, route ra NAT Gateway | Openflow yêu cầu tối thiểu `/24` mỗi subnet |
| NAT Gateway | Ở public subnet A | Private subnet cần đường ra Snowflake và AWS |
| S3 Gateway Endpoint | Gắn vào route table private | Tải dữ liệu từ S3 qua mạng nội bộ AWS |
| EC2 PostgreSQL | `t3.small`, ổ gp3 20 GB mã hóa, private subnet 1 | Cùng subnet với nơi runtime Openflow chạy |
| Security group | Chỉ nhận cổng 5432 từ hai private subnet | PostgreSQL không mở ra Internet |
| Secrets Manager | Mật khẩu superuser và `openflow_replicator` | EC2 đọc lúc khởi động, mật khẩu không nằm trong script |

EC2 không có IP công khai và không mở cổng SSH, nên việc kiểm tra bên trong máy đi qua Session Manager.

Khi khởi động, EC2 tự dựng container PostgreSQL từ các file trong bucket, nạp dữ liệu chất lượng không khí năm 2021 và chuẩn bị logical replication. Sau đó EC2 tự kiểm tra `wal_level = logical` và publication `openflow_aq_pub` rồi báo kết quả cho CloudFormation, nên stack chỉ đạt `CREATE_COMPLETE` khi cả quá trình thành công.

Các file khởi động gồm `docker-compose.yml` và thư mục `postgres/` của repo, trong đó có các script SQL, file dữ liệu CSV và ba script 04 đến 06 dùng cho phần CDC ở mục 2.3. Các file này phải được đưa lên prefix `postgres-transfer/` của bucket trước khi deploy, vì thiếu file thì EC2 không khởi động xong và stack thất bại:

```powershell
$bucket = "aq-lakehouse-$(aws sts get-caller-identity --query Account --output text)-us-east-2"

aws s3 sync postgres s3://$bucket/postgres-transfer/postgres/ --region us-east-2
aws s3 cp docker-compose.yml s3://$bucket/postgres-transfer/docker-compose.yml --region us-east-2
```

Prefix này tách khỏi `lakehouse/`, nơi Snowflake ghi dữ liệu Iceberg. EC2 kéo các file về `/opt/aq/`, và container PostgreSQL thấy các script ở `/workspace/postgres`.

Hai mật khẩu trong lệnh deploy dưới đây là giá trị mẫu cho môi trường thử nghiệm, còn ngoài môi trường này thì nên tự đặt mật khẩu mạnh.

```bash
aws cloudformation deploy --template-file infra/cloudformation/postgres-ec2.yaml --stack-name aq-postgres-ec2 --capabilities CAPABILITY_IAM --region us-east-2 --parameter-overrides PostgresPassword=postgres123 ReplicatorPassword=replicator123
```

Các giá trị đầu ra của stack được dùng lại ở các bước sau: `InstanceId` để kết nối Session Manager, `PostgresPrivateIp` làm host khi tạo connector, còn VPC, subnet và security group được chọn lại khi tạo deployment Openflow.

> **[HÌNH 5: Các giá trị đầu ra của stack `aq-postgres-ec2`]** (`muc2-postgres-ec2-outputs.png`)

Để kiểm tra, mở phiên Session Manager vào EC2 rồi truy vấn PostgreSQL trong container:

```powershell
$id = aws cloudformation describe-stacks --stack-name aq-postgres-ec2 --region us-east-2 --query "Stacks[0].Outputs[?OutputKey=='InstanceId'].OutputValue" --output text
aws ssm start-session --target $id --region us-east-2
```

```bash
sudo docker ps
sudo grep -A3 csv_rows /var/log/aq-bootstrap.log
sudo docker exec aq-postgres psql -U postgres -d airquality -c "SHOW wal_level;" -c "SELECT pubname, schemaname, tablename FROM pg_publication_tables;"
```

Ba điều cần xác nhận là container `aq-postgres` ở trạng thái `healthy`, `wal_level` là `logical` cùng publication `openflow_aq_pub` có đủ hai bảng, và dữ liệu đã nạp xong. Số trạm (23) và số phép đo (2117) là mốc để đối chiếu với Bronze sau initial snapshot ở mục 2.2.

> **[HÌNH 6: Kết quả kiểm tra PostgreSQL trên EC2, gồm container, log nạp dữ liệu, `wal_level` và publication]** (`muc2-postgres-ec2-verification.png`)

## 2.2. Triển khai Openflow và initial snapshot

Openflow BYOC chạy trong chính tài khoản AWS của bạn và được tổ chức thành hai tầng.

- **Deployment** là hạ tầng nền, gồm cụm EKS, RDS và load balancer được dựng trong VPC của bạn, và mất hơn 45 phút để dựng xong.
- **Runtime** là môi trường bên trong deployment nơi connector chạy, dưới một role Snowflake riêng để role này quyết định connector được ghi vào đâu.

Connector PostgreSQL chạy trong runtime và đóng vai trò dịch vụ CDC trong mô hình ở phần giới thiệu mục 2: nó là subscriber của publication, thực hiện initial snapshot rồi đọc thay đổi từ replication slot.

### Deployment

Mọi thao tác Openflow, từ tạo deployment đến tạo runtime, cần một role Snowflake riêng, vì Openflow không cho đăng nhập bằng ACCOUNTADMIN hoặc các role quản trị khác. File `snowflake/02b_openflow_access.sql` tạo role OPENFLOW_ADMIN cho các thao tác này, cùng role chạy runtime, database AQ_OPENFLOW và secret chứa mật khẩu của `openflow_replicator` (đặt ở mục 2.1) kèm quyền đọc cho role runtime. File cũng đặt OPENFLOW_ADMIN làm role mặc định và đặt role phụ (các role khác được kích hoạt cùng role chính) về rỗng, để ACCOUNTADMIN không bị gửi kèm khi đăng nhập Openflow.

Sau khi chạy file, đăng xuất rồi đăng nhập lại Snowsight để các thiết lập mặc định có hiệu lực.

Với role OPENFLOW_ADMIN, vào **Ingestion** → **Openflow**, bấm **Launch Openflow** ở lần đầu rồi chọn **Deployments** → **Create deployment**. Đặt tên `aq_openflow_aws`, chọn **BYOC** trên **AWS**, region `us-east-2` và **Bring your own VPC**.

> **[HÌNH 7: Chọn nơi triển khai deployment, BYOC trên AWS, region us-east-2]** (`muc2-openflow-deployment-location.png`)

> **[HÌNH 8: Cấu hình deployment với Bring your own VPC]** (`muc2-openflow-deployment-config.png`)

Sau khi bấm **Create deployment**, Snowflake cung cấp một template CloudFormation đã chứa cấu hình của deployment. Template được tải về `infra/cloudformation/aq-openflow-aws.yaml` và chỉ cần truyền thêm VPC, hai private subnet và security group, lấy từ đầu ra của stack ở mục 2.1 (template chứa secret OAuth nên không được commit lên Git).

> **[HÌNH 9: Hộp thoại sau khi tạo deployment, cung cấp template CloudFormation]** (`muc2-openflow-deployment-created.png`)

```powershell
$out = aws cloudformation describe-stacks --stack-name aq-postgres-ec2 --region us-east-2 --query "Stacks[0].Outputs" | ConvertFrom-Json
$o = @{}; $out | ForEach-Object { $o[$_.OutputKey] = $_.OutputValue }

aws cloudformation deploy --template-file infra/cloudformation/aq-openflow-aws.yaml --stack-name aq-openflow --capabilities CAPABILITY_IAM CAPABILITY_NAMED_IAM --region us-east-2 --parameter-overrides InfraVPC=$($o.VpcId) PrivateSubnet1=$($o.PrivateSubnetAId) PrivateSubnet2=$($o.PrivateSubnetBId) PrivateSecurityGroup=$($o.OpenflowSecurityGroupId)
```

PrivateSubnet1 là private subnet A, cùng subnet với EC2 PostgreSQL. Template không hỏi public subnet vì Openflow tự tìm hai subnet có tag `kubernetes.io/role/elb`, đã được gắn ở mục 2.1.

Stack hoàn tất sau vài phút, rồi agent EC2 trong stack tiếp tục dựng EKS, RDS và load balancer. Deployment sẵn sàng khi trạng thái chuyển sang **Active**.

> **[HÌNH 10: Deployment aq_openflow_aws ở trạng thái Active]** (`muc2-openflow-deployment-active.png`)

### Runtime

Khi deployment đã Active, runtime được tạo bên trong nó bằng SQL dưới role OPENFLOW_ADMIN. Tên deployment phải đặt trong dấu nháy kép vì được lưu ở dạng chữ thường:

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
```

Runtime được cấu hình một node cố định (`MIN_NODES = MAX_NODES = 1`). Sau khoảng 5 phút, `SHOW OPENFLOW RUNTIMES` báo ACTIVE. Khi đó, vào lại **Openflow** → **Runtimes**, mở AQ Runtime và chọn **Allow** ở lời nhắc cấp quyền cho ứng dụng của runtime.

### Connector PostgreSQL

Khi runtime đã sẵn sàng, connector PostgreSQL được cài vào đó. Việc đầu tiên là tải driver JDBC của PostgreSQL từ [trang tải của driver](https://jdbc.postgresql.org/download/), chọn bản Java 8 mới nhất (`postgresql-42.7.x.jar`), vì connector dùng driver này để kết nối tới nguồn. Sau đó, trong **Connector library**, chọn PostgreSQL **Gen 2**, bấm **Install**, chọn AQ Runtime ở **Select runtime**, đặt tên `aq_postgres_cdc` rồi bấm **Begin installation**. Các bước cấu hình hiện ra từ đây theo thứ tự Source, Replication, Destination details, Tuning và Migration, và mỗi bước nên được **Verify configuration** trước khi sang bước kế tiếp.

Bước **Source** cho connector biết cách kết nối tới PostgreSQL, gồm địa chỉ, driver, tài khoản và publication cần đọc. Mật khẩu được chọn từ secret đã tạo ở phần trên thay vì nhập trực tiếp. Riêng Configure Logical Keys giữ Default Primary Key Support, tức là connector dùng khóa chính của bảng để xác định dòng khi gộp thay đổi. Khóa chính cũng là replica identity mặc định của PostgreSQL, nên chỉ bảng không có khóa chính mới cần đổi tùy chọn này. Địa chỉ dùng PostgresPrivateIp, lấy từ đầu ra của stack ở mục 2.1 bằng lệnh sau:

```powershell
aws cloudformation describe-stacks --stack-name aq-postgres-ec2 --region us-east-2 --query "Stacks[0].Outputs[?OutputKey=='PostgresPrivateIp'].OutputValue" --output text
```

| Trường | Giá trị |
| --- | --- |
| Source Database Connection URL | `jdbc:postgresql://<PostgresPrivateIp>:5432/airquality` |
| Source Database Driver | File `.jar` vừa tải |
| Source Database User | `openflow_replicator` |
| Source Database Password | Secret `AQ_PG_REPLICATOR_PASSWORD` |
| Source Database Publication Name | `openflow_aq_pub` |
| Configure Logical Keys | `Default Primary Key Support` |

> **[HÌNH 11: Bước Source sau khi Verify configuration thành công]** (`muc2-postgres-connector-source.png`)

Hai bước tiếp theo xác định dữ liệu nào được sao chép và ghi vào đâu. Ở **Replication**, giữ mặc định là schema aq với hai bảng stations và measurements cùng tất cả cột, và hai bảng này phải nằm trong publication, nếu không connector bỏ qua mà không báo lỗi. Ở **Destination details**, Bronze được ghi vào database AQ_LAKEHOUSE bằng warehouse AQ_WH, và với Destination Schema Strategy giữ `{schema}` thì schema nguồn aq trở thành AQ_LAKEHOUSE.AQ. **Table Storage Format** được đổi từ Standard sang Iceberg, sau đó ô **Iceberg Version** xuất hiện và được chọn là Version 3. Form không hỏi external volume vì bảng Bronze nhận thiết lập của database lúc được tạo (mục 2.1), và một số mục như Destination Schema Strategy hay Iceberg Version không đổi được sau khi connector chạy.

> **[HÌNH 12: Bước Destination details với Table Storage Format là Iceberg và Iceberg Version là Version 3]** (`muc2-postgres-connector-destination.png`)

Hai bước cuối điều khiển nhịp và cách khởi động của connector. **Tuning** giữ mặc định, với lịch gộp `0 * * * * ?` tức là gộp thay đổi vào Bronze mỗi phút, và lịch này quyết định độ trễ như ở phần giới thiệu. Ở **Migration**, Ingestion Type giữ Full để connector chạy initial snapshot rồi chuyển sang CDC (Incremental bỏ qua snapshot nên dữ liệu có sẵn không được sao chép), còn Replication Slot Name cần điền `openflow_aq_slot` vì ô này để trống theo mặc định, và nếu slot chưa có thì connector tạo mới.

> **[HÌNH 13: Bước Migration với Ingestion Type là Full và replication slot openflow_aq_slot]** (`muc2-postgres-connector-migration.png`)

Sau Migration, bấm **Verify configuration** lần cuối, đợi thông báo thành công rồi bấm **Apply**. Connector chuyển sang **Stopped** sau khi khởi tạo xong, và chỉ khi đó mới start được: trong **Installed connectors**, mở menu ba chấm của aq_postgres_cdc, chọn **Start** rồi chờ **Running**.

### Kiểm tra initial snapshot

Khi connector Running, initial snapshot bắt đầu và sau vài phút hai bảng Bronze xuất hiện trong AQ_LAKEHOUSE.AQ. Kết quả đúng là hai bảng Iceberg (cột `is_iceberg` là `Y`), với 23 dòng ở STATIONS và 2117 dòng ở MEASUREMENTS, khớp với PostgreSQL ở mục 2.1:

```sql
USE ROLE openflow_admin;
USE WAREHOUSE AQ_WH;

SHOW TABLES IN SCHEMA AQ_LAKEHOUSE.AQ;

SELECT
  (SELECT COUNT(*) FROM AQ_LAKEHOUSE.AQ.STATIONS)     AS stations,
  (SELECT COUNT(*) FROM AQ_LAKEHOUSE.AQ.MEASUREMENTS) AS measurements;
```

Lúc này chưa có bảng journal vì initial snapshot được nạp thẳng vào các bảng Bronze. Journal của một bảng chỉ được tạo khi bảng đó có thay đổi CDC đầu tiên, ở mục 2.3.

Bên phía PostgreSQL, slot đã được tạo và đang được connector đọc. Lệnh sau chạy trong phiên Session Manager của EC2 như ở mục 2.1, không chạy trong Snowsight:

```bash
sudo docker exec aq-postgres psql -U postgres -d airquality -c "SELECT slot_name, plugin, active FROM pg_replication_slots WHERE slot_name = 'openflow_aq_slot';"
```

Kết quả đúng là một dòng có `active` là `t`, tức là connector đang đọc từ slot.

## 2.3. Theo dõi CDC qua insert, update và delete

Sau initial snapshot, connector tiếp tục đọc thay đổi từ replication slot. Để quan sát, ta tạo ba thay đổi trên PostgreSQL bằng ba script có sẵn trên EC2, chạy trong phiên Session Manager như ở mục 2.1. Các script được chạy lần lượt, mỗi script một lần: sau mỗi script, đợi 1 đến 2 phút theo lịch gộp của connector rồi kiểm tra Bronze, và chỉ chạy script kế tiếp khi đã thấy kết quả. Các kết quả dưới đây giả định initial snapshot vừa hoàn thành và ba script chưa được chạy lần nào.

**Insert:** script 04 thêm dòng `measurement_id = 2118` vào bảng measurements.

```bash
sudo docker exec aq-postgres psql -U postgres -d airquality -f /workspace/postgres/04_cdc_insert.sql
```

Sau 1 đến 2 phút, đếm số dòng của bảng measurements ở Bronze:

```sql
SELECT COUNT(*) FROM AQ_LAKEHOUSE.AQ.MEASUREMENTS;
```

Kết quả đúng là 2118, tăng một dòng so với initial snapshot.

Thay đổi đầu tiên cũng khiến connector tạo journal của bảng measurements, cũng là một bảng Iceberg. Liệt kê các bảng journal để lấy tên của nó, có dạng `MEASUREMENTS_JOURNAL_<epoch>_<số>`:

```sql
SHOW TABLES LIKE '%JOURNAL%' IN SCHEMA AQ_LAKEHOUSE.AQ;
```

Kết quả đúng chỉ có journal của measurements, vì bảng stations chưa có thay đổi nào. Journal lưu từng thay đổi nhận từ nguồn, và được đọc bằng tên vừa lấy (thay vào `<tên-journal>`):

```sql
SELECT PRIMARY_KEY__MEASUREMENT_ID AS id, EVENT_TYPE, SEEN_AT
FROM AQ_LAKEHOUSE.AQ."<tên-journal>"
ORDER BY SEEN_AT;
```

Kết quả đúng là một dòng `IncrementalInsertRows` cho `measurement_id` 2118.

**Update:** script 05 đổi `aqi` và `pm25` của dòng `measurement_id = 320` thành 275.

```bash
sudo docker exec aq-postgres psql -U postgres -d airquality -f /workspace/postgres/05_cdc_update.sql
```

Sau 1 đến 2 phút, kiểm tra dòng 320 ở Bronze:

```sql
SELECT MEASUREMENT_ID, AQI, PM25 FROM AQ_LAKEHOUSE.AQ.MEASUREMENTS WHERE MEASUREMENT_ID = 320;
```

Kết quả đúng là `AQI` và `PM25` đều bằng 275.00.

**Delete:** script 06 xóa dòng `measurement_id = 434`.

```bash
sudo docker exec aq-postgres psql -U postgres -d airquality -f /workspace/postgres/06_cdc_delete.sql
```

Sau 1 đến 2 phút, kiểm tra dòng 434 ở Bronze:

```sql
SELECT MEASUREMENT_ID, AQI, _SNOWFLAKE_DELETED FROM AQ_LAKEHOUSE.AQ.MEASUREMENTS WHERE MEASUREMENT_ID = 434;
```

Kết quả đúng là dòng 434 không biến mất khỏi Bronze mà có `_SNOWFLAKE_DELETED` bằng `TRUE`, trong khi `AQI` vẫn giữ giá trị cuối cùng (221.00). Đây là soft delete ở phần giới thiệu, và khi đọc Bronze ở các tầng sau, điều kiện `WHERE NOT _SNOWFLAKE_DELETED` loại các dòng đã xóa.

### Journal sau ba thay đổi

Chạy lại truy vấn đọc journal ở bước Insert, journal giờ có ba dòng, mỗi dòng ứng với một thay đổi theo thứ tự xảy ra:

| id | EVENT_TYPE |
| ---: | --- |
| 2118 | IncrementalInsertRows |
| 320 | IncrementalUpdateRows |
| 434 | IncrementalDeleteRows |

Mỗi dòng journal gồm khóa chính (`PRIMARY_KEY__*`), giá trị các cột sau thay đổi (`PAYLOAD__*`), loại thao tác (`EVENT_TYPE`) và thời điểm nhận (`SEEN_AT`). Với dòng 434, các cột `PAYLOAD__*` trống vì sự kiện delete chỉ mang khóa, còn Bronze vẫn giữ dòng cùng cờ xóa `_SNOWFLAKE_DELETED`.

# Mục 3. Transformation và kiểm soát data quality

> **[HÌNH 14: tổng quan Write-Audit-Publish từ Bronze đến Silver và Gold]** (`muc3-write-audit-publish.png`)

Sau mục 2, Bronze đã nhận dữ liệu từ PostgreSQL và được cập nhật liên tục bằng CDC. Tuy nhiên, Bronze giữ dữ liệu gần nguyên như ở nguồn, kể cả những phần chưa sạch như giá trị thiếu, giá trị ngoài miền hợp lệ, dòng trùng và các dòng đã bị soft delete vẫn nằm trong bảng. Dashboard và các truy vấn phân tích không nên đọc trực tiếp từ đó. Mục này thực hiện transformation (biến đổi dữ liệu) để xây dựng hai tầng tiếp theo là Silver và Gold, đồng thời đặt một quy trình kiểm soát data quality (chất lượng dữ liệu) để dữ liệu chỉ đến người dùng sau khi đã được kiểm tra.

## Write-Audit-Publish

Nếu ghi trực tiếp kết quả transformation vào Silver, dữ liệu lỗi có thể đến các truy vấn phân tích trước khi được kiểm tra. Vì vậy cần một bước kiểm tra đặt trước khi thay đổi đến người dùng, và quy trình thực hiện việc đó là Write-Audit-Publish.

> **Write-Audit-Publish (WAP)** là quy trình gồm ba bước: ghi thay đổi vào một bản làm việc tách biệt gọi là candidate (Write), kiểm tra candidate (Audit) và chỉ khi đạt mới đưa vào sử dụng (Publish).

Ở bước Write, candidate được tạo từ Silver hiện tại rồi cập nhật theo Bronze. Ở bước Audit, các kiểm tra data quality chạy trên candidate, và mỗi kiểm tra có thể ở mức chặn hoặc chỉ ở mức cảnh báo. Nếu có kiểm tra ở mức chặn thất bại, Publish không chạy và Silver hiện tại giữ nguyên, nên downstream tiếp tục đọc phiên bản đã được kiểm tra trước đó. Ngược lại, bước Publish đưa nội dung candidate vào Silver. Gold được tạo từ Silver mới sau Publish, không nằm trong vòng Write-Audit-Publish.

## Candidate và zero-copy clone

Candidate cần chứa các bảng Silver thay đổi theo Bronze để so sánh và cập nhật, nhưng sao chép các bảng đó sau mỗi lần chạy sẽ tốn thời gian và dung lượng. Vì vậy mỗi lần chạy, candidate được tạo từ bản zero-copy clone của các bảng Silver này.

> **Zero-copy clone** là bản sao của bảng không sao chép dữ liệu. Bản gốc và bản clone dùng chung các file Parquet trên S3 nhưng có file metadata riêng, và chỉ những thay đổi sau đó mới tạo file dữ liệu mới.

> **[HÌNH 15: Silver hiện tại, candidate và Bronze]** (`muc3-silver-candidate-bronze.png`)

## 3.1. Chuẩn bị schema và đăng nhập cho pipeline

Ở mục 3.2, quy trình Write-Audit-Publish được chạy tự động bằng một script, gọi là pipeline (chuỗi các bước xử lý dữ liệu chạy nối tiếp nhau). Trước đó cần có hai thứ. Thứ nhất là các bảng đích của star schema, vì candidate được clone từ các bảng này. Thứ hai là cách đăng nhập Snowflake không cần người nhập mã MFA, vì script chạy mà không có ai ngồi nhập mã. Repo đã có sẵn file SQL và script hỗ trợ cho hai việc này, nên bạn chỉ cần chạy theo các bước dưới đây.

### Tạo schema

Mở `snowflake/03_silver_schema.sql` trong Snowsight và chạy toàn bộ bằng **Run all**. File tạo ba schema:

- **`SILVER`** gồm các bảng Iceberg của star schema, với bốn dimension `DIM_DATE`, `DIM_TIME`, `DIM_CITY`, `DIM_STATION` và bảng fact `FACT_AQI`, cùng hàm `AQI_CATEGORY` phân loại mức ô nhiễm từ chỉ số AQI.
- **`GOLD`** để trống, được điền ở bước cuối của mục 3.2.
- **`CONTROL`** chứa các bảng tham chiếu và bảng `DQ_RESULTS`, nơi lưu kết quả các kiểm tra data quality.

Thành phố của mỗi trạm lấy từ URL của trạm, vì cột `location` trong dữ liệu gốc là tọa độ chứ không phải tên thành phố. Riêng trạm `13252` có URL không khớp với thành phố thật nên được gán trực tiếp vào Cao Bằng qua bảng `CONTROL.STATION_CITY_OVERRIDE`.
Cuối file có ba câu kiểm tra. Trong cùng worksheet, bôi đen từng câu rồi chạy bằng `Ctrl + Enter`. Kết quả đúng là `DIM_DATE` có 4383 dòng, `DIM_TIME` có 24 dòng, `DIM_CITY` có 11 dòng, câu tìm trạm chưa xác định được thành phố không trả về dòng nào, và 23 trạm được chia cho 11 thành phố, trong đó Hà Nội có 11 trạm và Bắc Ninh có 3 trạm. Hai bảng `DIM_STATION` và `FACT_AQI` còn trống, vì hai bảng này được điền khi pipeline chạy.

### Đăng nhập bằng key pair

Bạn đăng nhập Snowsight bằng mật khẩu và mã từ ứng dụng Authenticator. Script thì không có ai nhập mã, nên pipeline dùng key pair (cặp khóa): Snowflake giữ khóa công khai, máy bạn giữ khóa riêng.

Trước hết, thêm hai dòng sau vào `.gitignore` để khóa riêng và thông tin đăng nhập không bị commit nhầm:

```
.keys/
.env
```

Tạo cặp khóa bằng script có sẵn trong repo, thay `<snowflake-user>` bằng tên user Snowflake của bạn:

```bash
uv run --with cryptography python scripts/make_keypair.py <snowflake-user>
```

Script ghi khóa riêng vào `.keys/snowflake_rsa_key.p8` và in ra một câu `ALTER USER ... SET RSA_PUBLIC_KEY = '...'`. Trong Snowsight, đổi role thành `SECURITYADMIN`, vì đây là role quản lý user, rồi chạy câu `ALTER USER` vừa in ra để đăng ký khóa công khai.

Tiếp theo, tạo file `.env` ở thư mục gốc của repo để khai báo kết nối:

```
SNOWFLAKE_ACCOUNT=<organization>-<account-name>
SNOWFLAKE_USER=<snowflake-user>
SNOWFLAKE_PRIVATE_KEY_PATH=.keys/snowflake_rsa_key.p8
SNOWFLAKE_ROLE=OPENFLOW_ADMIN
SNOWFLAKE_WAREHOUSE=AQ_WH
```

`SNOWFLAKE_ACCOUNT` có dạng `<organization>-<account-name>`, xem trong menu tài khoản của Snowsight.

Cuối cùng, cài các thư viện cho pipeline gồm Soda để chạy kiểm tra, `python-dotenv` để đọc `.env` và `snowflake-connector-python` để kết nối Snowflake:

```bash
uv add soda-core-snowflake python-dotenv snowflake-connector-python setuptools
```

## 3.2. Chạy Write-Audit-Publish

Write-Audit-Publish chỉ bảo vệ được Silver khi các bước chạy đúng thứ tự và Publish chỉ chạy sau khi Audit không có kiểm tra fail. Nếu mỗi bước là một file chạy tay, việc đọc kết quả Audit rồi mới quyết định Publish phụ thuộc vào người chạy, và bước kiểm tra rất dễ bị bỏ qua. Vì vậy cả quy trình được gói trong một script là `wap/run.py`, chạy bốn bước theo thứ tự và tự dừng khi Audit thất bại. Chạy script bằng một lệnh từ thư mục gốc của repo:

```bash
uv run wap/run.py
```

Bốn bước gồm Write, Audit, Publish rồi Gold. Mỗi bước in một dòng tiêu đề dạng `== 1/4 WRITE ...`. Kết quả đúng ở lần chạy đầu là Audit in 22 dòng `[PASS]` kèm dòng `AUDIT PASSED.`, và script kết thúc bằng dòng `== Done. Silver and Gold are updated.`. Các phần dưới đây giải thích từng bước qua những đoạn code chính của từng bước.

> **[HÌNH 16: Output của wap/run.py, từ bước WRITE đến dòng Done]** (muc3-wap-run-output.png)

### Write

Bước Write chạy file `wap/01_write_candidate.sql`. Việc đầu tiên là tạo schema `SILVER_CANDIDATE` và clone hai bảng Silver thay đổi theo Bronze:

```sql
CREATE OR REPLACE ICEBERG TABLE SILVER_CANDIDATE.DIM_STATION CLONE SILVER.DIM_STATION;
CREATE OR REPLACE ICEBERG TABLE SILVER_CANDIDATE.FACT_AQI    CLONE SILVER.FACT_AQI;
```

Chỉ `DIM_STATION` và `FACT_AQI` được clone. `DIM_DATE`, `DIM_TIME` và `DIM_CITY` là dữ liệu lịch và dữ liệu tham chiếu nên được đọc thẳng từ Silver. Candidate được dựng lại từ Silver hiện tại ở mỗi lần chạy. Ở lần chạy đầu, Silver còn trống nên bản clone cũng trống.

Sau khi clone, hai câu `MERGE` đưa dữ liệu từ Bronze vào candidate, `DIM_STATION` trước rồi đến `FACT_AQI`. Với `FACT_AQI`, câu `MERGE` xử lý ba trạng thái của một dòng ở Bronze:

```sql
WHEN MATCHED AND s.is_deleted THEN DELETE
WHEN MATCHED AND NOT s.is_deleted AND t.ingested_at <> s.ingested_at THEN UPDATE SET
    ...
WHEN NOT MATCHED AND NOT s.is_deleted THEN INSERT (...) VALUES (...);
```

Dòng bị soft delete (`_SNOWFLAKE_DELETED = TRUE`) bị `DELETE` khỏi candidate. Dòng đã thay đổi, nhận biết qua `_SNOWFLAKE_UPDATED_AT` khác `ingested_at` đã lưu, được `UPDATE`. Dòng mới được `INSERT`. Đây là nơi dòng đã xóa ở nguồn rời khỏi dữ liệu của các tầng sau, đúng như mục 2 đã nêu.

Trong lúc nạp, dữ liệu cũng được làm sạch nhẹ. Thời gian đo được đổi sang giờ Việt Nam trước khi tính khóa ngày và khóa giờ, nếu không các lần đo sau 17:00 UTC sẽ rơi sang ngày kế tiếp:

```sql
CONVERT_TIMEZONE('Asia/Ho_Chi_Minh', m.MEASURED_AT)::TIMESTAMP_NTZ AS measured_at
```

Ngoài ra, giá trị `source` được đổi tên (`kaggle_2021` thành `kaggle`, `waqi_api` thành `api`), và cột `dominant_pollutant` có giá trị rỗng, `-` hoặc `aqi` được chuyển thành `NULL`.

Câu `MERGE` nối `FACT_AQI` với các dimension bằng `JOIN`, nên dòng nào không nối được với đủ dimension sẽ không được nạp và không có lỗi nào được báo. Việc phát hiện những dòng như vậy thuộc về bước Audit.

### Audit

Bước Audit chạy `wap/02_audit.py`, script này dùng Soda để chạy các kiểm tra khai báo trong `soda/checks/silver_candidate.yml` trên `FACT_AQI` của candidate. Có 22 kiểm tra, mỗi kiểm tra có kết quả pass, warn hoặc fail. Kiểm tra ở mức chặn khi vi phạm cho kết quả fail, còn kiểm tra ở mức cảnh báo, khai báo bằng `warn`, cho kết quả warn. Trong 22 kiểm tra, 18 kiểm tra ở mức chặn và 4 kiểm tra ở mức cảnh báo.

Các kiểm tra ở mức chặn gồm số dòng tối thiểu, tính duy nhất của `measurement_id` và của cặp (`station_key`, `measured_at`), khóa không được null, miền giá trị hợp lệ như `aqi` trong khoảng 0 đến 500, và `pollution_level` phải khớp với `aqi`. Kiểm tra đối soát bắt các dòng bị rơi khi `JOIN` ở bước Write bằng cách so số dòng của candidate với số dòng còn sống ở Bronze:

```yaml
- bronze_row_difference = 0:
    name: candidate rows equal live Bronze rows
    bronze_row_difference query: |
      SELECT ABS(
        (SELECT COUNT(*) FROM AQ_LAKEHOUSE.AQ.MEASUREMENTS WHERE NOT _SNOWFLAKE_DELETED)
      - (SELECT COUNT(*) FROM AQ_LAKEHOUSE.SILVER_CANDIDATE.FACT_AQI)
      )
```

Nhóm kiểm tra referential integrity (toàn vẹn tham chiếu) bảo đảm mọi dòng fact tìm được đủ bốn dimension, thành phố của fact bằng thành phố của trạm, và mọi thành phố tham chiếu đều có dữ liệu:

```yaml
- orphan_fact_rows = 0:
    name: every fact row resolves to all four dimensions
    orphan_fact_rows query: |
      SELECT COUNT(*)
      FROM AQ_LAKEHOUSE.SILVER_CANDIDATE.FACT_AQI f
      LEFT JOIN AQ_LAKEHOUSE.SILVER.DIM_DATE d ON d.date_key = f.date_key
      ...
      WHERE d.date_key IS NULL OR t.time_key IS NULL
         OR c.city_key IS NULL OR s.station_key IS NULL
```

Bốn kiểm tra ở mức cảnh báo là tỷ lệ null của `aqi`, `pm25`, `pm10` và độ mới của dữ liệu. Các số đo được phép null trong một ngưỡng, vì dữ liệu thật có khoảng 23% giá trị AQI bị thiếu:

```yaml
- missing_percent(aqi):
    name: null percent of aqi
    warn: when > 30
```

Kiểm tra độ mới cảnh báo khi dòng Bronze không thay đổi quá 2 ngày. Nếu bạn chạy lại pipeline sau hơn 2 ngày mà Bronze không có thay đổi mới, kiểm tra này cho kết quả warn và Publish vẫn chạy. Điều này là bình thường, vì dữ liệu mẫu là dữ liệu năm 2021.

Sau khi chạy xong, script ghi từng kết quả vào bảng `CONTROL.DQ_RESULTS` để xem lại lịch sử, rồi trả về mã thoát cho `run.py`:

```python
if scan.has_check_fails():
    print("AUDIT FAILED: Silver Candidate is not published.")
    return 1

if scan.has_check_warns():
    print("AUDIT PASSED with warnings.")
else:
    print("AUDIT PASSED.")
return 0
```

Ba mã thoát có ý nghĩa như sau.

| Mã thoát | Ý nghĩa |
| --- | --- |
| 0 | Mọi kiểm tra pass, hoặc chỉ có warn |
| 1 | Có ít nhất một kiểm tra fail |
| 2 | Soda không chạy được |

### Publish

`run.py` quyết định có Publish hay không dựa trên mã thoát của Audit:

```python
audit = subprocess.run([sys.executable, str(WAP / "02_audit.py")], cwd=ROOT)
if audit.returncode == 1:
    print("== Audit failed. Nothing was published; Current Silver is unchanged.")
    return 1
if audit.returncode != 0:
    print("== Audit could not run. Nothing was published.")
    return 2
```

Khi Audit có kiểm tra fail hoặc không chạy được, pipeline dừng tại đây. Publish và Gold không chạy, Silver giữ nguyên, nên các truy vấn phân tích tiếp tục đọc phiên bản đã qua kiểm tra trước đó. Candidate bị bỏ lại và được dựng lại ở lần chạy sau.

Khi Audit không có kiểm tra fail, `run.py` chạy `wap/03_publish.sql`, gồm hai câu:

```sql
INSERT OVERWRITE INTO SILVER.DIM_STATION SELECT * FROM SILVER_CANDIDATE.DIM_STATION;
INSERT OVERWRITE INTO SILVER.FACT_AQI    SELECT * FROM SILVER_CANDIDATE.FACT_AQI;
```

Mỗi câu thay toàn bộ nội dung một bảng Silver bằng nội dung bảng tương ứng của candidate. Trong Snowflake, một câu lệnh đơn lẻ hoặc được commit toàn bộ hoặc bị rollback (hủy) toàn bộ, và các session (phiên làm việc) khác không thấy thay đổi chưa commit. Vì vậy truy vấn đọc một bảng Silver thấy hoặc nội dung cũ hoặc nội dung mới, không bao giờ thấy trạng thái trung gian. Bảng giữ nguyên tên, vị trí lưu trữ và quyền truy cập, nên các tầng sau và các engine bên ngoài không phải thay đổi gì.

Hai câu được chạy tách riêng, nên giữa hai câu có một khoảng ngắn mà `DIM_STATION` đã mới còn `FACT_AQI` vẫn cũ. `DIM_STATION` đi trước vì ở bước Write, `MERGE` giữ nguyên `station_key` của các trạm đã có, nên trong khoảng đó bảng fact cũ vẫn nối được với dimension mới.

### Gold

Sau Publish, `run.py` chạy `wap/04_load_gold.sql` để tạo năm bảng tổng hợp từ Silver mới: tóm tắt theo ngày, xếp hạng thành phố theo tháng, tóm tắt theo trạm, mẫu hình theo giờ trong ngày và tóm tắt theo mùa. Gold nằm ngoài vòng Write-Audit-Publish, vì dữ liệu đầu vào của nó đã được kiểm tra ở Audit. Mỗi bảng được thay bằng một câu `INSERT OVERWRITE`, nên người đọc thấy bảng cũ hoặc bảng mới, không thấy bảng dựng dở. Ví dụ, bảng thứ nhất có dạng:

```sql
INSERT OVERWRITE INTO GOLD.AQI_DAILY_SUMMARY (...)
SELECT c.city_slug, ..., d.full_date, AVG(f.aqi), MAX(f.aqi), MIN(f.aqi), ...
FROM SILVER.FACT_AQI f
JOIN SILVER.DIM_CITY c ON c.city_key = f.city_key
JOIN SILVER.DIM_DATE d ON d.date_key = f.date_key
GROUP BY c.city_slug, c.city_name, c.region, d.full_date;
```

Hạng được tính riêng cho từng tháng bằng `DENSE_RANK() OVER (PARTITION BY year, month ...)`. Thành phố không có giá trị AQI nào thì không được xếp hạng, để không bị xếp nhầm là nơi ô nhiễm nhất. Bảng xếp hạng thành phố lấy trung bình của các giá trị trung bình theo ngày.

Nếu bước Gold lỗi, Silver đã được publish từ trước và không bị hoàn lại, `run.py` in `GOLD failed (Silver was already published)` và trả về mã 2. Chạy lại `uv run wap/run.py` sẽ dựng lại các bảng Gold.

### Kiểm tra kết quả

Mở một worksheet mới trong Snowsight và chọn role, warehouse:

```sql
USE ROLE openflow_admin;
USE WAREHOUSE AQ_WH;
```

Đếm số dòng của `FACT_AQI` ở Silver và tìm ba thay đổi CDC đã thực hiện ở mục 2.3:

```sql
SELECT COUNT(*) FROM AQ_LAKEHOUSE.SILVER.FACT_AQI;

SELECT measurement_id, aqi
FROM AQ_LAKEHOUSE.SILVER.FACT_AQI
WHERE measurement_id IN (320, 434, 2118)
ORDER BY measurement_id;
```

Kết quả đúng là 2117 dòng, và câu thứ hai trả về hai dòng: dòng 320 với `aqi` bằng 275 (dòng đã sửa) và dòng 2118 (dòng thêm mới). Dòng 434 không xuất hiện vì đã bị soft delete ở Bronze.

Tiếp theo, so tổng `record_count` của từng bảng Gold với số dòng của Silver:

```sql
SELECT
    (SELECT COUNT(*)          FROM AQ_LAKEHOUSE.SILVER.FACT_AQI)             AS silver_rows,
    (SELECT SUM(record_count) FROM AQ_LAKEHOUSE.GOLD.AQI_DAILY_SUMMARY)      AS daily,
    (SELECT SUM(record_count) FROM AQ_LAKEHOUSE.GOLD.AQI_CITY_RANKING)       AS city_ranking,
    (SELECT SUM(record_count) FROM AQ_LAKEHOUSE.GOLD.STATION_SUMMARY)        AS station_summary,
    (SELECT SUM(record_count) FROM AQ_LAKEHOUSE.GOLD.AQI_HOURLY_PATTERN)     AS hourly,
    (SELECT SUM(record_count) FROM AQ_LAKEHOUSE.GOLD.AQI_SEASONAL_SUMMARY)   AS seasonal;
```

Kết quả đúng là cả sáu số đều bằng 2117, tức là mọi bảng tổng hợp đều tính đủ các dòng của Silver.

Cuối cùng, xem bảng xếp hạng thành phố của tháng 1 năm 2021:

```sql
SELECT year, month, city_name, ROUND(avg_aqi, 1) AS avg_aqi, aqi_rank, days_observed
FROM AQ_LAKEHOUSE.GOLD.AQI_CITY_RANKING
WHERE year = 2021 AND month = 1
ORDER BY aqi_rank NULLS LAST, city_name;
```

Kết quả đúng là 11 thành phố. Chín thành phố đầu có hạng từ 1 đến 9, mỗi thành phố có 9 ngày quan sát. Đà Nẵng và Nha Trang không có giá trị AQI nên `avg_aqi` và `aqi_rank` để trống, và hai thành phố này nằm cuối bảng.

> **[HÌNH 17: Bảng xếp hạng thành phố tháng 1/2021 trong Snowsight]** (muc3-gold-city-ranking.png)

# Mục 4. Truy cập lakehouse từ engine bên ngoài

> **[HÌNH 18: Tổng quan engine bên ngoài đọc và ghi qua Horizon Catalog]** (muc4-external-engine-overview.svg)

> **[TODO: Phần mở đầu mục 4, viết theo doc "Dàn ý giới thiệu Mục 4". Giới thiệu Horizon Catalog, PAT và vended credentials, rồi đặt HÌNH 19 sau đoạn về PAT và vended credentials.]**

> **[HÌNH 19: Horizon chỉ cấp khóa S3 cho role có quyền]** (muc4-horizon-s3-access-flow.svg)

## 4.1. Cấp quyền cho engine bên ngoài

Trước khi DuckDB đọc được bảng, Snowflake cần biết DuckDB là ai và được phép làm gì. Mục này tạo một role, một user và một token dành riêng cho engine bên ngoài, rồi kiểm tra kết nối từ phía client. Repo đã có file SQL và script hỗ trợ cho các bước này, nên bạn chỉ cần chạy theo thứ tự dưới đây.

### Thiết kế quyền

Engine bên ngoài dùng một role riêng tên AQ_EXTERNAL, gắn với một user tên AQ_DUCKDB. Bảng dưới cho thấy role này được làm gì trên từng nhóm bảng.

| Nhóm bảng | Quyền của AQ_EXTERNAL |
| --- | --- |
| Silver và Gold | Chỉ đọc (SELECT) |
| SILVER_CANDIDATE | Chỉ đọc (SELECT) |
| SANDBOX.DUCKDB_NOTES | Đọc và ghi (SELECT, INSERT, UPDATE, DELETE, TRUNCATE) |
| Bronze và CONTROL | Không có quyền |

Cách chia này là nguyên tắc quyền tối thiểu áp dụng cho từng nhóm bảng. Vùng ghi duy nhất là schema SANDBOX, nơi engine bên ngoài thử thêm, sửa và xóa dòng mà không chạm vào dữ liệu đã qua kiểm tra. Lý do của SILVER_CANDIDATE nằm ở phần "Cho role đọc các bản clone" bên dưới.

User AQ_DUCKDB thuộc loại service user, vì người dùng thật không nhập mật khẩu hay mã MFA thay cho DuckDB được.

> **Service user** là user dành cho chương trình. User này không có mật khẩu và không hỏi MFA, chỉ đăng nhập bằng các phương thức dành cho máy như key pair hoặc PAT.

Để user này đăng nhập được bằng PAT, file gắn thêm một authentication policy cho user.

> **Authentication policy** (chính sách xác thực) là đối tượng quy định các phương thức xác thực mà một user được dùng.

Mặc định, PAT chỉ dùng được khi user có network policy, tức danh sách địa chỉ mạng được phép kết nối. Để bạn kết nối từ máy cá nhân, policy của bài bỏ yêu cầu này. Môi trường thật nên tạo network policy cho các máy được phép thay vì bỏ yêu cầu.

### Chạy file cấu hình

Mở `snowflake/05_horizon_access.sql` trong Snowsight và chạy toàn bộ bằng **Run all**. File gồm ba phần. Phần A và B chạy lại được nhiều lần. Phần C tạo token nên chỉ chạy một lần, vì chạy lại sẽ báo lỗi do tên token đã tồn tại.

**Phần A tạo role, user và quyền đọc.** File tạo role, user và các quyền đọc đã nêu ở phần thiết kế. Bảng Iceberg là một loại đối tượng riêng, nên câu cấp quyền phải ghi `ALL ICEBERG TABLES`. Nếu ghi `ALL TABLES`, câu lệnh vẫn chạy không báo lỗi nhưng không cấp quyền nào.

**Phần B tạo vùng ghi sandbox.** File tạo schema SANDBOX và bảng DUCKDB_NOTES, rồi cấp quyền đọc và ghi trên bảng này. Bảng được tạo bằng role OPENFLOW_ADMIN, không để DuckDB tự tạo, vì Horizon yêu cầu role sở hữu bảng phải có quyền sử dụng trên external volume. Nếu thiếu quyền này, DuckDB sẽ lỗi khi xin khóa S3.

**Phần C tạo token.** Câu cuối của file tạo PAT tên duckdb_token cho AQ_DUCKDB, giới hạn ở role AQ_EXTERNAL và hết hạn sau 30 ngày. Chuỗi bí mật nằm ở cột `token_secret` trong kết quả của câu này và chỉ hiện một lần. Bạn chép giá trị đó vào file `.env` ở thư mục gốc của repo, thành một dòng, không có dấu nháy hay khoảng trắng quanh dấu bằng:

```
HORIZON_PAT=<giá trị của cột token_secret>
```

Ai cầm chuỗi này được coi là user AQ_DUCKDB, nên đừng dán nó vào chat, ticket hay commit. File `.env` đã nằm trong `.gitignore` từ mục 3.1.

Nếu làm mất chuỗi hoặc token hết hạn sau 30 ngày, các script ở mục 4.2 sẽ báo lỗi lấy token. Khi đó bạn xóa và tạo lại token bằng role ACCOUNTADMIN, rồi cập nhật `HORIZON_PAT` trong `.env`:

```sql
USE ROLE ACCOUNTADMIN;
ALTER USER AQ_DUCKDB REMOVE PAT duckdb_token;

ALTER USER AQ_DUCKDB ADD PAT duckdb_token
  ROLE_RESTRICTION = 'AQ_EXTERNAL'
  DAYS_TO_EXPIRY = 30
  COMMENT = 'DuckDB tutorial token';
```

### Cho role đọc các bản clone

Ở bước Write, pipeline đặt các bản clone của FACT_AQI và DIM_STATION vào schema SILVER_CANDIDATE. Theo [tài liệu Horizon của Snowflake](https://docs.snowflake.com/en/user-guide/tables-iceberg-access-using-external-query-engine-snowflake-horizon), với bảng có clone, nếu role không có quyền trên bảng gốc hoặc trên các bản clone khác của nó thì yêu cầu cấp khóa S3 bị từ chối. Vì vậy Phần A cấp cho AQ_EXTERNAL quyền sử dụng trên schema SILVER_CANDIDATE và quyền đọc trên các bảng trong schema này, gồm cả bảng sẽ tạo sau, vì mỗi lần chạy pipeline tạo lại bản clone mới và bảng mới không thừa hưởng quyền của bảng cũ. Đây vẫn chỉ là quyền đọc, role không sửa được candidate hay Silver. Ba bảng còn lại của Silver và toàn bộ Gold không có clone nên không chịu quy tắc này. Nếu thiếu quyền, DuckDB đọc FACT_AQI hoặc DIM_STATION ở Silver sẽ báo `403 Authorization failed`, trong khi các bảng khác vẫn đọc bình thường.

### Kiểm tra quyền

Trong Snowsight, chạy các câu sau bằng role ACCOUNTADMIN, role xem được đầy đủ mọi quyền đã cấp, để biết AQ_EXTERNAL đang có quyền gì:

```sql
USE ROLE ACCOUNTADMIN;
USE WAREHOUSE AQ_WH;
SHOW GRANTS TO ROLE AQ_EXTERNAL;
```

Kết quả đúng gồm quyền đọc trên 5 bảng Silver, 5 bảng Gold và 2 bảng của SILVER_CANDIDATE, năm quyền đọc và ghi trên SANDBOX.DUCKDB_NOTES, cùng quyền sử dụng trên database và bốn schema SILVER, GOLD, SANDBOX, SILVER_CANDIDATE. Role không có quyền ghi nào trên bảng Silver hoặc Gold, và không có quyền gì trên Bronze hay CONTROL.

### Kiểm tra kết nối

Script `scripts/check_horizon.py` đóng vai một client bên ngoài. Script đọc `.env`, đổi PAT lấy một access token ngắn hạn giới hạn ở role AQ_EXTERNAL, hỏi catalog cấu hình rồi liệt kê schema và bảng. Script không in PAT hay token ra màn hình. Bạn chạy từ thư mục gốc của repo:

```bash
uv run scripts/check_horizon.py
```

Kết quả đúng gồm ba dòng PASS cho việc đổi token, lấy cấu hình catalog và liệt kê schema, không có dòng FAIL nào, danh sách đủ bốn schema và dòng cuối cho biết role thấy 13 bảng.

> **[HÌNH 20: Kết quả kiểm tra kết nối Horizon, role AQ_EXTERNAL thấy 13 bảng]** (muc4-horizon-connection-check.png)

Dòng Endpoint là địa chỉ của Horizon Catalog, có dạng `https://<account-identifier>.snowflakecomputing.com/polaris/api/catalog`. Giá trị prefix chính là tên catalog, và tên này là tên database AQ_LAKEHOUSE viết hoa, không phải tên warehouse. Mục 4.2 dùng tên này khi kết nối DuckDB. Schema chứa Bronze và schema CONTROL không xuất hiện trong danh sách, vì role không có quyền trên hai schema này.

## 4.2. Đọc và ghi bằng DuckDB

Với role và token đã sẵn sàng, DuckDB có thể làm việc trực tiếp với các bảng Iceberg do Snowflake quản lý. Mục này đọc Silver và Gold rồi đối chiếu với Snowflake, ghi vào bảng sandbox để Snowflake đọc lại, và cuối cùng thử ghi vào Silver để thấy ranh giới quyền hoạt động. Các script nằm trong thư mục `duckdb/` của repo.

### Cài DuckDB

Các bảng trong bài là Iceberg v3, nên DuckDB phải từ phiên bản 1.5.3 trở lên. Bạn thêm DuckDB vào project và kiểm tra phiên bản:

```bash
uv add duckdb
uv run python -c "import duckdb; print(duckdb.__version__)"
```

Lệnh đầu thêm DuckDB vào `pyproject.toml` và `uv.lock`, bạn commit cả hai file. Khi làm bài, phiên bản được cài là 2.0.0.

### Cách DuckDB kết nối

Hai script `duckdb/read.py` và `duckdb/write.py` kết nối giống nhau. Mỗi script đổi PAT lấy access token như `scripts/check_horizon.py` ở mục 4.1, đưa token cho DuckDB dưới dạng một secret kiểu iceberg, rồi gắn catalog bằng câu `ATTACH`:

```sql
ATTACH 'AQ_LAKEHOUSE' AS lake (
    TYPE iceberg,
    SECRET horizon_secret,
    URI 'https://<account-identifier>.snowflakecomputing.com/polaris/api/catalog',
    ACCESS_DELEGATION_MODE 'vended_credentials'
);
```

Tùy chọn `ACCESS_DELEGATION_MODE 'vended_credentials'` bảo DuckDB xin Horizon khóa S3 tạm thời cho từng bảng khi đọc, đúng luồng ở HÌNH 19. Sau khi gắn, mỗi bảng được gọi theo dạng `lake.<schema>.<bảng>`, ví dụ `lake.SILVER.FACT_AQI`. Script không in PAT hay token ra màn hình.

### Đọc Silver và Gold

Script `duckdb/read.py` chạy bốn truy vấn đọc, mỗi khối in kèm giá trị Snowflake đã kiểm tra ở mục 3.2 để so sánh. Bốn đối tượng được đối chiếu là số dòng bảng fact trong Silver, các thay đổi CDC, tổng số bản ghi của bảng xếp hạng trong Gold và xếp hạng thành phố tháng 1/2021. Bạn chạy từ thư mục gốc của repo:

```bash
uv run duckdb/read.py
```

Output của script nằm trong HÌNH 21 ở phần ghi bên dưới, cạnh output của lệnh ghi. Ba khối đầu khớp khi số liệu bằng giá trị in kèm trong tiêu đề khối. Riêng khối xếp hạng tháng 1/2021, bạn đối chiếu bằng câu sau trong Snowsight:

```sql
USE ROLE openflow_admin;
USE WAREHOUSE AQ_WH;
SELECT city_name, ROUND(avg_aqi, 1) AS avg_aqi, aqi_rank, days_observed
FROM AQ_LAKEHOUSE.GOLD.AQI_CITY_RANKING
WHERE year = 2021 AND month = 1
ORDER BY aqi_rank NULLS LAST, city_name;
```

Kết quả phải giống DuckDB từng dòng, cùng thành phố, cùng trung bình, cùng hạng và `days_observed` bằng 9. Nếu DuckDB báo `403 Authorization failed` khi đọc FACT_AQI hoặc DIM_STATION ở Silver, bạn xem lại phần clone ở mục 4.1.

### Ghi vào sandbox

Script `duckdb/write.py` thao tác trên bảng SANDBOX.DUCKDB_NOTES và in bảng sau mỗi bước. Script xóa các dòng cũ để chạy lại được nhiều lần, thêm 3 dòng, sửa nội dung dòng 2 rồi xóa dòng 3. Bạn chạy lệnh ghi từ thư mục gốc của repo:

```bash
uv run duckdb/write.py
```

> **[HÌNH 21: DuckDB đọc Silver và Gold, rồi ghi vào bảng sandbox]** (muc4-duckdb-read-write-results.png)

Sau khi script chạy xong, Snowflake phải thấy đúng những gì DuckDB đã ghi. Bạn đọc lại bảng trong Snowsight:

```sql
USE ROLE openflow_admin;
USE WAREHOUSE AQ_WH;
SELECT * FROM AQ_LAKEHOUSE.SANDBOX.DUCKDB_NOTES ORDER BY note_id;
```

Kết quả đúng là 2 dòng, dòng 1 giữ nguyên và dòng 2 mang nội dung đã sửa. Cột `written_at` là thời điểm DuckDB ghi, theo giờ máy của bạn.

> **[HÌNH 22: Snowsight đọc lại bảng sandbox, thấy đúng hai dòng DuckDB để lại]** (muc4-snowsight-sandbox-notes.png)

Bài chỉ thử thêm, sửa và xóa dòng. Các thao tác ghi khác của DuckDB lên bảng Snowflake quản lý chưa được kiểm tra.

### Tùy chọn khi ghi qua Horizon

Câu `ATTACH` trong `duckdb/write.py` khác `duckdb/read.py` ở một điểm, là thêm tùy chọn `DISABLE_MULTI_TABLE_COMMIT true`. Mặc định DuckDB lưu thay đổi qua endpoint commit nhiều bảng cùng lúc của Iceberg REST. Tài liệu DuckDB mô tả tùy chọn này là để tắt endpoint đó, dành cho catalog từ chối nó ([iceberg_options](https://duckdb.org/docs/2.0/core_extensions/iceberg/iceberg_options.html)). Tài liệu Horizon IRC của Snowflake cũng ghi trong mục Limitations rằng endpoint này không được hỗ trợ ([Horizon IRC](https://docs.snowflake.com/en/user-guide/externally-managed-iceberg-tables-access-horizon-irc)), dù trang đó nói về bảng quản lý ngoài và trang về engine bên ngoài đọc bảng Snowflake quản lý không nhắc tới.

Trong lúc làm bài, nếu chưa có tùy chọn này thì lệnh thêm dòng thất bại ở bước commit với `403 Authorization failed`, dù role đã đủ quyền trên bảng. Bật tùy chọn thì script chạy được. Snowflake không giải thích mã 403 này là do commit nhiều bảng, nên đây chỉ là quan sát chứ không phải điều tài liệu xác nhận.

### Thử ghi vào Silver

Role AQ_EXTERNAL chỉ có quyền đọc trên Silver. Để thấy điều này trong thực tế, bạn thêm cờ `--try-silver`:

```bash
uv run duckdb/write.py --try-silver
```

Script chạy lại các bước ghi sandbox rồi thử thêm một dòng vào `lake.SILVER.DIM_CITY`. Kết quả đúng là lệnh bị từ chối.

> **[HÌNH 23: DuckDB ghi vào Silver bị từ chối với lỗi 403]** (muc4-duckdb-silver-write-refused.png)

Lệnh bị từ chối ở bước tải file Parquet lên S3. Khóa S3 mà Horizon cấp cho role chỉ có quyền đọc là khóa chỉ đọc, nên DuckDB không ghi được file dữ liệu và không đi tới bước commit. Đây là suy ra từ nội dung lỗi, tài liệu Snowflake không mô tả cơ chế này. Nếu bạn thấy dòng báo ghi thành công, hãy dừng lại, vì khi đó bảng DIM_CITY có thêm một dòng trùng và quyền của role đang sai.

# Mục 5. Dọn dẹp tài nguyên

Hạ tầng Openflow gồm cụm EKS, NAT gateway, RDS và các máy EC2, tất cả tính phí theo giờ dù pipeline không chạy, nên sau khi học xong bạn nên gỡ toàn bộ, từ Openflow, PostgreSQL, các đối tượng Snowflake đến bucket S3. Thao tác không đảo ngược được và xóa cả dữ liệu Bronze, Silver, Gold trong S3, vì vậy bạn chỉ làm khi không cần dữ liệu nữa.

Thứ tự các bước quan trọng vì mỗi lớp phụ thuộc lớp trước. Hạ tầng của deployment phải được dỡ bằng script trước khi xóa stack, deployment phải terminate trước khi drop, và external volume chỉ xóa được sau khi các bảng Iceberg dùng nó đã biến mất. Các lệnh `aws` viết cho PowerShell và chạy từ thư mục gốc của repo, các câu SQL chạy trong worksheet của Snowsight.

## Gỡ Openflow

Bạn bắt đầu từ runtime. Lệnh `CASCADE` terminate luôn connector nằm trong runtime, nên bạn không cần xóa connector riêng:

```sql
USE ROLE openflow_admin;

-- CASCADE terminates the connector inside the runtime first
ALTER OPENFLOW RUNTIME aq_runtime TERMINATE CASCADE;

-- Run again until the status is TERMINATED
SHOW OPENFLOW RUNTIMES;
```

Khi trạng thái là TERMINATED, bạn xóa bản ghi runtime. Lệnh DROP bị từ chối khi runtime còn TERMINATING, và cũng bị từ chối khi còn bản ghi connector nếu thiếu `CASCADE`:

```sql
USE ROLE openflow_admin;

DROP OPENFLOW RUNTIME aq_runtime CASCADE;
```

Tiếp theo là hạ tầng trong VPC. Agent EC2 giữ script `destroy.sh` để dỡ EKS và RDS. Bạn phải chạy script này trước khi xóa stack, nếu không EKS và RDS bị bỏ lại và vẫn tính phí. Agent không đăng ký với Session Manager, nên bạn kết nối qua EC2 Instance Connect Endpoint. Trên Windows, khóa tạm mà AWS CLI tự tạo bị `ssh` từ chối vì quyền file, nên đoạn dưới tạo một khóa riêng:

```powershell
$env:AWS_PAGER = ""

# Find the agent EC2 instance of stack aq-openflow
$agent = aws cloudformation describe-stack-resources --stack-name aq-openflow --region us-east-2 --query "StackResources[?ResourceType=='AWS::EC2::Instance'].PhysicalResourceId" --output text

# Create a dedicated SSH key once
$key = "$HOME\.ssh\aq_agent"
if (-not (Test-Path "$HOME\.ssh")) { New-Item -ItemType Directory "$HOME\.ssh" | Out-Null }
if (-not (Test-Path $key)) { ssh-keygen -t ed25519 -f $key -q -N '""' }
icacls $key /inheritance:r /grant:r "$($env:USERNAME):(R)" | Out-Null

# Push the public key, then connect (run these two lines back to back)
aws ec2-instance-connect send-ssh-public-key --instance-id $agent --instance-os-user ec2-user --ssh-public-key "file://$key.pub" --region us-east-2
aws ec2-instance-connect ssh --instance-id $agent --connection-type eice --private-key-file $key --os-user ec2-user --region us-east-2
```

Khóa đẩy lên agent chỉ có hiệu lực 60 giây, nên hai lệnh cuối phải chạy liền nhau. Lần đầu kết nối, `ssh` hỏi xác nhận fingerprint của agent và bạn gõ `yes`. Khi dấu nhắc của agent hiện ra, bạn chạy script:

```bash
./destroy.sh
```

Script chạy khá lâu vì phải dỡ EKS và RDS, và kết thúc bằng dòng `delete successful`. Nếu mất kết nối, script vẫn chạy nền. Bạn kết nối lại và theo dõi bằng `journalctl -u docker -f -n 250`.

> **[HÌNH 24: Cuối output của destroy.sh, dòng delete successful xác nhận hạ tầng đã được dỡ]** (muc5-infrastructure-destroy-success.png)

Bạn gõ `exit` để thoát khỏi agent, rồi xem trạng thái deployment:

```sql
USE ROLE openflow_admin;

-- Run again until the status is INACTIVE
SHOW OPENFLOW DEPLOYMENTS;
```

Sau khi script xong, trạng thái đi qua DEACTIVATION_REQUIRED rồi INACTIVE khi agent ngừng báo cáo. Tài liệu Snowflake chỉ nêu trạng thái NOT_REPORTING cho mốc này, nên đây là quan sát khi làm bài. Khi deployment là INACTIVE, bạn xóa stack:

```powershell
aws cloudformation delete-stack --stack-name aq-openflow --region us-east-2
aws cloudformation wait stack-delete-complete --stack-name aq-openflow --region us-east-2
```

Lệnh `wait` không in gì khi thành công và trả lại dấu nhắc sau vài phút. Sau đó bạn terminate deployment. Tên deployment nằm trong dấu nháy kép vì Snowflake lưu tên này bằng chữ thường, và câu này không đảo ngược được:

```sql
USE ROLE openflow_admin;

ALTER OPENFLOW DEPLOYMENT "aq_openflow_aws" TERMINATE;

-- Run again until the status is TERMINATED
SHOW OPENFLOW DEPLOYMENTS;
```

> **[HÌNH 25: Deployment aq_openflow_aws ở trạng thái TERMINATED, sẵn sàng để drop]** (muc5-openflow-deployment-terminated.png)

Khi đã TERMINATED, bạn drop deployment. Kết quả đúng là `SHOW` không còn dòng nào:

```sql
USE ROLE openflow_admin;

DROP OPENFLOW DEPLOYMENT "aq_openflow_aws";

SHOW OPENFLOW DEPLOYMENTS;
```

## Gỡ PostgreSQL

Stack `aq-postgres-ec2` chứa máy EC2 PostgreSQL cùng VPC và các subnet mà Openflow đã dùng, nên bạn xóa nó sau khi stack Openflow đã biến mất. Bước này xóa luôn dữ liệu nguồn trên EC2, còn các bảng Bronze nằm trong S3 nên chưa mất ở bước này:

```powershell
aws cloudformation delete-stack --stack-name aq-postgres-ec2 --region us-east-2
aws cloudformation wait stack-delete-complete --stack-name aq-postgres-ec2 --region us-east-2
```

## Gỡ Snowflake và S3

Các câu dưới xóa theo thứ tự phụ thuộc. User được xóa trước để authentication policy hết bị gắn vào user. Database được xóa trước external volume vì các bảng Iceberg còn tham chiếu volume. Role mặc định của bạn được đặt lại trước khi drop OPENFLOW_ADMIN. Bạn chạy toàn bộ bằng ACCOUNTADMIN và **Run all**, vì hai database do ACCOUNTADMIN sở hữu và dùng OPENFLOW_ADMIN sẽ báo thiếu quyền:

```sql
USE ROLE ACCOUNTADMIN;

-- The user holds the PAT and the authentication policy
DROP USER IF EXISTS AQ_DUCKDB;
DROP ROLE IF EXISTS AQ_EXTERNAL;

-- Dropping a database removes its schemas, tables, secrets and policies
DROP DATABASE IF EXISTS AQ_LAKEHOUSE;
DROP DATABASE IF EXISTS AQ_OPENFLOW;

-- No Iceberg table references the volume any more
DROP EXTERNAL VOLUME IF EXISTS AQ_ICEBERG_VOL;
DROP WAREHOUSE IF EXISTS AQ_WH;

-- Move the default role away from OPENFLOW_ADMIN before dropping it
SET me = CURRENT_USER();
ALTER USER IDENTIFIER($me) SET DEFAULT_ROLE = ACCOUNTADMIN;
DROP ROLE IF EXISTS OPENFLOW_AQ_RUNTIME_EXECUTE_AS_RL;
DROP ROLE IF EXISTS OPENFLOW_ADMIN;
```

Snowsight chỉ hiện kết quả của câu cuối, nên bạn thấy một dòng `OPENFLOW_ADMIN successfully dropped`. Giao diện có thể vẫn hiện OPENFLOW_ADMIN ở góc dưới bên trái cho đến khi bạn đăng xuất rồi đăng nhập lại.

Xóa database chỉ xóa metadata của các bảng Iceberg, còn file Parquet vẫn nằm trong bucket S3. Bạn làm rỗng bucket rồi xóa stack lưu trữ, stack này giữ bucket và IAM role của external volume. Bài không bật versioning cho bucket nên lệnh `rm` là đủ, còn bucket có versioning thì bạn phải xóa cả các phiên bản cũ:

```powershell
$acct = aws sts get-caller-identity --query Account --output text
$bucket = "aq-lakehouse-$acct-us-east-2"

# Delete every object in the bucket (irreversible)
aws s3 rm "s3://$bucket" --recursive --quiet

aws cloudformation delete-stack --stack-name aq-iceberg-storage --region us-east-2
aws cloudformation wait stack-delete-complete --stack-name aq-iceberg-storage --region us-east-2
```

Cuối cùng, bạn xóa các file local gắn với deployment đã bị xóa. Khóa SSH chỉ dùng cho agent cũ, còn template CloudFormation chứa secret OAuth của deployment và không dùng lại được:

```powershell
Remove-Item "$HOME\.ssh\aq_agent", "$HOME\.ssh\aq_agent.pub" -ErrorAction SilentlyContinue
Remove-Item "infra\cloudformation\aq-openflow-aws.yaml" -ErrorAction SilentlyContinue
```

File `.env` và thư mục `.keys/` trong repo không bị xóa bởi các bước trên. PAT trong `.env` đã mất hiệu lực khi user bị xóa, còn khóa RSA trong `.keys/` vẫn là bí mật, nên nếu không định dựng lại bài, bạn xóa nốt hai thứ này.

## Kiểm tra lần cuối

Bảy lệnh dưới kiểm tra không còn tài nguyên nào tính phí. Cả bảy lệnh không in gì là đúng, vì stack lưu trữ cũng đã bị xóa:

```powershell
aws cloudformation list-stacks --region us-east-2 --stack-status-filter CREATE_COMPLETE UPDATE_COMPLETE DELETE_FAILED --query "StackSummaries[].StackName" --output text
aws eks list-clusters --region us-east-2 --output text
aws rds describe-db-instances --region us-east-2 --query "DBInstances[].DBInstanceIdentifier" --output text
aws ec2 describe-nat-gateways --region us-east-2 --filter Name=state,Values=available --query "NatGateways[].NatGatewayId" --output text
aws ec2 describe-addresses --region us-east-2 --query "Addresses[].PublicIp" --output text
aws ec2 describe-instances --region us-east-2 --filters Name=instance-state-name,Values=running,stopped --query "Reservations[].Instances[].InstanceId" --output text
aws elbv2 describe-load-balancers --region us-east-2 --query "LoadBalancers[].LoadBalancerName" --output text
```

Nếu một lệnh `wait` ở các bước trước báo lỗi, bạn xem tài nguyên nào chặn việc xóa stack rồi dọn tài nguyên đó:

```powershell
aws cloudformation describe-stack-events --stack-name <tên-stack> --region us-east-2 --query "StackEvents[?ResourceStatus=='DELETE_FAILED'].[LogicalResourceId,ResourceStatusReason]" --output text
```
