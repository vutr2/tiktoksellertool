# Codex review: product creation

Ngày 2026-09-13. Review các thay đổi product creation chưa commit được nêu ở cuối `CLAUDE_HANDOFF.md`, trên nền commit `251824a`.

**Kết luận:** cần sửa các lỗi P1 dưới đây trước khi coi luồng tạo sản phẩm đã hoàn tất. Đây là kết quả review, chưa phải bản sửa implementation.

Code generation/credits và dependencies mới xuất hiện trong khi review đang chạy; chúng không nằm trong phạm vi kết luận này. Không gọi API ghi dữ liệu thật, không đọc `.env`, không dừng hay đổi cấu hình hai dev server.

## Các lỗi cần sửa

### R1 — [P1] Cache sản phẩm lộ sang tài khoản tiếp theo trên cùng thiết bị

**Vị trí:** `ios/ListingForge/Features/Capture/ProductDetailsView.swift:191`.

Luồng mới bắt đầu ghi sản phẩm thật vào `ModelContainer` dùng chung toàn app. `CachedProduct` không có owner/org; `ProductsView.swift:12` lấy toàn bộ cache; `AuthStore.signOut()` và `deleteAccount()` không xóa hoặc đổi cache. A tạo sản phẩm, đăng xuất, rồi B đăng nhập trên cùng thiết bị: B thấy sản phẩm của A. Xóa tài khoản cũng để lại bản cache đó.

Phải cô lập cache theo danh tính và xử lý đổi tài khoản; đồng thời reset state của `ProductStore`. Việc server lọc theo org không bảo vệ được truy vấn SwiftData hiện tại.

### R2 — [P1] Lưu thành công làm mất các góc ảnh phụ

**Vị trí:** `ios/ListingForge/Features/Capture/ProductDetailsView.swift:184`; `CaptureView.swift:86`.

UI ghi “Continue with 3 photos” và “3 angles captured”, nhưng request chỉ chứa `mainCutout?.pngData`. Khi server trả thành công, callback xóa cả mảng `cutouts`. Hai góc phụ không được upload hoặc ghi vào `assets` và không có cách khôi phục sau khi dữ liệu trong bộ nhớ bị giải phóng.

Lưu từng góc với định danh/thứ tự ổn định; chỉ kết thúc draft khi server xác nhận đủ các ảnh đã chọn. Nếu upload từng ảnh, retry phải tiếp tục ảnh còn thiếu thay vì tạo sản phẩm mới.

### R3 — [P1] Upload thất bại vẫn tạo sản phẩm; retry tạo bản trùng

**Vị trí:** `api/src/lib/products.ts:125`, `:143`, `:150`.

`createProduct()` insert row trước rồi mới upload và cập nhật đường dẫn. Lỗi upload hoặc cập nhật chỉ `throw`; không rollback, không trả id của sản phẩm dở dang, không có API tiếp tục hoàn tất và không có idempotency key. Client nhận lỗi và lần bấm Continue tiếp theo insert một row khác. Mất response sau khi server đã thành công cũng có nguy cơ tạo trùng.

Đã tái hiện bằng mock trong bộ nhớ: hai lần upload thất bại để lại hai row không có ảnh; lỗi ghi đường dẫn để lại một row cùng một storage object chưa liên kết. Chưa có cơ chế thực tế để “recover” row như comment trong code mô tả.

Cần thao tác tạo có thể thử lại an toàn, cùng cleanup hoặc quy trình hoàn tất bản ghi dở dang khi một bước lỗi.

### R4 — [P1] Response của sheet đã đóng có thể xóa loạt ảnh mới

**Vị trí:** `ios/ListingForge/Features/Capture/ProductDetailsView.swift:179`; `CaptureView.swift:86`.

Save chạy trong `Task` không được quản lý theo vòng đời draft. Nút Back vẫn bật và sheet vẫn kéo xuống đóng được trong khi `store.isSaving`. Kịch bản: nhấn Continue khi mạng chậm → Back → Start over/chụp sản phẩm khác → request cũ thành công. `onCreated` cũ vẫn xóa `cutouts` hiện tại và reset series của sản phẩm mới.

Khóa việc đóng/chuyển draft trong lúc save hoặc gắn operation với draft ID và chỉ cập nhật đúng draft đó. Chỉ cancel request phía client không đủ vì server có thể đã tạo sản phẩm; cần phối hợp với R3.

### R5 — [P1] Xóa tài khoản không xóa ảnh vừa được upload

**Vị trí:** `api/src/lib/products.ts:140`; đối chiếu `api/src/app/api/account/delete/route.ts:22`.

Thay đổi mới lưu ảnh trong bucket `cutouts`, nhưng luồng account deletion chỉ xóa các row `products` rồi tombstone user. Không có thao tác xóa storage object. Cascade của bảng ứng dụng không phải một lệnh xóa file qua Storage API. Vì vậy ảnh vẫn còn trong storage sau khi app thông báo xóa toàn bộ dữ liệu liên quan.

Bổ sung cleanup ảnh theo org với xử lý lỗi/retry, gồm cả object mồ côi từ R3. Đây là kiểm tra qua code; không thử xóa tài khoản thật.

### R6 — [P2] Callback lưu sản phẩm tái tạo lỗi khóa AE/AWB

**Vị trí:** `ios/ListingForge/Features/Capture/CaptureView.swift:87`.

Callback gọi `camera.series.reset()`, chỉ đổi số shot và trạng thái lock trong model. Nó không gọi `applyExposureLock(false)`, nên camera thật tiếp tục giữ exposure/white balance của sản phẩm trước trong khi UI báo unlocked. `CameraSession.resetSeries()` ở dòng 225 đã xử lý việc này nhưng bị bỏ qua.

Dùng thao tác reset của `CameraSession` và xóa preview cũ khi kết thúc draft. Hậu quả hình ảnh cần kiểm tra trên iPhone thật; sự thiếu lệnh mở khóa được xác nhận trực tiếp từ code.

### R7 — [P2] Sản phẩm trên server không được đồng bộ trở lại danh sách iOS

**Vị trí:** `ios/ListingForge/Features/Products/ProductStore.swift:60`; `ProductDetailsView.swift:192`.

`ProductStore.load()` đã có nhưng không được gọi ở đâu trong app; `ProductsView` chỉ đọc SwiftData. Cài lại app, đăng nhập trên máy khác hoặc lỗi `modelContext.save()` sẽ làm sản phẩm đã tạo trên server không xuất hiện, ngay cả khi có mạng. Việc bỏ qua lỗi cache hiện chưa có đường khôi phục bằng server sync.

Nối load/refresh vào màn hình danh sách hoặc session lifecycle, rồi upsert cache của đúng tài khoản. Việc đặt mapper trong view tự nó không phải lỗi; thiếu ownership và reconciliation mới là vấn đề cụ thể.

### R8 — [P2] Cap 4 MiB cho ảnh không phù hợp với JSON upload lên Vercel

**Vị trí:** `api/src/lib/products.ts:18`; `ios/ListingForge/Features/Products/ProductStore.swift:46`.

4.194.304 byte ảnh thành 5.592.408 byte base64, chưa tính JSON. Validator cho phép kích thước đó, trong khi [Vercel giới hạn request body của Function ở 4,5 MB](https://vercel.com/docs/functions/limitations#request-body-size), trả 413 trước khi handler xử lý. Chạy local thành công không kiểm chứng được giới hạn này.

Pipeline iOS cũng giữ kích thước ảnh gốc ở `ProductCutout.swift:128`, không giới hạn ảnh thành 1600 px như giả định trong comment backend. Cần upload trực tiếp bằng quyền upload có giới hạn hoặc giới hạn payload theo kích thước thực trên đường truyền, có UX xử lý ảnh vượt ngưỡng. Việc giảm độ phân giải phải tôn trọng yêu cầu marketplace.

### R9 — [P2] Validator chấp nhận file không phải ảnh PNG hợp lệ

**Vị trí:** `api/src/lib/products.ts:92`; `api/tests/products.test.ts:9`.

Validator chỉ kiểm tra magic bytes. Đã tái hiện: đúng 8 byte PNG signature, không có IHDR/IDAT/IEND, vẫn trả `ok: true`. Fixture hiện được gọi là “Minimal valid PNG” cũng chỉ có signature và một byte; đó không phải ảnh PNG hợp lệ. Kiểm tra này cũng không xác nhận ảnh có transparency.

Xác thực khả năng decode cùng đặc tính cần thiết cho compositing, với giới hạn kích thước ảnh. Dùng fixture ảnh thật để test trường hợp hợp lệ, truncated và opaque.

### R10 — [P2] Tách theo dấu phẩy làm thay đổi đặc điểm sản phẩm

**Vị trí:** `ios/ListingForge/Features/Capture/ProductDetailsView.swift:205`.

Ví dụ “Compatible with iPhone 14, 15, and 16” bị biến thành ba đặc điểm riêng. Text field không thông báo dấu phẩy là delimiter; việc tách còn có thể làm vượt giới hạn 10 features dù người dùng nhập ít ý. Dùng một dòng/một feature hoặc các trường nhập riêng để bảo toàn nội dung.

## Đính chính và phạm vi chưa hoàn tất

- **Có manual retry:** khi `create()` thất bại, `isSaving` được reset và sheet giữ dữ liệu; bấm Continue sẽ gửi lại. Thiếu draft bền vững và retry an toàn theo R3, không phải hoàn toàn không có retry.
- “2 of 4” trong một luồng tab + sheet là UX chưa hoàn chỉnh. Ưu tiên bảo toàn dữ liệu và danh tính trước khi thay khung wizard.
- Cả cổng 3000 và 3001 đang có listener. `ios/project.yml:31` vẫn mặc định trỏ tới **3000**; xem log 3001 không chứng minh request của app đi tới đó. Review này không đổi cổng hay dừng tiến trình nào.

## Kiểm chứng

- `npm run typecheck` và `npm test`: đạt 59 tests ở thời điểm chạy, trước các thay đổi generation/credits xuất hiện song song.
- XcodeGen + `xcodebuild ... -only-testing:ListingForgeTests`: build/test đạt trên iPhone 17 / iOS 26.5 Simulator lúc 13:31. Báo cáo: **104 test cases passed, 1 skipped**; 108 successful executions khi tính parameterized tests. Không chạy live auth UI test.
- Reproduction backend dùng Node module mocks, không kết nối Supabase: xác nhận R3 và R9, cùng phép tính kích thước R8. Script tạm: `/tmp/listingforge-product-review.mjs`.
- Các kịch bản đổi tài khoản, đóng sheet giữa request và camera thật được phân tích theo code; chưa chạy tương tác trên thiết bị thật.
- Sau lượt test, Claude nối thêm `MarketplacesView` vào `ProductDetailsView` và thay callback ở `CaptureView`. Đã đối chiếu lại: các lỗi product creation nêu trên vẫn còn, số dòng và hash bên dưới đã cập nhật. Kết quả test 13:31 không chứng nhận phần integration generation/marketplaces mới đó.

Snapshot SHA-256 rút gọn để đối chiếu khi Claude tiếp tục sửa:

| File | SHA-256 prefix |
| --- | --- |
| `ProductDetailsView.swift` | `5870089f22ea318a` |
| `CaptureView.swift` | `e63745f3c18c7f4e` |
| `ProductStore.swift` | `0f9acfb7f5ffaf51` |
| `api/src/lib/products.ts` | `3f4c297ba05e02b5` |
| `api/src/app/api/products/route.ts` | `dddd22b377548119` |
