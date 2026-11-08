# MetalBridge

MetalBridge là một lớp tương thích dành cho iOS, được xây dựng từ đầu bằng ngôn ngữ Swift, nhằm hỗ trợ các API Metal công khai vốn chỉ có trên macOS mà không có API Metal tương ứng trên iOS. Dự án bao gồm một framework, một ứng dụng kiểm tra/thử nghiệm (inspector/lab), các bài kiểm tra (tests), công cụ tạo danh mục SDK và báo cáo mức độ bao phủ (coverage report).

Dự án này không khẳng định rằng mọi API Metal trên macOS đều có thể hoạt động trên iOS. Thay vào đó, nó triển khai các bộ chuyển đổi (adapters) thực tế khi đã có giải pháp tương đương trên iOS; đối với các tính năng chỉ được hỗ trợ một phần, nó sẽ đánh dấu là "một phần" (partial); còn với những API không có giải pháp thay thế hợp lệ trên iOS, nó sẽ đưa ra thông báo lỗi rõ ràng rằng tính năng đó không được hỗ trợ.

## Cấu trúc dự án

```text
Sources/MetalBridgeKit/Core/        Các kiểu cầu nối (bridge types) công khai và cơ chế thăm dò khả năng (capability probe)
Sources/MetalBridgeKit/Adapters/    Các bộ chuyển đổi (adapter) cho lưu trữ, định dạng, đồng bộ hóa, rào cản (barrier) và cấu trúc liên kết (topology)
Sources/MetalBridgeKit/Emulation/   Giải mã BC (BC decode), phân mảnh bề mặt (tessellation), hàng rào (fence), tài nguyên thưa thớt (sparse resources) và bộ đệm đối số (argument buffers)
Sources/MetalBridgeKit/Inventory/   Bảng kê phạm vi (coverage manifest) được ứng dụng và các bài kiểm thử sử dụng
Sources/MetalBridgeLab/             Công cụ kiểm tra (inspector) cho UIKit, thăm dò kết xuất (render probe) và các công cụ thăm dò dịch vụ
Shaders/                            Shader kiểm chứng (validation shader) theo chuẩn MSL 1.2
Tests/MetalBridgeKitTests/          Các bài kiểm thử logic và kiểm thử nhanh (smoke tests) cho Metal
Tools/metal_api_inventory.py        Công cụ quét khai báo trong SDK của macOS/iOS
Tools/metal_retarget.py             Công cụ quét và viết lại shader để chuyển đổi mục tiêu (retarget) cho tập hợp con A9
Tools/run_bc_differential.sh        Công cụ chạy kiểm thử sai biệt (differential test) cho giải mã BC (so sánh giữa GPU và bcdec)
Tools/FacadeDriver/                 Trình điều khiển giả lập (facade driver) trên macOS (build_and_run.sh)
docs/API_INVENTORY.md               Bảng kê API và các quyết định trong Giai đoạn 1
docs/COVERAGE.md                    Báo cáo về phạm vi bao phủ (coverage report) trong Giai đoạn 2
docs/COMPAT_SHADER.md               Thỏa thuận về tính tương thích của shader và các quy tắc chuyển đổi mục tiêu (retarget rules)
docs/VERIFICATION.md                Ghi chép về quá trình xây dựng (build) và kiểm chứng
```

## Giai đoạn 1: Danh mục API

Danh mục này thực hiện so sánh các header Metal công khai giữa SDK macOS 26.2 và SDK iOS 26.2 (sử dụng Xcode 26.3). Công cụ quét sẽ ghi lại các khai báo có sẵn trên macOS nhưng không có trên iOS, và ngược lại. Kết quả phân tích cho thấy có 43 dòng khai báo chỉ dành riêng cho macOS và 27 dòng khai báo theo chiều ngược lại (reverse-direction) trên mỗi bộ công cụ phát triển phần mềm (SDK), với tổng cộng 96 tệp tiêu đề (header). Nhóm khai báo ngược này chủ yếu dành riêng cho iOS, bên cạnh một số thành phần chỉ dành cho tvOS hoặc các thành phần không khả dụng trên cả hai nền tảng.

Các dòng khai báo thô này bao gồm các thuộc tính, phương thức, hằng số và các trường trong kiểu liệt kê (enum). Danh mục được tổng hợp trong [docs/API_INVENTORY.md](docs/API_INVENTORY.md) phân loại chúng thành 29 nhóm API chỉ dành cho macOS, cùng với 8 API gốc (native API) phổ biến được lớp cầu nối (bridge) sử dụng.

Khái niệm "chỉ dành cho macOS trên kiến ​​trúc ARM" (`macOS ARM-only`) không phải là một danh sách SDK cố định. Việc xác định các khai báo chỉ dành cho macOS dựa trên khả năng khả dụng trong SDK, trong khi các tính năng đặc thù của Apple Silicon lại là thuộc tính của "họ GPU" (GPU-family) tại thời điểm thực thi (runtime). Lớp cầu nối sẽ tự động phát hiện các họ GPU Apple trên iOS tại thời điểm thực thi và đảm bảo không bao giờ báo cáo họ GPU `Mac2` (vốn thuộc về macOS) trên nền tảng iOS.

## Giai đoạn 2: Lớp tương thích (Compatibility layer)

Cơ chế thực thi gốc (native path) sử dụng trực tiếp các API Metal công khai của iOS. Các bộ chuyển đổi (adapter) bao gồm:

- Ánh xạ bộ nhớ được quản lý (managed storage) sang bộ nhớ chia sẻ (shared storage).
- Các thao tác `didModifyRange` và đồng bộ hóa blit được thiết lập thành "không thực hiện gì cả" (no-op) trong trường hợp bộ nhớ chia sẻ trên iOS đã đảm bảo tính nhất quán (coherent).
- Định dạng `Depth24 stencil8` được ánh xạ sang `depth32Float stencil8`.
- Các rào cản (barrier) đối với mục tiêu kết xuất (render-target) được ánh xạ thành rào cản ở phạm vi kết cấu (texture-scope barrier) trên iOS 16 trở lên; đối với các phiên bản iOS cũ hơn, cơ chế này có những hạn chế cụ thể.
- Các giá trị cấu trúc liên kết (topology) được thiết lập cho một thiết bị duy nhất (phù hợp với nền tảng chỉ có một GPU).
- Các thông báo lỗi rõ ràng cho những trường hợp không được hỗ trợ, bao gồm: cắm/rút thiết bị (hot-plug), chia sẻ tài nguyên giữa các GPU, bộ nhớ phân tán (sparse heaps), các tập tính năng (feature sets) chỉ có trên macOS, và lỗi khi thiết bị bị loại bỏ (device-removal).

Bảng kê khai phạm vi hỗ trợ bao gồm 37 mục: 8 API gốc phổ biến, 12 API đã được chuyển đổi, 6 API được hỗ trợ một phần và 11 API không được hỗ trợ. `PlatformLimitationAdapter` cung cấp thông tin về các tập tính năng macOS, bộ nhớ phân tán và lỗi loại bỏ thiết bị dưới dạng các kết quả "không được hỗ trợ" rõ ràng, phục vụ cho các thành phần cần truy vấn trực tiếp thông tin này. ## Chuyển đổi mục tiêu shader (Shader retargeting)

Các shader được viết dựa trên MSL (Metal Shading Language) phiên bản Metal 2/3/4 sẽ được chuyển đổi sang tập con MSL 1.2 tương thích với chip A9 thông qua công cụ `Tools/metal_retarget.py`. Công cụ này sẽ thông báo về các cấu trúc không được hỗ trợ (như ray tracing, mesh shader, các thao tác nguyên tử 64-bit, function constant, và các cấu trúc argument-buffer) đồng thời tự động sửa đổi các trường hợp hợp lệ. Cụ thể, các thuộc tính thuộc nhóm `[[threads_per_grid]]` sẽ được chuyển sang các vị trí bộ đệm (buffer slot) dành riêng (từ 29 đến 31), vì trong chuỗi công cụ này, thuộc tính đó trả về lưới phân phối (dispatch grid) đã được đệm (padded). Chi tiết đầy đủ về quy ước này có tại [docs/COMPAT_SHADER.md](docs/COMPAT_SHADER.md).

```sh
python3 Tools/metal_retarget.py Sources/MyGame/Shaders --strict
```

Tập ​​con shader dành riêng cho cầu nối (bridge) này cũng được kiểm soát theo cách tương tự: các shader đi kèm dự án khi chạy với tùy chọn `--strict` sẽ không phát hiện bất kỳ lỗi hay cảnh báo nào.

## Xây dựng (Build)

Yêu cầu:

- Xcode 26.3 / iOS SDK 26.2.
- XcodeGen 2.46 trở lên.
- iOS deployment target: 12.0.
- Thiết bị kiến ​​trúc arm64 hỗ trợ Metal, sử dụng chip A9 trở lên.

Tạo dự án:

```sh
xcodegen generate
```

Xây dựng phiên bản Debug:

```sh
xcodebuild -project MetalBridge.xcodeproj\
-target MetalBridgeLab\
-configuration Debug\
-sdk iphoneos\
-arch arm64\
CODE_SIGNING_ALLOWED=NO \
build
```

Xây dựng phiên bản Release:

```sh
xcodebuild -project MetalBridge.xcodeproj\
-target MetalBridgeLab\
-configuration Release\
-sdk iphoneos\
-arch arm64\
CODE_SIGNING_ALLOWED=NO \
build
```

Xây dựng gói kiểm thử (test bundle):

```sh
xcodebuild -project MetalBridge.xcodeproj\
-target MetalBridgeKitTests \
-configuration Debug \
-sdk iphoneos \
-arch arm64 \
CODE_SIGNING_ALLOWED=NO \
build
```

Mục tiêu (target) của ứng dụng vẫn là iOS 12.0. Mục tiêu kiểm thử (test target) sử dụng iOS 13.0 vì framework XCTest đi kèm với bộ công cụ (toolchain) này yêu cầu phiên bản đó.

Mã nguồn chính được viết bằng Swift. Thành phần duy nhất không phải Swift là shader sử dụng ngôn ngữ Metal Shading Language (MSL). Không có cầu nối (bridge) nào sử dụng C, C++ hoặc Objective-C++.

Quá trình biên dịch shader sử dụng tham số `MTL_COMPILER_FLAGS=-std=ios-metal1.2`, và tệp `Shaders/Probe.metal` chứa một khẳng định tại thời điểm biên dịch (compile-time assertion) để từ chối các phiên bản MSL mới hơn.

## Chạy ứng dụng

Mở `MetalBridge.xcodeproj`, chọn lược đồ (scheme) dùng chung `MetalBridgeLab` (không phải lược đồ framework `MetalBridgeKit`), chọn nhóm phát triển (development team), rồi chạy ứng dụng trên thiết bị sử dụng chip A9 trở lên, chạy hệ điều hành iOS 12.0 trở lên. Nếu Xcode yêu cầu chọn đích chạy (run destination), hãy chọn thiết bị vật lý thay vì trình mô phỏng (simulator). Ứng dụng sẽ hiển thị:

- Thông tin về thiết bị và dòng GPU (GPU-family) hiện tại.
- Một công cụ kiểm tra kết xuất (render probe) giúp biên dịch tệp `metallib` đi kèm và kết xuất một hình tam giác ngoài màn hình (offscreen triangle).
- Danh sách các bản ghi tương thích, bao gồm trạng thái, phương thức triển khai và các hạn chế đi kèm.

Hình tam giác này chỉ là một ví dụ để xác thực đường ống kết xuất (pipeline validation). Hãy nhấn **Run Probe** để thực thi; quá trình kiểm tra này không tự động chạy khi khởi động ứng dụng. Framework và tệp kê khai phạm vi (coverage manifest) chính là lớp tương thích được cung cấp.

## Tạo lại danh mục (inventory)

```sh
python3 Tools/metal_api_inventory.py
```

Lệnh này sẽ tạo ra các tệp `docs/generated/metal_api_inventory.json` và `.csv`. Các quyết định chính thức về danh mục nằm trong tệp `docs/API_INVENTORY.md`, chứ không phải trong dữ liệu quét thô. ## Trạng thái xác minh

Được xác minh vào ngày 22/10/2026 với Xcode 26.3 (17C529) và iOS SDK 26.2:

- Các bản dựng ứng dụng (app build) ở chế độ Debug và Release đều thành công cho kiến ​​trúc `arm64-apple-ios12.0`.
- Mục tiêu kiểm thử (test target) đã được biên dịch thành công.
- Gói ứng dụng (app bundle) chứa tệp `default.metallib` với các thành phần `probe_vertex` và `probe_fragment`.
- Lệnh biên dịch shader bao gồm tham số `-std=ios-metal1.2`.
- Tệp thực thi và framework nhúng đều thuộc kiến ​​trúc arm64.
- Tệp `Info.plist` xác định `MinimumOSVersion=12.0`, định danh gói (bundle ID) là `dev.metalbridge.lab`, cùng với các thiết lập `UILaunchScreen` và `UIRequiresFullScreen`.

Chưa xác minh:

- Chưa thực hiện kiểm tra khi chạy ứng dụng (runtime), kết quả render probe, thao tác cử chỉ, hiệu năng hoặc các vấn đề liên quan đến nhiệt độ thiết bị.
- Chưa chạy trên phần cứng A9. Không có môi trường iOS Simulator nào được cài đặt trên máy chủ thực hiện xác minh.
- Chưa cài đặt trên thiết bị thực (yêu cầu chữ ký số).
- Gói kiểm thử chỉ mới được biên dịch, chưa được thực thi.

Xem tóm tắt nhật ký lệnh tại [docs/VERIFICATION.md](docs/VERIFICATION.md).

## Các hạn chế

- Lớp tương thích (compatibility layer) này không thay thế hoàn toàn cho môi trường runtime Metal trên macOS.
- Các API không có phiên bản tương đương trên iOS sẽ không được hỗ trợ và không bao giờ được báo cáo là thành công.
- Các cấu hình như đa GPU (multi-GPU), cắm nóng thiết bị (hot-plug), ánh xạ tài nguyên giữa các GPU (peer-GPU resource aliasing), bộ nhớ được quản lý (managed storage) và các bộ tính năng (feature sets) đặc thù của macOS không thể tái lập chính xác trên iOS.
- Ứng dụng không có danh mục tài nguyên (asset catalog) hay biểu tượng tùy chỉnh.
- Cơ chế render probe sử dụng lệnh chặn `waitUntilCompleted` chỉ với mục đích xác thực một lần duy nhất; đây không phải là vòng lặp khung hình (frame loop) của trình kết xuất (renderer).

## Tính độc lập

Đây là một bản triển khai hoàn toàn mới với tên sản phẩm, định danh gói, cấu trúc mã nguồn, danh mục tài nguyên và tài liệu riêng biệt. Dự án này không tái sử dụng mã nguồn, tài nguyên, cấu hình hay tên gọi từ bất kỳ dự án trình kết xuất nào trước đây.