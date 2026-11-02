# Dàn ý giới thiệu Mục 4

Nov 2, 2026 · @Dang Nha

## Bối cảnh

Cần viết phần giới thiệu cho **Mục 4. Multi-engine access với Horizon Catalog**, dài khoảng 400 đến 600 chữ. Phần này chỉ có lý thuyết: không có lệnh, SQL hay thao tác Snowsight.

- **Vị trí:** sau mục 3 (Transformation và kiểm soát data quality), trước 4.1 Cấp quyền cho engine bên ngoài và 4.2 Đọc và ghi bằng DuckDB.
- **Người đọc đã biết:** bảng Iceberg nằm trên S3 qua External Volume, Bronze được cập nhật bằng CDC, Silver được cập nhật qua Write-Audit-Publish, Gold là các bảng tổng hợp, và khái niệm candidate, zero-copy clone. Người đọc được giả định đã biết medallion và star schema.
- **Mục tiêu:** sau phần này, người đọc hiểu vì sao engine khác Snowflake đọc được bảng Iceberg do Snowflake quản lý, catalog đóng vai trò gì, engine bên ngoài lấy quyền đọc file trên S3 bằng cách nào, và vì sao mỗi engine bên ngoài chỉ nên được cấp quyền tối thiểu.
- **Khuôn mẫu:** theo phần giới thiệu mục 3. Tiêu đề mục, rồi hình tổng quan, rồi một đoạn mở nối từ mục 3, rồi đúng một phần cấp 2 là `## Horizon Catalog và vended credentials`.
- **Bàn giao:** một file markdown, gửi lại chủ tutorial để ghép vào `docs/tutorial.md` của repo `snowflake-open-lakehouse`.

## Quy ước văn phong

Tutorial viết bằng tiếng Việt, giọng học thuật nhưng thân thiện. Các quy ước dưới đây đã được áp dụng cho mục 2 và mục 3, nên phần mới cần giữ đúng.

**Thuật ngữ và định nghĩa**

- Thuật ngữ cốt lõi giữ tiếng Anh. Lần dùng đầu tiên kèm giải nghĩa tiếng Việt trong ngoặc, ví dụ "multi-engine (nhiều engine cùng truy vấn một bảng)". Các lần sau không giải nghĩa lại.
- Định nghĩa đặt trong blockquote, dạng `> **Thuật ngữ** là …`, và đặt ngay sau câu dẫn vào khái niệm đó.
- Một khái niệm phải được định nghĩa trước khi được dùng.

**Tiêu đề**

- Tiêu đề mục và tiêu đề cấp 2 không chứa chữ Bronze, Silver, Gold và không có dấu ":".

**Câu và đoạn**

- Không dùng dấu ";" và không dùng dấu "-" làm dấu câu.
- Không để đoạn chỉ có một câu đơn lẻ loi. Mỗi câu mới cần được dẫn dắt từ câu trước.
- Tránh đại từ mơ hồ như "chúng". Gọi tên đối tượng, ví dụ "hai bảng này".
- Không dùng các từ "tin cậy", "tận mắt", "ở đây".
- Viết câu tổng quát, tránh câu chỉ đúng trong tutorial khi khái niệm có thể nói chung. Ví dụ không viết "bản làm việc trong tutorial gọi là candidate".
- Không phóng đại, không kể lịch sử của công nghệ, không viết đoạn kết luận thừa.
- Không nhắc tới phiên bản trước (v1) của tài liệu.

**Bảng**

- Nếu cần bảng, chỉ dùng bảng hai cột để vừa trang khi xuất LaTeX hoặc Docs.

**Hình**

- Chỗ đặt hình viết dạng `> **[HÌNH 18: mô tả ngắn]** (`ten\_file.svg`)`. Nội dung chữ trong hình viết bằng tiếng Anh, giống các hình đã có.

## Dàn ý chi tiết

Phần giới thiệu gồm tiêu đề, hình tổng quan, một đoạn mở và một phần cấp 2 với bốn ý. Mỗi ý dưới đây ghi nội dung cần nêu và dữ kiện đã kiểm tra kèm nguồn.

**Tiêu đề và hình**

1. Tiêu đề: `# Mục 4. Multi-engine access với Horizon Catalog`.
2. Ngay dưới tiêu đề là chỗ đặt HÌNH 18 (xem phần Hình cần có).

**Đoạn mở: nối từ mục 3 sang multi-engine**

1. Mở bằng kết quả của mục 3: Silver và Gold đã là bảng Iceberg trên S3, do Snowflake quản lý, và Silver chỉ thay đổi qua Write-Audit-Publish.
2. Nêu lý do engine khác đọc được: dữ liệu nằm ở định dạng mở (file Parquet cùng file metadata Iceberg), nên một engine hiểu Iceberg có thể đọc cùng bảng mà không cần bản sao hay pipeline export.
3. Giới thiệu thuật ngữ multi-engine (kèm gloss) và nêu mục này dùng DuckDB làm engine bên ngoài. Viết câu tổng quát, không viết như thể cách làm chỉ đúng với DuckDB. Horizon còn hỗ trợ Spark, Trino, Flink, PyIceberg và các engine khác ([Snowflake, external engine](https://docs.snowflake.com/en/user-guide/tables-iceberg-access-using-external-query-engine-snowflake-horizon)).
4. Câu chuyển sang phần cấp 2: để đọc được, engine bên ngoài cần một catalog cho biết bảng nào đang tồn tại và file nào là phiên bản hiện tại.

**Phần cấp 2****: `## Horizon Catalog và vended credentials`**

**Mạch dẫn dắt của phần này.** Phần này không liệt kê bốn khái niệm rời. Mỗi ý trả lời một câu hỏi do ý trước đặt ra, và người viết mở mỗi ý bằng câu hỏi đó (không cần viết nguyên dạng câu hỏi, chỉ cần giữ logic).

- **Câu mở của phần (động cơ).** Bảng Iceberg nằm trên S3 chưa đủ để một engine khác đọc được. Engine đó còn phải biết bảng nào đang tồn tại, file metadata hiện tại ở đâu, mình được phép đọc những gì và lấy file bằng cách nào. Phần này trả lời lần lượt bốn câu hỏi đó.
- **Ý 1 trả lời "bảng nằm ở đâu và phiên bản nào là hiện tại".** Đây là vai trò của catalog. Câu nối sang ý 2: vậy Snowflake cung cấp catalog đó cho engine bên ngoài bằng cách nào.
- **Ý 2 trả lời "engine bên ngoài nói chuyện với catalog của Snowflake bằng gì".** Đây là Horizon Catalog cùng Iceberg REST Catalog API. Câu nối sang ý 3: nhưng catalog chỉ chỉ ra vị trí file, engine còn phải chứng minh mình là ai và lấy được file trên S3.
- **Ý 3 trả lời "engine chứng minh mình là ai và lấy file bằng cách nào mà không giữ khóa cố định".** Đây là PAT và vended credentials. Câu nối sang ý 4: có cách vào rồi thì phải quyết định cho vào đến đâu.
- **Ý 4 trả lời "engine bên ngoài được phép làm gì".** Đây là nguyên tắc quyền tối thiểu, và là ý kết của phần giới thiệu. Câu cuối của phần nối sang 4.1: các nguyên tắc trên được hiện thực bằng role, user và token cụ thể.

**Gợi ý độ dài.** Câu mở và mỗi ý khoảng 2 đến 4 câu, kèm blockquote ở các thuật ngữ đã nêu trong dàn ý bên dưới.

1. **Vai trò của catalog.**
   - Blockquote định nghĩa catalog: nơi giữ danh sách bảng và, với mỗi bảng, vị trí của file metadata hiện tại. Catalog không chứa dữ liệu.
   - Nguồn: "A metadata pointer maps a table name to the location of that table's current metadata file" ([Snowflake, Iceberg tables](https://docs.snowflake.com/en/user-guide/tables-iceberg)).
   - Ý cần rút ra: khi Snowflake commit một thay đổi, catalog trỏ sang file metadata mới, nên mọi engine đọc qua catalog đều thấy cùng phiên bản.
2. **Horizon Catalog là catalog cho engine bên ngoài.**
   - Horizon Catalog có sẵn trong mọi tài khoản Snowflake và cung cấp Iceberg REST Catalog API, một chuẩn API mở của Apache Iceberg, để engine bên ngoài truy vấn bảng Iceberg do Snowflake quản lý qua một endpoint duy nhất ([Snowflake, external engine](https://docs.snowflake.com/en/user-guide/tables-iceberg-access-using-external-query-engine-snowflake-horizon), [Iceberg REST spec](https://iceberg.apache.org/rest-catalog-spec/)).
   - Engine bên ngoài đọc được bảng Iceberg v2 và v3, và ghi được vào bảng Snowflake-managed (có một số thao tác không hỗ trợ). Chỉ cần nêu ý đọc và ghi, không liệt kê các giới hạn.
   - Không đưa URL endpoint cụ thể vào phần này, URL thuộc về mục 4.1.
3. **Ba điều engine bên ngoài cần biết.** Viết thành một đoạn, không phải danh sách: catalog ở đâu (endpoint), mình là ai (token), và lấy file trên S3 bằng cách nào (vended credentials). Hai khái niệm sau cần blockquote:
   - **PAT (programmatic access token)**: chuỗi token Snowflake cấp cho một user để chương trình đăng nhập thay cho mật khẩu ([Snowflake, PAT](https://docs.snowflake.com/en/user-guide/programmatic-access-tokens)). Nhấn mạnh ai cầm chuỗi này được coi là user đó, nên phải giữ kín như mật khẩu. Ngoài PAT, Horizon còn hỗ trợ External OAuth, key pair và Workload Identity Federation, chỉ cần nhắc trong một vế câu.
   - **Vended credentials**: khóa S3 ngắn hạn mà catalog cấp cho từng bảng khi engine yêu cầu. Engine gửi header `X-Iceberg-Access-Delegation: vended-credentials` theo chuẩn Iceberg REST ([Snowflake, external engine](https://docs.snowflake.com/en/user-guide/tables-iceberg-access-using-external-query-engine-snowflake-horizon), [Iceberg OpenAPI](https://raw.githubusercontent.com/apache/iceberg/main/open-api/rest-catalog-open-api.yaml)).
   - Ý cần rút ra: engine bên ngoài không cần quyền cố định vào bucket. Quyền trên bảng vẫn do Snowflake quản lý bằng role, và Horizon chỉ cấp khóa khi role đủ quyền (chip Checks role grants và Issues S3 keys trong HÌNH 18). Có khóa rồi, engine đọc file Parquet trực tiếp trên S3 và dữ liệu không đi qua catalog (chip Reads files directly). Access token và khóa S3 đều hết hạn nhanh nên engine không giữ khóa cố định. Nếu role không đủ quyền thì Horizon từ chối và không cấp khóa (nhánh Request refused trong HÌNH 19).
   - Đặt HÌNH 19 ngay sau đoạn này.
4. **Nguyên tắc quyền tối thiểu.**
   - Câu nối từ ý 2: Horizon cho phép engine bên ngoài đọc và ghi, nhưng điều engine thực sự làm được do quyền của role quyết định, và HÌNH 18 vẽ quyền của một role dành cho engine bên ngoài. Role này chỉ được cấp quyền đọc trên Silver và Gold (khớp với nhãn Read only trong hình). Lý do: Silver chỉ được thay đổi qua Write-Audit-Publish, nên nếu cho engine bên ngoài ghi thẳng vào Silver thì dữ liệu bỏ qua bước Audit. Gold được dựng từ Silver, nên ghi vào Gold sẽ làm Gold lệch khỏi Silver.
   - Bronze không được cấp quyền nên engine bên ngoài không thấy (khớp với nhãn Not visible trong hình). Lý do: Bronze giữ dữ liệu gần nguyên như ở nguồn, gồm giá trị chưa sạch và các dòng đã bị soft delete (đã nêu ở phần giới thiệu mục 3), nên chỉ pipeline mới nên đọc trực tiếp.
   - Từ hai lý do trên rút ra nguyên tắc quyền tối thiểu: quyền được cấp theo role (ở hình là external role, role dành cho engine bên ngoài) và theo từng nhóm bảng, nên engine bên ngoài chỉ thấy phần được cấp. Kết quả: dù token bị lộ, người cầm nó không sửa được dữ liệu đã qua kiểm tra và không đụng được Bronze.
   - Blockquote định nghĩa nguyên tắc quyền tối thiểu (least privilege): mỗi role chỉ được cấp quyền cần cho việc của mình, không hơn.

**Lưu ý về nguồn**

- Trang tổng quan Iceberg của Snowflake còn câu "Third-party clients can't append to, delete from, or upsert data to Iceberg tables that use Snowflake as the catalog", trái với trang Horizon. Chủ tutorial đã ghi thành công vào bảng sandbox qua Horizon ở mục 4.2, nên dùng trang Horizon làm nguồn và không trích câu kia.

## Hình cần có

Phần giới thiệu cần 2 hình, đánh số nối tiếp HÌNH 17 của mục 3.

| Hình | File | Vị trí | Nội dung cần thể hiện |
| --- | --- | --- | --- |
| HÌNH 18: tổng quan multi-engine | `muc4_overview.svg` | Ngay dưới tiêu đề mục 4 | Ba hàng. Hàng 1: Snowflake (nhãn Internal, Owns the tables) ở trái, DuckDB (External engine, kèm hai chip Authenticates with a PAT và Reads files directly) ở phải. Hàng 2: thanh Horizon Catalog (ba chip REST API, Checks role grants, Issues S3 keys), nối với DuckDB bằng mũi tên REST call. Hàng 3: vùng Iceberg tables on S3 gồm Silver (Read only), Gold (Read only) và Bronze (nét đứt, Not visible). Snowflake nối thẳng xuống vùng bảng (Full access, Silver và Gold chỉ đổi qua Write-Audit-Publish), Horizon nối xuống vùng bảng (Only granted tables). Tiêu đề hình: External engines see only granted tables. Phụ đề: Access shown for the external role. Silver and Gold are read only, and Bronze stays hidden. |
| HÌNH 19: luồng truy cập qua vended credentials | `muc4_access_flow.svg` | Sau đoạn định nghĩa vended credentials | Dạng swimlane (mỗi bên thực hiện một làn). Tiêu đề hình: S3 keys go only to granted roles. Phụ đề: Horizon checks the role before it returns anything. Ba làn: DuckDB (dải ngang phía trên, chứa bước 1, 2 và 4), Horizon (làn nhỏ phía dưới bên trái, chứa bước 3 và thẻ Request refused) và S3 (làn nét đứt nằm dưới bước 4). Bốn bước đánh số: (1) engine đổi PAT lấy access token ngắn hạn, (2) engine yêu cầu catalog tải bảng kèm `vended-credentials`, (3) Horizon kiểm tra quyền của role rồi trả metadata và khóa S3 tạm thời về cho DuckDB, (4) DuckDB đọc file Parquet trực tiếp trên S3 bằng các khóa đó. Mũi tên nối 1 sang 2, 2 xuống 3, 3 lên 4 và 4 xuống S3. Một nhánh phụ: role không đủ quyền thì Horizon từ chối (thẻ Request refused, nét đứt màu hồng) và không cấp khóa. Thời hạn của token và khóa không vẽ trong hình mà nêu trong đoạn văn. |

**Yêu cầu chung cho hai hình**

- Giữ cùng phong cách với HÌNH 14 và 15 của mục 3: nền `#FBFAF7`, thanh màu xanh `#2F9E5B` cạnh tiêu đề, card bo góc viền đen, vùng nhóm bằng khung nét đứt, ô đặt icon 28×28 có `id`, font Figtree.
- Cùng một đối tượng dùng cùng màu ở mọi hình: Bronze `#A9CFF5`, Silver `#8EE4AF`, Gold `#F8D3A0`.
- Chữ trong hình bằng tiếng Anh, tiêu đề nêu điều người đọc cần rút ra, không chỉ nêu chủ đề.
- Không đưa số liệu, thời hạn token hay URL vào hình.
- Chủ tutorial có file SVG mẫu của HÌNH 14 và 15 để lấy thông số, liên hệ để nhận.

## Thuật ngữ cho glossary

Các thuật ngữ sau xuất hiện lần đầu trong phần giới thiệu mục 4, cần thêm vào bảng thuật ngữ hai cột của tutorial. Người viết có thể sửa cách diễn đạt, miễn giữ đúng nghĩa và khớp với blockquote trong bài.

| Thuật ngữ | Ý nghĩa |
| --- | --- |
| Multi-engine | Nhiều engine truy vấn cùng một bảng dữ liệu mà không cần bản sao. |
| Catalog | Nơi giữ danh sách bảng và vị trí file metadata hiện tại của từng bảng, không chứa dữ liệu. |
| Iceberg REST Catalog API | Chuẩn API mở của Apache Iceberg để engine làm việc với catalog qua HTTP. |
| Horizon Catalog | Catalog của Snowflake, cung cấp Iceberg REST Catalog API cho engine bên ngoài. |
| PAT (programmatic access token) | Token Snowflake cấp cho một user để chương trình đăng nhập thay cho mật khẩu. |
| Vended credentials | Khóa truy cập S3 ngắn hạn do catalog cấp cho từng bảng khi engine yêu cầu. |
| Least privilege (quyền tối thiểu) | Mỗi role chỉ được cấp quyền cần cho việc của mình, không hơn. |

## Phạm vi

Phần giới thiệu chỉ nêu khái niệm. Các nội dung sau đã có chỗ ở mục 4.1, 4.2 hoặc đã bị bỏ, nên không viết vào phần giới thiệu.

| Nội dung | Nằm ở |
| --- | --- |
| URL endpoint, tên catalog bằng tên database | 4.1 |
| Role, user, quyền cụ thể, authentication policy, network policy | 4.1 |
| Quy tắc 403 khi bảng có clone và quyền đọc cho candidate | 4.1 |
| Thời hạn token, cách tạo và lưu PAT vào `.env` | 4.1 |
| `ATTACH`, phiên bản DuckDB, `DISABLE_MULTI_TABLE_COMMIT` | 4.2 |
| Khóa S3 chỉ đọc làm lệnh ghi vào Silver bị từ chối | 4.2, và chỉ nêu như quan sát vì tài liệu Snowflake không mô tả cơ chế này |
| Lỗi `409 CommitConflict` | Đã bỏ |
| Phí gọi API của Horizon, danh sách đầy đủ engine và giới hạn | Không đưa vào tutorial |

## Tài liệu tham khảo

Các trang dưới đây đã được mở và kiểm tra ngày 2/11/2026. Trang đầu tiên là nguồn chính cho phần giới thiệu.

| Nguồn | Dùng cho |
| --- | --- |
| [Snowflake: Query Snowflake-managed Iceberg tables with an external engine through Horizon Catalog](https://docs.snowflake.com/en/user-guide/tables-iceberg-access-using-external-query-engine-snowflake-horizon) | Horizon Iceberg REST Catalog API, các cách xác thực, vended credentials, đọc và ghi từ engine bên ngoài, danh sách engine |
| [Snowflake: Apache Iceberg tables](https://docs.snowflake.com/en/user-guide/tables-iceberg) | Định nghĩa catalog và metadata pointer (lưu ý câu mâu thuẫn ở phần Dàn ý) |
| [Snowflake: Horizon Catalog](https://docs.snowflake.com/en/user-guide/snowflake-horizon) | Horizon Catalog là gì, tính mở và khả năng tương thích với engine khác |
| [Snowflake: Programmatic access tokens](https://docs.snowflake.com/en/user-guide/programmatic-access-tokens) | Định nghĩa PAT |
| [Apache Iceberg: REST Catalog Spec](https://iceberg.apache.org/rest-catalog-spec/) | Chuẩn Iceberg REST Catalog API |
| [Apache Iceberg: REST catalog OpenAPI](https://raw.githubusercontent.com/apache/iceberg/main/open-api/rest-catalog-open-api.yaml) | Header `X-Iceberg-Access-Delegation` với giá trị `vended-credentials` |
| [DuckDB: Iceberg catalogs](https://duckdb.org/docs/2.0/core_extensions/iceberg/catalogs.html) | DuckDB là một client của Iceberg REST catalog, tùy chọn `ACCESS_DELEGATION_MODE 'vended_credentials'` (chi tiết thuộc 4.2) |

**Tài liệu nội bộ của project**

- `horizon-access.md` và `duckdb-read-write.md` trong Project "Snowflake": runbook đã chạy thật, dùng để đối chiếu thiết kế quyền và luồng kết nối.
- Phần giới thiệu mục 3 (`intro-muc3.md`): bản mẫu về giọng văn, cách đặt blockquote và chỗ đặt hình. Chủ tutorial gửi kèm khi giao việc.
