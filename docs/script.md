# One Iceberg Dataset, Two Engines

## Slide 1: One Iceberg dataset, two engines

Chào mọi người. Hôm nay mình sẽ giới thiệu cách xây dựng và vận hành một Open Data Lakehouse sử dụng Snowflake, Apache Iceberg và AWS. Trong các hệ thống dữ liệu truyền thống, dữ liệu thường được đưa vào một Data Warehouse và gắn khá chặt với nền tảng xử lý đó. Nếu muốn sử dụng một query engine khác, chúng ta có thể phải xuất dữ liệu và tạo thêm một bản sao. Open Lakehouse hướng tới việc tách định dạng lưu trữ khỏi compute engine, để nhiều công cụ có thể làm việc trên cùng một tập dữ liệu.

Tuy nhiên, việc sử dụng một định dạng mở chưa giải quyết được toàn bộ vấn đề. Chúng ta vẫn cần một cách đồng bộ dữ liệu từ nguồn, kiểm soát chất lượng trước khi sử dụng và quản lý quyền truy cập giữa các engine. Trong bài này, mình sẽ tập trung vào ba câu hỏi. Thứ nhất, làm sao đồng bộ những thay đổi liên tục từ PostgreSQL vào Lakehouse mà không phải sao chép lại toàn bộ dữ liệu?

Thứ hai, làm sao kiểm tra dữ liệu trước khi đưa vào các bảng phục vụ phân tích?

Và cuối cùng, làm sao để Snowflake và DuckDB cùng truy cập những bảng Iceberg trên S3 mà vẫn tuân thủ quyền hạn?

Để trả lời, chúng ta sẽ theo dõi toàn bộ hành trình dữ liệu từ PostgreSQL đến DuckDB, bắt đầu với kiến trúc tổng thể.

## Slide 2: The big picture

Đây là kiến trúc tổng thể của hệ thống. Ở phía nguồn, PostgreSQL đóng vai trò Operational Database, nơi dữ liệu liên tục được thêm, cập nhật hoặc xóa trong quá trình ứng dụng hoạt động. Snowflake Openflow sử dụng cơ chế Change Data Capture, hay CDC, để đồng bộ những thay đổi này vào tầng Bronze.

Dữ liệu sau đó được xử lý qua các tầng Silver Candidate, Silver và Gold. Silver Candidate là một bản làm việc tạm thời, nơi dữ liệu được biến đổi và kiểm tra trước khi công bố sang Silver. Gold tiếp tục sử dụng dữ liệu Silver đã được kiểm định để tạo các bảng tổng hợp phục vụ phân tích. Trong tutorial, các bảng Bronze, Silver, Gold, Silver Candidate và Sandbox sử dụng Apache Iceberg, với dữ liệu và metadata được lưu trên Amazon S3.

Riêng schema CONTROL chứa các bảng Snowflake thông thường, phục vụ cấu hình và lưu kết quả kiểm tra chất lượng, chẳng hạn DQ_RESULTS và STATION_CITY_OVERRIDE. Ở phía truy vấn, Snowflake là compute engine chính, chịu trách nhiệm ingestion, transformation và quản lý bảng. DuckDB đóng vai trò external engine, truy cập cùng các bảng Iceberg thông qua Horizon Catalog.

Nhìn tổng thể, kiến trúc giải quyết ba bài toán chính: Data Ingestion, Data Quality và Multi-engine Access. Trước khi đi vào từng phần, chúng ta cần hiểu những thành phần cơ bản tạo nên một Open Lakehouse.

## Slide 3: An open lakehouse is more than open files

Một điểm quan trọng của Open Lakehouse là dữ liệu được lưu theo định dạng mở. Tuy nhiên, chỉ lưu các file Parquet trên S3 thì chưa đủ để nhiều engine có thể làm việc với cùng một bảng. Chúng ta cần phân biệt bốn thành phần: Compute, Catalog, Table Format và Storage. Đầu tiên là Compute, nơi thực thi các câu lệnh SQL và xử lý dữ liệu. Trong hệ thống này, Snowflake và DuckDB đều đóng vai trò compute engine.

Thứ hai là Catalog, nơi quản lý thông tin về bảng và giúp engine xác định metadata hiện tại. Ví dụ, khi một engine truy vấn bảng FACT_AQI, catalog giúp nó tìm được metadata tương ứng với trạng thái hiện tại của bảng đó. Thứ ba là Apache Iceberg, một Open Table Format.

Khác với việc chỉ quản lý một thư mục chứa nhiều file Parquet, Iceberg tổ chức trạng thái bảng thông qua metadata, snapshot và manifest. Metadata mô tả cấu trúc và thông tin quản lý bảng. Manifest giúp xác định các data file thuộc về một snapshot. Còn snapshot đại diện cho một trạng thái nhất quán của bảng tại một thời điểm. Nhờ vậy, engine có thể xác định chính xác những file cần đọc mà không phải tự suy luận từ toàn bộ object trong thư mục S3.

Cuối cùng là Storage, nơi lưu các file dữ liệu Parquet và metadata thực tế. Trong tutorial, thành phần này là Amazon S3. Việc tách biệt các trách nhiệm này tạo điều kiện để nhiều engine tương thích cùng sử dụng một tập dữ liệu. Tuy nhiên, dữ liệu được lưu trên S3 thuộc tài khoản AWS của chúng ta. Snowflake không mặc nhiên có quyền truy cập những file đó.

Vì vậy, bước tiếp theo là thiết lập một cơ chế cấp quyền an toàn giữa AWS và Snowflake.

## Slide 4: The external volume connects Snowflake to S3

Trước tiên, chúng ta cần hiểu vấn đề đang giải quyết. Snowflake là một dịch vụ bên ngoài tài khoản AWS chứa dữ liệu của chúng ta. Do đó, Snowflake cần được cấp quyền để đọc và ghi file trên S3, nhưng chúng ta không muốn đưa trực tiếp permanent AWS access key cho dịch vụ bên ngoài. AWS giải quyết bài toán này thông qua IAM Role và AssumeRole.

IAM Role có thể hiểu là một danh tính AWS đi kèm với tập quyền, nhưng không có bộ access key dài hạn gắn cố định giống IAM User thông thường. Một đối tượng được tin cậy có thể tạm thời sử dụng quyền của Role thông qua thao tác gọi là AssumeRole. AssumeRole nghĩa là yêu cầu AWS cho phép sử dụng quyền của một IAM Role trong một khoảng thời gian nhất định.

Khi yêu cầu hợp lệ, AWS Security Token Service, viết tắt là STS, cấp một bộ temporary credentials. Bộ thông tin này thường gồm Access Key ID, Secret Access Key và Session Token. Những credentials này có thời hạn, giúp giảm rủi ro so với việc phân phối permanent credentials cho các hệ thống bên ngoài. Vậy AWS kiểm tra một yêu cầu AssumeRole dựa trên điều gì?

Một IAM Role có hai phần quan trọng.

Permission Policy quy định Role được phép thực hiện những thao tác nào trên tài nguyên. Ví dụ, trong tutorial, Role của Snowflake chỉ được đọc và ghi trong prefix `lakehouse/` của S3 bucket, thay vì có toàn quyền trên toàn bộ tài khoản AWS.

Trust Policy lại trả lời một câu hỏi khác: Đối tượng nào được phép AssumeRole này?

Nói cách khác, Permission Policy xác định quyền sau khi Role được sử dụng, còn Trust Policy xác định ai được phép sử dụng Role. Để Snowflake tham chiếu đến đúng Role, AWS cung cấp Role ARN. ARN là viết tắt của Amazon Resource Name, tức định danh của một tài nguyên trong AWS. Có thể hiểu Role ARN như địa chỉ định danh chính xác của IAM Role mà Snowflake cần sử dụng.

Ngoài ra, chúng ta còn có External ID. External ID là một giá trị được kiểm tra khi bên thứ ba AssumeRole. Nó giúp hạn chế vấn đề Confused Deputy, khi một dịch vụ được nhiều khách hàng tin cậy có thể bị lợi dụng để truy cập nhầm tài nguyên của khách hàng khác. Trong cấu hình của tutorial, yêu cầu AssumeRole phải thỏa mãn cả danh tính được tin cậy và điều kiện External ID.

Bây giờ, tại sao CloudFormation lại cần deploy hai lần?

Nguyên nhân nằm ở một phụ thuộc vòng giữa AWS và Snowflake. Để tạo External Volume trong Snowflake, chúng ta cần biết Role ARN của IAM Role bên AWS. Nhưng để hoàn thiện Trust Policy của IAM Role, chúng ta lại cần biết Snowflake IAM User ARN, tức định danh phía Snowflake sẽ AssumeRole.

Như vậy, AWS cần thông tin từ Snowflake, trong khi Snowflake lại cần thông tin từ AWS. Tutorial xử lý phụ thuộc này bằng hai lần deploy. Ở lần deploy đầu tiên, CloudFormation tạo S3 bucket và IAM Role, sau đó xuất ra những giá trị như Role ARN và External ID.

Chúng ta sử dụng các thông tin này để tạo External Volume trong Snowflake. External Volume là một đối tượng cấu hình của Snowflake, khai báo vị trí lưu trữ bên ngoài cùng cơ chế xác thực để Snowflake có thể truy cập vị trí đó. Sau khi External Volume được tạo, chúng ta dùng DESCRIBE EXTERNAL VOLUME để lấy Snowflake IAM User ARN.

Lần deploy thứ hai không tạo một bộ hạ tầng mới, mà cập nhật Trust Policy của IAM Role đã tồn tại, bổ sung đúng Snowflake IAM User ARN và điều kiện External ID. Khi quan hệ tin cậy được thiết lập, Snowflake có thể AssumeRole thông qua AWS STS để nhận temporary credentials rồi đọc hoặc ghi các file Iceberg trên S3. Hai lần deploy không phải yêu cầu bắt buộc của mọi IAM Role.

Đó là cách tutorial giải quyết phụ thuộc giữa việc tạo External Volume và cấu hình Trust Policy. Trong thực tế, mô hình AssumeRole kết hợp temporary credentials là một cách tích hợp phổ biến giữa AWS và các dịch vụ bên thứ ba, bởi nó giúp tránh chia sẻ access key dài hạn và cho phép quản lý quyền tập trung. Sau khi storage và quyền truy cập đã sẵn sàng, thành phần tiếp theo cần triển khai là Openflow.

## Slide 5: Openflow must be Active before ingestion starts

Openflow là dịch vụ Data Integration của Snowflake, được xây dựng trên Apache NiFi. Apache NiFi là một nền tảng xử lý và điều phối luồng dữ liệu. Nó sử dụng các processor và connection để mô tả cách dữ liệu được tiếp nhận, biến đổi và chuyển giữa các hệ thống. Snowflake Openflow cung cấp các connector và khả năng quản lý để triển khai những luồng dữ liệu như vậy.

Trong tutorial, Openflow được triển khai theo mô hình BYOC, viết tắt của Bring Your Own Cloud. Với BYOC, Snowflake quản lý Control Plane, bao gồm giao diện, API và các chức năng quản lý deployment. Trong khi đó, Data Plane, nơi các connector thực sự chạy và dữ liệu được xử lý, nằm trong tài khoản AWS của người dùng.

Tại sao cần tách hai phần này?

Một lý do quan trọng là kiểm soát network và nơi xử lý dữ liệu. Trong thực tế, operational database thường nằm trong private network và không được phép mở trực tiếp ra Internet. Nếu connector chạy ở một môi trường không có đường kết nối phù hợp, chúng ta phải xây dựng thêm cơ chế networking để truy cập database nguồn.

Với BYOC, Data Plane có thể được triển khai vào VPC của doanh nghiệp. Trong tutorial, PostgreSQL chạy trên EC2 ở private subnet, còn Openflow được triển khai trong cùng VPC. Vì vậy, connector có thể truy cập PostgreSQL thông qua private IP. Để hiểu cách triển khai này, Openflow có ba thành phần quan trọng: Deployment, Runtime và Connector.

Deployment là lớp hạ tầng nền. Trong mô hình BYOC của bài, Deployment sử dụng những thành phần AWS như EKS, RDS và Load Balancer để cung cấp môi trường vận hành. Amazon EKS là dịch vụ Kubernetes được AWS quản lý. Kubernetes đảm nhiệm việc điều phối các container và tài nguyên tính toán cần thiết.

RDS ở đây phục vụ hạ tầng nội bộ của Openflow, không phải PostgreSQL operational source mà pipeline sẽ đọc dữ liệu.

Runtime là môi trường thực thi nằm bên trong Deployment. Nếu Deployment cung cấp cơ sở hạ tầng chung, thì Runtime là nơi các flow và connector được phân bổ tài nguyên để hoạt động. Runtime có thể được cấu hình số node, kích thước node và execute-as role.

Execute-as role đặc biệt quan trọng vì nó xác định quyền Snowflake được sử dụng khi connector thực hiện các thao tác.

Connector là thành phần chứa logic tích hợp dữ liệu cụ thể. Trong bài này, PostgreSQL Connector chịu trách nhiệm kết nối database nguồn, thực hiện Initial Snapshot, đọc các thay đổi bằng CDC và ghi dữ liệu vào Bronze. Như vậy, Deployment, Runtime và Connector có ba trách nhiệm khác nhau: cung cấp hạ tầng, cung cấp môi trường thực thi và thực hiện logic đồng bộ.

Trong tutorial, Deployment được tạo trước và phải chuyển sang trạng thái Active. Sau đó, Runtime được tạo bên trong Deployment và cũng cần chuyển sang Active. Cuối cùng, PostgreSQL Connector mới được cài đặt vào Runtime và khởi chạy.

Việc tách các lớp này giúp quản lý tài nguyên, quyền truy cập và các pipeline độc lập hơn. Tuy nhiên, BYOC cũng đi kèm trách nhiệm vận hành và chi phí hạ tầng. Những thành phần như EKS, NAT Gateway hoặc RDS có thể tiếp tục phát sinh chi phí ngay cả khi pipeline không xử lý dữ liệu. Vì vậy, BYOC phù hợp với những trường hợp cần kiểm soát môi trường chạy hoặc network, nhưng không mặc nhiên là lựa chọn tối ưu cho mọi workload.

Khi connector đã sẵn sàng, quá trình đồng bộ dữ liệu bắt đầu.

## Slide 6: Take a snapshot, then stream changes

Một bài toán cơ bản của CDC là làm sao đồng bộ cả dữ liệu đã tồn tại từ trước và những thay đổi mới phát sinh. Giả sử một bảng PostgreSQL đã có một triệu dòng. Nếu connector chỉ bắt đầu đọc các thay đổi từ thời điểm hiện tại, những dòng đã tồn tại trước đó sẽ không tự xuất hiện ở destination. Vì vậy, quá trình CDC thường kết hợp hai giai đoạn: Initial Snapshot và Continuous Change Capture.

Initial Snapshot là bước sao chép trạng thái dữ liệu hiện có ở nguồn để tạo baseline cho hệ thống đích. Trong tutorial, snapshot ban đầu chứa 23 trạm quan trắc và 2.117 bản ghi measurements. Sau khi dữ liệu này được đưa vào Bronze, connector chuyển sang giai đoạn Continuous CDC.

Ở giai đoạn thứ hai, connector không cần liên tục quét lại toàn bộ bảng. Thay vào đó, nó theo dõi những thay đổi phát sinh từ transaction log của PostgreSQL. Ví dụ, nếu một bảng có một triệu dòng nhưng mỗi phút chỉ có 100 dòng thay đổi, hệ thống CDC có thể tập trung xử lý những thay đổi đó thay vì sao chép lại toàn bộ một triệu dòng. Tuy nhiên, có một vấn đề đáng chú ý.

Trong lúc Initial Snapshot đang diễn ra, ứng dụng vẫn có thể tiếp tục ghi dữ liệu vào PostgreSQL. Nếu snapshot và quá trình đọc thay đổi không được phối hợp đúng cách, hệ thống có nguy cơ bỏ sót hoặc áp dụng trùng các thay đổi. Vì vậy, một CDC connector cần có cơ chế xác định mốc nhất quán giữa dữ liệu được sao chép ban đầu và luồng thay đổi tiếp theo.

PostgreSQL cung cấp các cơ chế liên quan đến snapshot, logical replication và vị trí trong transaction log để hỗ trợ việc này. Cách phối hợp cụ thể phụ thuộc vào implementation của connector. Một điều khác cần phân biệt là Continuous CDC không đồng nghĩa với toàn bộ Lakehouse được cập nhật tức thời. Connector có thể liên tục nhận sự kiện nhưng quá trình áp dụng các thay đổi vào bảng Bronze vẫn được thực hiện theo lịch.

Trong tutorial, lịch MERGE được đặt mỗi phút. Vì vậy, dữ liệu có thể đã được connector nhận nhưng chưa xuất hiện ngay trong trạng thái hiện tại của Bronze. Cuối cùng, cần tránh nhầm lẫn giữa hai khái niệm Snapshot.

Initial Snapshot của CDC là bước sao chép dữ liệu nguồn để khởi tạo destination. Trong khi đó, Iceberg Snapshot là một phiên bản logic của bảng được quản lý thông qua metadata. Hai khái niệm này có cùng tên nhưng giải quyết hai vấn đề khác nhau.

Vậy làm sao PostgreSQL cung cấp được các thay đổi INSERT, UPDATE và DELETE mà không cần quét lại toàn bộ bảng?

Câu trả lời nằm ở WAL và Logical Replication.

## Slide 7: WAL to Openflow

PostgreSQL sử dụng một cơ chế gọi là Write-Ahead Log, viết tắt là WAL. WAL được thiết kế chủ yếu để bảo đảm tính bền vững và hỗ trợ phục hồi dữ liệu khi database gặp sự cố. Nguyên tắc cơ bản là thông tin thay đổi cần thiết để phục hồi được ghi vào log trước khi những thay đổi tương ứng được ghi bền vững vào các data page.

Nhờ vậy, nếu PostgreSQL gặp sự cố, hệ thống có thể sử dụng WAL để khôi phục trạng thái nhất quán. Tuy nhiên, WAL ban đầu không phải một danh sách câu lệnh SQL mà các hệ thống bên ngoài có thể đọc và hiểu trực tiếp. Đây là nơi Logical Decoding xuất hiện.

Logical Decoding chuyển thông tin thay đổi trong WAL thành những sự kiện logic ở mức bảng và dòng dữ liệu, để một consumer bên ngoài có thể xử lý. Trong PostgreSQL Logical Replication, có ba thành phần quan trọng cần phân biệt: Publication, Replication Slot và Replica Identity.

Publication xác định phạm vi dữ liệu được xuất bản. Ví dụ, một database có 100 bảng nhưng pipeline phân tích chỉ cần hai bảng stations và measurements. Thay vì replicate toàn bộ database, chúng ta tạo Publication để đưa đúng những bảng cần thiết vào luồng thay đổi.

Publication cũng có thể xác định những loại thao tác được phát đi.

Replication Slot đảm nhiệm một trách nhiệm khác. Nó theo dõi tiến độ mà consumer đã xác nhận xử lý trong luồng thay đổi. PostgreSQL sử dụng thông tin này để xác định phần WAL nào vẫn cần được giữ lại cho consumer.

Vị trí trong WAL thường được biểu diễn bằng LSN, viết tắt của Log Sequence Number. Có thể hiểu LSN như một địa chỉ trong chuỗi log, giúp xác định consumer đã đọc đến đâu. Nếu Openflow tạm thời mất kết nối, Replication Slot giúp quá trình đọc có thể tiếp tục từ tiến độ phù hợp thay vì mặc nhiên bỏ qua những thay đổi phát sinh trong khoảng thời gian đó.

Tuy nhiên, Replication Slot không tự bảo đảm rằng mọi downstream system đều xử lý chính xác một lần trong mọi tình huống. Connector vẫn cần xử lý trường hợp sự kiện được gửi lại sau lỗi hoặc restart, để trạng thái đích không bị sai lệch.

Replica Identity lại giải quyết một vấn đề khác: Làm sao xác định đúng dòng đã được UPDATE hoặc DELETE?

Ví dụ, khi PostgreSQL phát một sự kiện DELETE cho measurement ID 434, Openflow cần biết dòng nào ở Bronze tương ứng với sự kiện đó. Nếu bảng có Primary Key, khóa chính thường được sử dụng làm Replica Identity. Nếu không có khóa nhận diện phù hợp, việc replicate UPDATE hoặc DELETE trở nên phức tạp hơn và có thể cần cấu hình bổ sung.

Cuối cùng, Replication Slot cũng tạo ra một trách nhiệm vận hành. Nếu connector ngừng hoạt động quá lâu và không xác nhận tiến độ, PostgreSQL có thể phải giữ lại lượng WAL ngày càng lớn. Điều này làm tăng dung lượng lưu trữ và có thể gây ảnh hưởng đến database nguồn.

Vì vậy, trong production, các chỉ số như replication lag, trạng thái slot và dung lượng WAL cần được theo dõi. Các thành phần này phối hợp với nhau, không phải các bước biến đổi dữ liệu tuần tự. WAL ghi nhận thay đổi, Publication giới hạn phạm vi được xuất bản, Replication Slot theo dõi tiến độ đọc, còn Replica Identity xác định dòng bị cập nhật hoặc xóa.

Openflow sử dụng những cơ chế đó để tiếp nhận các sự kiện CDC và chuyển sang destination.

## Slide 8: Merge the latest event for each key

Sau khi nhận các thay đổi từ PostgreSQL, Openflow không nhất thiết ghi từng sự kiện trực tiếp vào trạng thái cuối cùng của Bronze. Trong thiết kế của connector ở tutorial, dữ liệu thay đổi được xử lý thông qua Journal và bảng Bronze. Journal ghi lại các sự kiện CDC nhận từ nguồn, bao gồm loại thao tác, định danh dòng và những giá trị liên quan.

Ví dụ, cùng một Primary Key có thể lần lượt xuất hiện trong các sự kiện INSERT, UPDATE và DELETE. Journal giúp lưu lại lịch sử những thay đổi đã nhận, trong khi Bronze thể hiện trạng thái đã được tổng hợp theo khóa. Theo lịch được cấu hình, connector thực hiện MERGE các thay đổi chưa được áp dụng từ Journal vào Bronze.

Với INSERT, một dòng mới được thêm vào nếu khóa chưa tồn tại. Với UPDATE, dòng tương ứng được cập nhật theo thay đổi mới nhất. Riêng DELETE được xử lý bằng Soft Delete.

Thay vì xóa vật lý dòng khỏi Bronze, connector đánh dấu cột `_SNOWFLAKE_DELETED` bằng TRUE. Nhờ đó, Bronze vẫn giữ thông tin về dòng từng tồn tại ở nguồn, nhưng các tầng downstream có thể loại dòng đó khỏi trạng thái dữ liệu hiện tại. Việc tách Journal và Bronze còn giúp connector không phải thực hiện một thao tác MERGE riêng cho từng sự kiện nhỏ lẻ.

Tuy nhiên, cách làm này tạo ra một khoảng trễ giữa thời điểm nhận sự kiện và thời điểm Bronze được cập nhật. Trong tutorial, lịch MERGE được đặt mỗi phút để cân bằng giữa độ mới của dữ liệu và chi phí xử lý. Các thiết lập này được cấu hình trong PostgreSQL Connector, mà chúng ta sẽ xem ở slide tiếp theo.

## Slide 9: Three screens define the data path

PostgreSQL Connector có năm bước cấu hình: Source, Replication, Destination Details, Tuning và Migration. Trên slide, mình chọn ba màn hình thể hiện những quyết định quan trọng nhất về đường đi của dữ liệu: Source xác định nơi đọc, Migration quyết định cách khởi tạo đồng bộ, còn Destination xác định nơi ghi và định dạng bảng. Hai bước còn lại là Replication và Tuning, mình sẽ giải thích bổ sung sau.

Đầu tiên là Source. Bước này trả lời câu hỏi connector kết nối đến database nào và sử dụng danh tính gì. Chúng ta khai báo JDBC URL, tài khoản replicator, mật khẩu và Publication.

JDBC là một giao diện kết nối database trong hệ sinh thái Java. JDBC URL chứa những thông tin như host, port và tên database mà connector cần truy cập. Trong tutorial, PostgreSQL nằm trong private subnet, nên connector sử dụng private IP của EC2 để kết nối. Tài khoản replicator được cấp những quyền cần thiết để đọc bảng và sử dụng logical replication.

Việc dùng một tài khoản riêng giúp tránh phải sử dụng tài khoản quản trị database cho hoạt động đồng bộ thường xuyên.

Tiếp theo là Migration. Đây là nơi quyết định connector bắt đầu đồng bộ dữ liệu như thế nào. Tutorial sử dụng chế độ Full, nghĩa là thực hiện Initial Snapshot trước rồi tiếp tục CDC.

Nếu chọn Incremental ngay từ đầu khi destination chưa có dữ liệu, các dòng đã tồn tại trước đó sẽ không được sao chép đầy đủ. Vì vậy, Full phù hợp khi chúng ta xây dựng Bronze từ đầu. Incremental chỉ phù hợp khi trạng thái ban đầu đã được chuẩn bị bằng một quy trình khác hoặc khi việc bỏ qua snapshot là có chủ đích. Ở bước này, tutorial cũng đặt tên cố định cho Replication Slot để dễ kiểm tra và theo dõi.

Cuối cùng là Destination. Bước này trả lời câu hỏi dữ liệu được ghi vào đâu và sử dụng định dạng nào. Trong tutorial, destination là database AQ_LAKEHOUSE, sử dụng Snowflake Warehouse để xử lý các thao tác cần thiết.

Table Storage Format được chọn là Iceberg, với Iceberg Version 3. Việc chọn Iceberg rất quan trọng vì mục tiêu cuối cùng không chỉ là đọc dữ liệu bằng Snowflake, mà còn cho phép DuckDB truy cập cùng các bảng thông qua Horizon Catalog. Ngoài ba màn hình trên, connector còn hai bước cấu hình khác.

Replication xác định phạm vi bảng và cột mà connector sẽ xử lý. Phạm vi này phải phù hợp với PostgreSQL Publication đã cấu hình ở nguồn. Publication xác định những thay đổi được phía nguồn xuất bản, còn cấu hình Replication của connector xác định phạm vi dữ liệu mà connector được thiết lập để đồng bộ.

Tuning kiểm soát các tham số vận hành, trong đó có lịch MERGE và những cấu hình ảnh hưởng đến quá trình snapshot. MERGE thường xuyên hơn có thể giảm độ trễ, nhưng cũng làm tăng tần suất xử lý và chi phí compute. MERGE thưa hơn có thể tiết kiệm tài nguyên, nhưng Bronze sẽ cập nhật chậm hơn.

Vì vậy, đây là một đánh đổi giữa Data Freshness và chi phí vận hành. Trong tutorial, chúng ta sử dụng Full Snapshot, theo dõi hai bảng nguồn và MERGE mỗi phút. Sau khi connector được khởi chạy, các kết quả ở Bronze sẽ cho thấy cấu hình này có hoạt động đúng hay không.

## Slide 10: Bronze follows the source

Để kiểm chứng CDC, tutorial thực hiện ba thao tác trực tiếp trên PostgreSQL. Ban đầu, Bronze chứa 23 stations và 2.117 measurements, khớp với kết quả Initial Snapshot. Thao tác đầu tiên là INSERT một measurement mới có ID 2118.

Sau khi connector đồng bộ, tổng số dòng measurements trong Bronze tăng từ 2.117 lên 2.118. Thao tác thứ hai là UPDATE measurement ID 320, đặt AQI và PM2.5 thành 275. Khi truy vấn Bronze, những giá trị này đã được cập nhật đúng như mong đợi.

Cuối cùng là DELETE measurement ID 434. Dòng này không biến mất khỏi Bronze. Thay vào đó, `_SNOWFLAKE_DELETED` chuyển thành TRUE, cho biết dòng đã bị xóa ở nguồn. Như vậy, ba thao tác INSERT, UPDATE và DELETE đều được phản ánh đúng trong Bronze.

Tuy nhiên, Bronze vẫn chứa dữ liệu tương đối gần với nguồn, bao gồm những giá trị chưa được chuẩn hóa và các dòng Soft Delete. Vì vậy, dữ liệu mới nhất chưa chắc đã là dữ liệu phù hợp để đưa trực tiếp vào phân tích. Đó là lý do chúng ta cần Silver, Gold và quy trình kiểm soát chất lượng.

## Slide 11: From current data to trusted analytics

Trong kiến trúc Medallion, các tầng Bronze, Silver và Gold có những vai trò khác nhau. Bronze tập trung vào việc tiếp nhận dữ liệu nguồn và giữ lại những thông tin cần thiết cho quá trình xử lý. Silver tập trung vào dữ liệu đã được làm sạch, chuẩn hóa và kiểm định.

Gold phục vụ các nhu cầu phân tích cụ thể, thường thông qua các bảng tổng hợp. Tuy nhiên, Medallion không bắt buộc một mô hình dữ liệu cố định cho từng tầng. Trong tutorial này, Silver được tổ chức thành star schema, gồm bảng fact FACT_AQI và bốn bảng dimension: DIM_DATE, DIM_TIME, DIM_CITY và DIM_STATION.

Star schema giúp tổ chức dữ liệu phân tích quanh bảng fact chứa các phép đo và các bảng dimension mô tả ngữ cảnh của phép đo đó. Ví dụ, FACT_AQI lưu dữ liệu quan trắc, trong khi các bảng dimension giúp phân tích theo ngày, giờ, thành phố hoặc trạm. Gold lấy mô hình chi tiết này để tạo những bảng tổng hợp phục vụ từng nhu cầu phân tích, chẳng hạn thống kê AQI theo ngày hoặc xếp hạng thành phố theo tháng.

Nhưng có một vấn đề cần giải quyết trước khi xây dựng Silver. Nếu pipeline trực tiếp cập nhật bảng Silver rồi mới kiểm tra chất lượng, người dùng có thể truy vấn phải dữ liệu lỗi trong khoảng thời gian đó. Vì vậy, chúng ta cần tách quá trình chuẩn bị dữ liệu khỏi quá trình công bố dữ liệu.

Đây là mục đích của Write-Audit-Publish.

## Slide 12: A candidate isolates unfinished work

Trước khi giải thích Candidate, chúng ta cần hiểu một đặc điểm quan trọng của Apache Iceberg. Trong Iceberg, trạng thái của bảng không được xác định đơn giản bằng tất cả những file đang nằm trong một thư mục. Thay vào đó, metadata và snapshot xác định những data file nào thuộc về trạng thái hiện tại của bảng.

Cơ chế quản lý metadata này tạo điều kiện cho một kỹ thuật gọi là Zero-Copy Clone. Giả sử Silver hiện tại đang tham chiếu tới ba data file trên S3. Khi tạo Candidate bằng Zero-Copy Clone, Snowflake không cần sao chép lại toàn bộ ba file đó.

Thay vào đó, Candidate được tạo với metadata riêng và ban đầu có thể tham chiếu tới những data file đang được Silver sử dụng. Như vậy, Silver và Candidate là hai bảng độc lập về trạng thái logic, nhưng chia sẻ phần dữ liệu vật lý chưa thay đổi. Sau khi clone, pipeline thực hiện MERGE dữ liệu từ Bronze vào Candidate.

Những thay đổi này sẽ tạo ra các file dữ liệu hoặc metadata mới cần thiết cho trạng thái Candidate, mà không tự động thay đổi trạng thái Silver. Vì vậy, Zero-Copy Clone không có nghĩa là hệ thống sẽ không bao giờ ghi thêm file. Nó có nghĩa bước tạo bản sao ban đầu không cần nhân đôi toàn bộ dữ liệu.

Lợi ích là giảm thời gian khởi tạo và tránh chi phí sao chép dữ liệu không cần thiết. Bây giờ, tại sao tutorial chỉ clone DIM_STATION và FACT_AQI?

Lý do là hai bảng này phụ thuộc trực tiếp vào dữ liệu được cập nhật bằng CDC. FACT_AQI chứa các phép đo chất lượng không khí. Khi nguồn phát sinh measurement mới, cập nhật hoặc xóa measurement, bảng fact cần được cập nhật tương ứng. DIM_STATION chứa thông tin trạm quan trắc, cũng có thể thay đổi khi dữ liệu stations ở nguồn thay đổi.

Trong khi đó, DIM_DATE và DIM_TIME là các bảng dimension đã được chuẩn bị trước. DIM_CITY cũng được xử lý như dữ liệu tham chiếu đã chuẩn bị sẵn trong phạm vi tutorial. Do đó, pipeline không cần clone lại tất cả các bảng dimension mỗi lần chạy.

Tuy nhiên, đây là quyết định dựa trên đặc điểm dữ liệu của bài, không phải quy tắc chung của star schema. Trong một hệ thống thực tế, nếu các bảng dimension khác cũng thay đổi, chúng cần được đưa vào quy trình cập nhật và kiểm tra phù hợp. Candidate tạo ra một vùng làm việc tách biệt.

Downstream vẫn đọc Silver hiện tại trong khi dữ liệu mới được chuẩn bị và kiểm tra. Nếu Candidate không đạt yêu cầu, Silver sẽ không bị ảnh hưởng.

## Slide 13: A failed check leaves Silver unchanged

Sau khi Candidate được xây dựng, pipeline chuyển sang bước Audit bằng Soda. Ở đây, chúng ta cần phân biệt hai vấn đề. Một pipeline chạy thành công về mặt kỹ thuật chưa chắc đã tạo ra dữ liệu đúng về mặt nghiệp vụ.

Ví dụ, trong bước transformation, FACT_AQI cần JOIN với các bảng dimension để tìm khóa ngày, giờ, thành phố và trạm quan trắc. Nếu một dòng dữ liệu không tìm được bảng dimension tương ứng, nó có thể bị loại khỏi kết quả JOIN mà không gây lỗi SQL. Câu lệnh vẫn chạy thành công, nhưng kết quả có thể bị thiếu dữ liệu.

Đây là lý do tutorial có phép kiểm tra đối soát số dòng giữa Candidate và số dòng còn hiệu lực trong Bronze. Ngoài ra, các phép kiểm tra còn bao gồm tính duy nhất của Measurement ID, phạm vi hợp lệ của AQI, khóa không được NULL và tính toàn vẹn tham chiếu. Tổng cộng có 22 checks.

Trong đó, 18 checks thuộc nhóm Blocking và 4 checks thuộc nhóm Warning. Sự khác nhau giữa hai nhóm này rất quan trọng.

Kiểm tra chặn, hay blocking check, là điều kiện bắt buộc. Nếu không đạt, Candidate không được phép Publish.

Kiểm tra cảnh báo, hay warning check, ghi nhận một vấn đề cần theo dõi, nhưng chưa nhất thiết khiến dữ liệu không thể sử dụng. Ví dụ, dữ liệu chất lượng không khí thực tế có thể có một tỷ lệ giá trị AQI bị thiếu. Nếu cứ xuất hiện một giá trị NULL là pipeline dừng lại, hệ thống có thể không bao giờ công bố được dữ liệu.

Vì vậy, tutorial cho phép một mức độ thiếu dữ liệu trong giới hạn được kiểm soát và sử dụng Warning để cảnh báo khi vượt ngưỡng. Sau khi Audit hoàn tất, chúng ta có hai nhánh xử lý.

Nếu Audit có Blocking Failure, hoặc bản thân quá trình Audit không thể chạy, pipeline không tiếp tục Publish. Silver giữ nguyên phiên bản đã được công bố trước đó.

Nếu Audit không có Blocking Failure, kể cả trường hợp chỉ xuất hiện Warning, Candidate được phép chuyển sang bước Publish. Đây là nguyên lý Quality Gate: dữ liệu phải vượt qua những điều kiện quan trọng trước khi được công bố cho downstream. Tuy nhiên, điều này cũng tạo ra một đánh đổi.

Nếu Audit liên tục thất bại, Silver sẽ không nhận dữ liệu mới. Dữ liệu đang phục vụ vẫn đáp ứng các tiêu chuẩn đã kiểm tra ở lần Publish trước, nhưng độ mới của nó sẽ giảm xuống. Vì vậy, trong production, một quy trình WAP tốt cần đi kèm monitoring, cảnh báo, retry và cơ chế xử lý khi dữ liệu không được Publish trong khoảng thời gian vượt quá yêu cầu.

## Slide 14: Publish Silver only after the audit passes

Bây giờ chúng ta tổng hợp lại toàn bộ quy trình Write-Audit-Publish. Bước đầu tiên là Write. Pipeline tạo Candidate bằng Zero-Copy Clone từ Silver hiện tại, sau đó MERGE những thay đổi từ Bronze vào Candidate.

Tiếp theo là Audit. Soda chạy các Data Quality Checks để xác định Candidate có đáp ứng những tiêu chuẩn cần thiết hay không. Nếu có Blocking Failure, hoặc quá trình Audit gặp lỗi, pipeline dừng lại.

Publish và bước xây dựng Gold không được thực hiện. Silver giữ phiên bản đã được công bố trước đó. Nếu không có Blocking Failure, pipeline chuyển sang Publish.

Trong tutorial, Publish sử dụng hai câu lệnh INSERT OVERWRITE để thay thế nội dung DIM_STATION và FACT_AQI bằng kết quả từ Candidate. Mỗi câu INSERT OVERWRITE được thực thi và commit riêng. Vì vậy, một truy vấn đọc từng bảng sẽ nhìn thấy trạng thái trước hoặc sau khi câu lệnh commit, thay vì trạng thái đang được ghi dở.

Tuy nhiên, cần phân biệt atomicity của một câu lệnh với atomicity của toàn bộ quy trình Publish. Trong tutorial, DIM_STATION và FACT_AQI được cập nhật tuần tự, không nằm trong cùng một transaction. Do đó, có thể tồn tại một khoảng thời gian ngắn khi DIM_STATION đã được cập nhật nhưng FACT_AQI vẫn đang ở phiên bản trước.

Đây là giới hạn của cách triển khai Publish trong tutorial, không phải giới hạn tuyệt đối của Snowflake. Snowflake có hỗ trợ transaction cho các thao tác phù hợp trên Iceberg tables, nhưng pipeline hiện tại không sử dụng một transaction chung cho hai câu Publish. Thứ tự cập nhật cũng được lựa chọn có chủ đích.

DIM_STATION được Publish trước, trong khi các station key hiện có được giữ ổn định, nhằm hạn chế trường hợp bảng fact ở phiên bản cũ không thể tham chiếu đến bảng dimension mới. Sau khi Silver được Publish thành công, pipeline tiếp tục xây dựng Gold. Gold nằm ngoài vòng WAP. Vì vậy, nếu bước Gold thất bại, Silver đã được Publish sẽ không tự động rollback.

Trong production, đây là lý do cần xem xét thêm retry, idempotency, concurrent execution và tính nhất quán giữa những bảng có quan hệ phụ thuộc. Như vậy, WAP giúp kiểm soát chất lượng trước khi công bố, nhưng để vận hành ở quy mô lớn, chúng ta vẫn cần thiết kế cơ chế quản lý phiên bản và xử lý lỗi phù hợp.

## Slide 15: Validated Silver powers Gold analytics

Sau khi hoàn tất Write-Audit-Publish, chúng ta có một phiên bản Silver chứa dữ liệu đã vượt qua các phép kiểm tra chất lượng. Trong tutorial, sau ba thay đổi CDC, Bronze chứa 2.118 measurements, trong đó một dòng được đánh dấu Soft Delete. Khi dữ liệu được đưa sang Silver, dòng đã bị xóa ở nguồn được loại bỏ.

Vì vậy, FACT_AQI trong Silver chứa 2.117 dòng còn hiệu lực. Từ phiên bản Silver này, pipeline xây dựng các bảng Gold phục vụ phân tích. Ở slide này, chúng ta đang xem kết quả bảng xếp hạng AQI theo thành phố trong tháng 1 năm 2021.

Điểm đáng chú ý là Gold không chỉ sao chép dữ liệu từ Silver. Nó tổng hợp dữ liệu chi tiết thành những thông tin phục vụ người dùng cuối, chẳng hạn AQI trung bình và thứ hạng ô nhiễm của từng thành phố. Trong tutorial, bảng xếp hạng sử dụng DENSE_RANK để xác định thứ hạng theo từng tháng.

Nhìn vào kết quả, chúng ta có tổng cộng 11 thành phố. Trong đó, 9 thành phố có giá trị AQI hợp lệ để tính trung bình và xếp hạng. Hai thành phố Đà Nẵng và Nha Trang không có giá trị AQI hợp lệ trong tập dữ liệu đang xét, nên AVG_AQI và AQI_RANK nhận giá trị NULL.

Đây là một hành vi được thiết kế có chủ đích. Nếu một thành phố không có dữ liệu AQI hợp lệ nhưng hệ thống vẫn cố gắng gán thứ hạng, kết quả có thể gây hiểu nhầm cho người sử dụng. Một chi tiết khác là cột DAYS_OBSERVED vẫn có giá trị 9 cho các thành phố này.

Điều đó cho biết có chín ngày quan sát được ghi nhận theo logic tổng hợp, nhưng không có nghĩa tất cả những ngày đó đều có giá trị AQI hợp lệ. Như vậy, Gold không chỉ tạo ra bảng tổng hợp mà còn phải giữ đúng cách xử lý những giá trị thiếu. Các thay đổi INSERT, UPDATE và DELETE riêng lẻ đã được kiểm tra ở Bronze và Silver.

Còn kết quả trên slide này minh họa cách Gold sử dụng trạng thái Silver đã Publish để tạo ra thông tin phân tích. Bây giờ, câu hỏi tiếp theo là: Liệu chúng ta có thể đọc chính những bảng này bằng một query engine khác ngoài Snowflake hay không?

## Slide 16: Horizon resolves the table, S3 serves the files

Đến đây, chúng ta đã có các bảng Iceberg trên S3 và có thể truy vấn chúng bằng Snowflake. Nhưng nếu một ứng dụng muốn sử dụng DuckDB để đọc cùng dữ liệu thì sao?

Một cách đơn giản là cấp AWS access key trực tiếp cho DuckDB để truy cập S3. Tuy nhiên, cách này tạo thêm vấn đề bảo mật. Chúng ta phải quản lý AWS credentials ở một hệ thống khác, đồng thời phải tự bảo đảm những credentials đó chỉ có quyền truy cập đúng những dữ liệu cần thiết.

Trong tutorial, thay vì sử dụng permanent AWS key, DuckDB kết nối thông qua Horizon Catalog và cơ chế Vended Credentials. Để hiểu cơ chế này, chúng ta cần phân biệt hai lớp quyền truy cập.

Lớp thứ nhất là quyền truy cập Catalog. DuckDB phải chứng minh danh tính của mình trước khi yêu cầu metadata của bảng. Trong tutorial, DuckDB sử dụng một Service User và Programmatic Access Token, viết tắt là PAT.

PAT là token dành cho truy cập bằng chương trình, giúp client xác thực mà không phải thực hiện đăng nhập thủ công bằng mật khẩu và MFA trong mỗi lần chạy. Client sử dụng PAT để lấy một access token phục vụ việc giao tiếp với Horizon Catalog. Access token được gắn với danh tính và quyền hạn phù hợp của user.

Khi DuckDB yêu cầu truy cập một bảng, Horizon kiểm tra role đang sử dụng có quyền truy cập bảng đó hay không. Nếu được phép, Horizon cung cấp metadata để DuckDB xác định trạng thái hiện tại của bảng Iceberg. Metadata này giúp DuckDB biết snapshot nào đang được sử dụng và những data file nào thuộc về trạng thái bảng đó.

Tuy nhiên, biết dữ liệu nằm ở đâu vẫn chưa đủ để đọc dữ liệu. S3 không sử dụng Snowflake PAT để xác thực các yêu cầu truy cập object. Đây là lý do cần lớp thứ hai.

Lớp thứ hai là quyền truy cập Storage. Thông qua Vended Credentials, Horizon cung cấp temporary cloud storage credentials phù hợp với quyền của external role. Những credentials này được DuckDB sử dụng để truy cập các file trên S3.

Nói đơn giản, DuckDB không cần giữ permanent AWS credentials của doanh nghiệp. Nó nhận credentials tạm thời để thực hiện những thao tác mà role được phép. Sau khi có metadata và credentials, DuckDB đọc các file Parquet trực tiếp từ S3.

Điểm đáng chú ý là dữ liệu không cần được truy vấn thông qua Snowflake Warehouse rồi chuyển sang DuckDB. Horizon chịu trách nhiệm quản lý metadata và hỗ trợ kiểm soát quyền truy cập. S3 chịu trách nhiệm cung cấp các file dữ liệu thực tế.

Nhờ đó, chúng ta tách được quá trình khám phá và quản trị bảng khỏi quá trình đọc dữ liệu. Đây là một cơ chế quan trọng để nhiều query engine có thể sử dụng cùng một tập dữ liệu Iceberg mà không cần duy trì những bản sao riêng.

## Slide 17: The external role is read-first by design

Ở slide trước, chúng ta đã thấy Horizon có thể cung cấp metadata và temporary credentials cho external engine. Nhưng câu hỏi tiếp theo là: Làm sao bảo đảm external engine chỉ thực hiện những thao tác được phép?

Trong thực tế, một Data Platform thường có nhiều nhóm người sử dụng. Data Engineer cần quyền tạo bảng, cập nhật dữ liệu và vận hành pipeline. Data Analyst chủ yếu cần quyền đọc những bảng đã được chuẩn bị để phục vụ phân tích.

Các ứng dụng hoặc dịch vụ bên ngoài cũng có nhu cầu truy cập, nhưng không nên mặc nhiên sử dụng cùng tài khoản và bộ quyền với nhóm quản trị. Đây là nguyên tắc Least Privilege, tức chỉ cấp những quyền thực sự cần thiết để một đối tượng hoàn thành công việc. Trong Snowflake, cơ chế này thường được tổ chức bằng Role-Based Access Control, viết tắt là RBAC.

Thay vì cấp trực tiếp mọi quyền cho từng user, chúng ta định nghĩa Role, cấp quyền cho Role rồi gắn Role đó với user hoặc service tương ứng. Trong tutorial, DuckDB sử dụng một Service User cùng role AQ_EXTERNAL. Role này chủ yếu được cấp quyền SELECT trên Silver và Gold.

Lý do là hai tầng này phục vụ truy vấn phân tích, trong khi Bronze vẫn chứa dữ liệu gần với nguồn, bao gồm những giá trị chưa được chuẩn hóa hoàn toàn và các thông tin kỹ thuật như Soft Delete. Schema CONTROL cũng không cần được truy cập bởi một external engine chỉ phục vụ phân tích. Vì vậy, AQ_EXTERNAL không được cấp quyền trên Bronze và CONTROL, đồng thời không có quyền ghi vào Silver hoặc Gold.

Cách chia này giúp tách quyền sử dụng dữ liệu khỏi quyền quản trị pipeline. Tuy nhiên, trong tutorial có một ngoại lệ cần giải thích: Silver Candidate. Candidate được tạo bằng Zero-Copy Clone từ Silver, nên các bảng clone có thể cùng tham chiếu tới những data file vật lý.

Với cơ chế Vended Credentials của Horizon, quyền truy cập các bảng liên quan đến clone cần đáp ứng những điều kiện nhất định để catalog có thể cấp storage credentials. Nếu thiếu quyền phù hợp trên những bảng clone liên quan, yêu cầu credential vending có thể bị từ chối dù role có quyền SELECT trên bảng Silver cần đọc. Vì vậy, tutorial cấp thêm quyền đọc trên SILVER_CANDIDATE cho AQ_EXTERNAL.

Đây là một yêu cầu kỹ thuật phát sinh từ cách kết hợp clone và Horizon trong kiến trúc này. Tuy nhiên, chúng ta cần phân biệt yêu cầu kỹ thuật với nguyên tắc thiết kế bảo mật. Khi role có quyền SELECT trên Candidate, nó cũng có khả năng truy cập dữ liệu chưa được Publish.

Điều này không hoàn toàn trùng với mục tiêu chỉ cho external consumer đọc dữ liệu đã qua kiểm tra. Trong một hệ thống production có yêu cầu bảo mật nghiêm ngặt, chúng ta cần đánh giá trade-off này và cân nhắc cách tổ chức staging, clone hoặc phân quyền phù hợp hơn. Ngoại lệ thứ hai là Sandbox.

Sandbox được sử dụng để kiểm tra khả năng ghi dữ liệu từ DuckDB và không tham gia pipeline Bronze, Silver hay Gold. Role AQ_EXTERNAL được cấp quyền đọc và ghi trên bảng Sandbox, trong khi Silver và Gold vẫn ở chế độ read-only. Điều này cho phép chúng ta kiểm chứng rằng cùng một external engine có thể có quyền khác nhau trên từng nhóm tài nguyên.

Ngoài ra, production còn cần quan tâm đến quản lý token, giới hạn network, thời gian tồn tại credentials, audit log và cơ chế thu hồi quyền. Trong tutorial, yêu cầu network policy đối với PAT được nới lỏng để dễ kết nối từ máy cá nhân. Đây là đánh đổi cho môi trường thực hành, không nên mặc định áp dụng trong môi trường doanh nghiệp.

## Slide 18: DuckDB matches Snowflake

Sau khi kết nối Horizon và cấu hình external role, chúng ta kiểm tra khả năng truy vấn bằng DuckDB. Đầu tiên, DuckDB đọc bảng FACT_AQI trong Silver. Kết quả trả về 2.117 dòng, khớp với số dòng đã kiểm tra bằng Snowflake.

Khi truy vấn chi tiết, measurement ID 320 có giá trị AQI bằng 275. Measurement ID 2118 xuất hiện như mong đợi, còn measurement ID 434 đã bị loại khỏi Silver sau bước transformation. Tiếp theo, DuckDB đọc bảng AQI_CITY_RANKING trong Gold.

Kết quả về thành phố, AQI trung bình, số ngày quan sát và thứ hạng đều khớp với Snowflake. Trong ví dụ tháng 1 năm 2021, có 11 thành phố, trong đó 9 thành phố được xếp hạng và 2 thành phố không có giá trị AQI hợp lệ để xếp hạng. Các kết quả này cho thấy DuckDB có thể đọc những bảng Iceberg do Snowflake quản lý thông qua Horizon Catalog.

Hai engine sử dụng cùng metadata và cùng tập data file, thay vì phải duy trì một bản sao dữ liệu riêng cho DuckDB. Tuy nhiên, đây là kiểm chứng về khả năng đọc và tính nhất quán kết quả trong phạm vi tutorial. Nó chưa phải một bài kiểm thử toàn diện về hiệu năng, concurrent writes hoặc khả năng xử lý xung đột khi nhiều engine cùng ghi vào dữ liệu.

Sau khi xác nhận đường đọc, bước cuối cùng là kiểm tra ranh giới quyền ghi.

## Slide 19: A controlled write test proves the boundary

Ở slide trước, chúng ta đã thấy DuckDB đọc dữ liệu Iceberg thành công. Nhưng liệu DuckDB có thể ghi dữ liệu vào những bảng này hay không?

Tutorial thực hiện hai thử nghiệm để kiểm tra.

Thử nghiệm đầu tiên là ghi vào Sandbox. DuckDB thao tác với bảng SANDBOX.DUCKDB_NOTES. Script thêm ba dòng, cập nhật nội dung dòng thứ hai rồi xóa dòng thứ ba.

Kết quả cuối cùng là bảng còn hai dòng. Khi truy vấn lại từ Snowflake, chúng ta thấy đúng hai dòng này, bao gồm cả nội dung đã được cập nhật. Điều đó cho thấy DuckDB không chỉ có thể đọc, mà còn có thể ghi vào một bảng Iceberg do Snowflake quản lý khi được cấp quyền phù hợp.

Thử nghiệm thứ hai là ghi vào Silver. Trong lần này, DuckDB cố gắng thêm dữ liệu vào một bảng Silver. Tuy nhiên, request nhận lỗi HTTP 403 Forbidden.

Theo log được trình bày trong tutorial, lỗi xuất hiện ở bước tải file lên S3, trước khi thao tác commit thay đổi vào Catalog. Kết quả này phù hợp với thiết kế phân quyền: AQ_EXTERNAL được phép ghi vào Sandbox nhưng chỉ có quyền đọc trên Silver. Từ vị trí phát sinh lỗi, chúng ta có cơ sở suy luận rằng quyền storage được cấp cho thao tác trên Silver không cho phép thực hiện ghi.

Tuy nhiên, đây vẫn là suy luận từ kết quả thực nghiệm. Để xác định chính xác nguyên nhân từ chối ở cấp AWS, cần kiểm tra thêm quyền và log tương ứng. Điều mà thử nghiệm trực tiếp chứng minh là ranh giới quyền ghi đã hoạt động như mong đợi. Cùng một external engine có thể ghi thành công vào vùng được cấp quyền, nhưng không thể tùy ý sửa đổi bảng Silver.

Kết quả này thể hiện rõ nguyên tắc governance: khả năng truy cập một bảng không đồng nghĩa với việc có toàn quyền thay đổi bảng đó.

## Slide 20: Open files need governed access

Để tổng kết, chúng ta quay lại ba câu hỏi được đặt ra ở đầu bài.

Thứ nhất là Data Freshness. Openflow sử dụng CDC để đồng bộ những thay đổi từ PostgreSQL vào Bronze mà không cần liên tục sao chép lại toàn bộ dữ liệu nguồn. Nhờ WAL và Logical Replication, những thao tác INSERT, UPDATE và DELETE có thể được tiếp nhận và phản ánh vào Lakehouse.

Thứ hai là Data Quality. Write-Audit-Publish cho phép xây dựng và kiểm tra Candidate trước khi cập nhật Silver. Nếu dữ liệu mới không đáp ứng các điều kiện chất lượng quan trọng, quá trình Publish bị bỏ qua và downstream tiếp tục sử dụng phiên bản Silver đã được kiểm tra trước đó.

Thứ ba là Data Interoperability. Apache Iceberg cung cấp một Open Table Format, trong khi Horizon Catalog quản lý metadata và hỗ trợ kiểm soát quyền truy cập. Nhờ đó, Snowflake và DuckDB có thể làm việc với cùng những bảng Iceberg trên Amazon S3 mà không phải duy trì một bản sao dữ liệu riêng cho mỗi engine.

Tuy nhiên, một điểm cần nhấn mạnh là Open Lakehouse không có nghĩa dữ liệu được truy cập công khai hoặc không cần quản trị. Ngược lại, khi nhiều engine cùng sử dụng dữ liệu, những vấn đề như quyền truy cập, tính nhất quán và chất lượng dữ liệu càng trở nên quan trọng. Vì vậy, thông điệp cuối cùng của bài là:

Một Open Lakehouse không chỉ cần mở ở định dạng dữ liệu, mà còn phải được thiết kế để dữ liệu có thể được cập nhật, kiểm tra và chia sẻ một cách có kiểm soát. Cảm ơn mọi người đã lắng nghe.
