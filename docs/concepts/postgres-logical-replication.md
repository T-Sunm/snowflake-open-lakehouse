# PostgreSQL Logical Replication

Oct 28, 2026 · @Dang Nha

Sau bài này bạn hiểu một thay đổi dữ liệu đi từ transaction trên PostgreSQL đến consumer như thế nào, và mỗi khái niệm (WAL, Logical Decoding, Publication, Replication Slot) đứng ở đâu trên đường đi đó.

## Replication là gì?

Trong một hệ thống dữ liệu, dữ liệu thường không chỉ cần tồn tại tại nơi nó được tạo ra. Một database có thể cần chia sẻ dữ liệu sang nơi khác để duy trì bản sao, phục vụ các workload đọc (các truy vấn chỉ đọc), cung cấp dữ liệu cho analytics hoặc đồng bộ với những hệ thống phía sau (downstream system).

**Database Replication** là cơ chế sao chép dữ liệu từ một database nguồn sang một hoặc nhiều nơi khác, đồng thời tiếp tục duy trì các bản sao đó khi dữ liệu nguồn thay đổi. Tùy vào mức dữ liệu mà hệ thống sao chép, replication có hai hướng chính:

- **Physical Replication** làm việc ở mức vật lý của database, dựa trên các block và byte để duy trì một bản sao gần với source.
- **Logical Replication** làm việc ở mức các data object và những thay đổi logic của chúng, chẳng hạn một row được thêm, cập nhật hoặc xóa.

PostgreSQL hỗ trợ cả hai. Physical Replication phù hợp khi cần một PostgreSQL standby gần với source, thường phục vụ high availability (hệ thống vẫn chạy khi một node hỏng) hoặc read replica. Logical Replication không cố tạo một bản sao vật lý giống source. Thay vào đó, nó tập trung vào những thay đổi của dữ liệu và cho phép kiểm soát chi tiết hơn dữ liệu nào được replicate.

Trong Logical Replication, phía cung cấp dữ liệu gọi là **Publisher**. Phía nhận gọi là **Subscriber** nếu đó là PostgreSQL (native logical replication), hoặc hiểu rộng hơn là **Consumer** khi phía nhận là một database, connector hoặc data platform khác.

Chỉ gửi những thay đổi mới là chưa đủ, vì target có thể chưa có dữ liệu đã tồn tại trước đó. Vì vậy Logical Replication thường bắt đầu bằng một **initial snapshot**: lấy trạng thái hiện tại của các bảng cần replicate và sao chép sang subscriber. Sau khi dữ liệu ban đầu được đồng bộ, những thay đổi tiếp theo trên Publisher được gửi liên tục sang phía nhận.

Xuyên suốt bài này, ta theo dõi một câu lệnh duy nhất trên Publisher:

```sql
UPDATE orders SET status = 'shipped' WHERE id = 42;
```

Mục tiêu là trả lời: câu lệnh này đi qua những bước nào để dòng `id = 42` ở phía nhận cũng chuyển thành `shipped`.

## Từ transaction đến logical stream

Để hiểu PostgreSQL lấy các thay đổi từ đâu, cần quay lại cách một transaction được xử lý bên trong database.

Khi `UPDATE orders ...` chạy, PostgreSQL vừa thay đổi dữ liệu của bảng, vừa tạo thông tin cần thiết để phục hồi thay đổi đó nếu hệ thống gặp sự cố. Hai phần này là hai nhánh:

- **Table Data Path**: các page chứa dữ liệu được đọc và thay đổi trong **Buffer Cache**, vùng memory PostgreSQL dùng để làm việc với table data. Page đã thay đổi chưa nhất thiết được ghi xuống disk ngay mà có thể được flush sau.
- **WAL Path**: thông tin về thay đổi được ghi vào **WAL (Write-Ahead Log)**. WAL record trước tiên được tạo trong **WAL Buffer**, sau đó được ghi vào các WAL segment nằm trong `pg_wal`.

Tên **Write-Ahead Log** đến từ một nguyên tắc: WAL tương ứng với một thay đổi phải được ghi xuống persistent storage **trước** khi data page chứa thay đổi đó được phép ghi xuống storage. Nhờ vậy, nếu database dừng đột ngột trước khi các data page được ghi hoàn chỉnh, PostgreSQL vẫn dùng WAL để phục hồi trạng thái database.

WAL vốn được tạo cho durability (dữ liệu đã commit thì không mất) và crash recovery, nhưng nó đồng thời là nguồn có thể dùng cho replication, vì mọi thay đổi của transaction đã được ghi lại ở đây. Thay vì liên tục quét các bảng để tìm row nào vừa đổi, Logical Replication chỉ cần đọc những gì đã xuất hiện trong WAL.

WAL là representation nội bộ phục vụ PostgreSQL, chưa phải một stream các thao tác dữ liệu mà consumer có thể hiểu trực tiếp. PostgreSQL dùng **Logical Decoding** để diễn giải WAL thành những thay đổi ở mức logic, chẳng hạn "row `id = 42` của bảng `orders` vừa được `UPDATE`".

Để WAL chứa đủ thông tin cho quá trình này, PostgreSQL phải chạy với `wal_level = logical`. Khi đó Logical Decoding biến các WAL record thành một **logical replication stream** để truyền ra ngoài Publisher.

## Chọn gì để gửi: Publication, Replication Identity, Replication Slot

Không phải mọi bảng và mọi thay đổi đều cần xuất hiện trong stream. PostgreSQL dùng ba khái niệm để xác định dữ liệu nào cần replicate, row nào đang được nhắc tới và consumer đã đọc stream đến đâu:

- **Publication** xác định tập các thay đổi được publish từ một bảng hoặc một nhóm bảng, và có thể giới hạn các operation như `INSERT`, `UPDATE`, `DELETE`, `TRUNCATE`. Nó không chứa bản copy của dữ liệu, chỉ đóng vai trò khoanh vùng phần dữ liệu đưa vào replication. Ví dụ: publish bảng `orders`.
- **Replication Identity** xác định cách PostgreSQL nhận diện một row khi replicate `UPDATE` hoặc `DELETE`. Trường hợp phổ biến nhất là dùng primary key. Cần thông tin này vì phía nhận phải biết row nào cần cập nhật hoặc xóa. Trong ví dụ, đó là `id = 42`.
- **Replication Slot** lưu tiến độ đọc của một consumer và ngăn PostgreSQL xóa phần WAL mà consumer vẫn còn cần. Nếu consumer mất kết nối tạm thời hoặc xử lý chậm hơn Publisher, slot cho phép nó tiếp tục từ vị trí cũ thay vì mất các thay đổi chưa đọc.

Để biểu diễn vị trí trong WAL, PostgreSQL dùng **LSN (Log Sequence Number)**, có thể hiểu như một địa chỉ trong dòng WAL liên tục. Khi consumer xử lý thêm dữ liệu, vị trí mà slot theo dõi cũng tiến dần về phía trước.

Replication Slot không phải nơi chứa bản copy của WAL và cũng không phải một bước biến đổi dữ liệu. Nó giống một ghi chú PostgreSQL giữ cho từng consumer, để biết phần WAL nào đã có thể giải phóng và phần nào vẫn phải giữ lại.

> **Lưu ý:** vì slot giữ lại WAL cho consumer, nếu consumer ngừng đọc (chết, bị xóa nhưng slot vẫn còn, hoặc chậm kéo dài) thì PostgreSQL vẫn tiếp tục giữ WAL và thư mục `pg_wal` sẽ lớn dần cho đến khi đầy disk. Slot không còn dùng nên được xóa, và nên theo dõi lượng WAL mà slot đang giữ.

## Gửi đi và nhận về: WAL Sender và phía nhận

Sau khi Logical Decoding xử lý WAL và Publication xác định những thay đổi cần gửi, **WAL Sender** là process ở phía Publisher chịu trách nhiệm truyền logical replication stream qua replication connection tới phía nhận. Trong kiến trúc PostgreSQL native, WAL Sender khởi động Logical Decoding và liên tục chuyển các thay đổi đã decode sang subscriber.

**\[FIGURE 3 — PostgreSQL Logical Replication: Publisher WAL → Target Data\]**

Cách xử lý ở phía nhận phụ thuộc vào loại consumer.

Khi cả hai phía đều là PostgreSQL, Subscriber tạo một **Subscription**. Subscription chứa thông tin để kết nối tới Publisher và xác định Publication mà nó muốn nhận. Các **apply worker** (process ở Subscriber chuyên áp dụng thay đổi) nhận logical changes rồi ánh xạ chúng vào các local table theo đúng thứ tự transaction. Trong ví dụ, apply worker cập nhật `status = 'shipped'` cho dòng `id = 42` ở bảng `orders` của subscriber.

Khi phía nhận là CDC tool hoặc data platform, nó không nhất thiết dùng PostgreSQL `SUBSCRIPTION`. Consumer có thể tự thiết lập replication connection, dùng Publication và Replication Slot trên PostgreSQL source rồi đọc logical changes để đưa vào hệ thống đích. Đây là cách các công cụ CDC (Change Data Capture) như Airbyte dùng WAL của PostgreSQL để capture các thay đổi tăng dần, thay vì đọc lại toàn bộ bảng ở mỗi lần đồng bộ.

Logical Replication tập trung vào **data changes**, không tự đồng bộ toàn bộ cấu trúc và cấu hình của database. Với PostgreSQL native logical replication, các thay đổi DDL như `CREATE TABLE`, `ALTER TABLE` hoặc thay đổi index không được replicate tự động. Schema ở phía Subscriber vì vậy cần được duy trì tương thích với dữ liệu mà Publisher gửi sang. Ví dụ: nếu thêm cột mới vào `orders` trên Publisher, bạn phải tự thêm cột đó ở Subscriber.

## Tóm tắt: đường đi của một UPDATE

Lần theo `UPDATE orders SET status = 'shipped' WHERE id = 42` từ đầu đến cuối:

1. **Transaction** chạy trên Publisher: page của `orders` được sửa trong Buffer Cache (Table Data Path).
2. Đồng thời, thay đổi được ghi vào **WAL** trước khi data page được phép ghi xuống disk (WAL Path).
3. Với `wal_level = logical`, **Logical Decoding** diễn giải WAL record thành thay đổi logic: "row này của `orders` vừa được `UPDATE`".
4. **Publication** quyết định thay đổi này có nằm trong phần được publish hay không, còn **Replication Identity** (primary key `id = 42`) cho biết đó là row nào.
5. **Replication Slot** ghi nhớ consumer đã đọc đến **LSN** nào và giữ lại phần WAL chưa đọc.
6. **WAL Sender** truyền stream qua replication connection tới phía nhận.
7. Phía nhận (Subscriber hoặc CDC tool) áp dụng thay đổi vào target, và dòng `id = 42` ở đó cũng thành `shipped`.

Cần nhớ: **WAL là nguồn thay đổi, Logical Decoding là bước dịch, Publication là bộ lọc, Replication Slot là điểm đánh dấu tiến độ** (và cũng là thứ có thể làm đầy disk nếu không được đọc).