# Manga Browser — dịch truyện tranh trên màn hình (giống iTranscreen)

App iOS dịch chữ trên màn hình (Anh → Việt) và hiện bản dịch trong **cửa sổ nổi** khi bạn đọc truyện tranh trên Safari hay bất kỳ app nào.

## Cách hoạt động

```
 ┌──────────── Broadcast Extension (ReplayKit) ────────────┐
 │ quay toàn màn hình → OCR bằng Vision (cứ ~0.6 s/lần)    │
 │ → ghi danh sách dòng chữ + vị trí vào App Group         │
 └──────────────────────────┬──────────────────────────────┘
                            │ Darwin notification
 ┌──────────────────────────▼──── App chính (chạy nền nhờ PiP) ┐
 │ lọc mép màn hình + lọc chữ của chính cửa sổ nổi             │
 │ → gom dòng thành bóng thoại → chờ màn hình đứng yên          │
 │ → dịch (Google / Gemini / DeepSeek, có cache)                │
 │ → vẽ thành khung hình → cửa sổ Picture-in-Picture            │
 └─────────────────────────────────────────────────────────────┘
```

| Thư mục | Nội dung |
|---|---|
| `BroadcastExt/` | Extension quay màn hình + OCR |
| `MangaTrans/Pipeline/` | Lọc, gom bóng thoại, điều phối dịch |
| `MangaTrans/Translation/` | Bộ dịch Google miễn phí, Google Cloud, Gemini, DeepSeek, OpenRouter |
| `MangaTrans/PiP/` | Cửa sổ nổi Picture-in-Picture |
| `MangaTrans/Browser/` | Chế độ Trình duyệt (dịch trong app, không cần quay màn hình) |
| `MangaTrans/Views/` | Giao diện SwiftUI |
| `Shared/` | Code dùng chung cho app và extension |

Yêu cầu: iOS 16 trở lên.

## Build

Project Xcode được sinh từ `project.yml` bằng [XcodeGen](https://github.com/yonaskolb/XcodeGen).

### Cách 1 — Có máy Mac

```bash
brew install xcodegen
xcodegen generate
open MangaTrans.xcodeproj
```

1. Chọn target **MangaTrans** → *Signing & Capabilities* → chọn Team. Làm tương tự với target **BroadcastExt**.
2. Nếu báo trùng bundle id, đổi `APP_BUNDLE_ID` và `APP_GROUP_ID` trong `project.yml` rồi chạy lại `xcodegen generate`.
3. Cắm iPhone vào máy rồi bấm Run.

Tài khoản Apple miễn phí cũng dùng được (app hết hạn sau 7 ngày). App Group cần bật cho **cả hai** target.

### Cách 2 — Không có Mac (GitHub Actions)

Mỗi lần push, workflow `.github/workflows/ios.yml` chạy unit test rồi build file **`MangaTrans-unsigned.ipa`**. Vào tab **Actions** → chọn lần chạy → mục **Artifacts** để tải về.

Sau đó cài bằng một trong các cách dưới. App tự đọc tên App Group thật từ chữ ký, nên công cụ sideload có đổi tên group thì app vẫn chạy.

Có 2 bản:

| File | Có gì | Số App ID khi sideload bằng Apple ID miễn phí |
|---|---|---|
| `MangaTrans.ipa` | Dịch màn hình (mọi app) + Trình duyệt | 2 |
| `MangaTrans-Lite.ipa` | Chỉ Trình duyệt | 1 |

Bản mới nhất luôn có ở [Releases → latest](https://github.com/diepnt27/manga-trans/releases/tag/latest) (file `MangaTrans.ipa`), tải thẳng trên iPhone được.

#### SideStore (miễn phí, gia hạn ngay trên iPhone — khuyên dùng)

1. iPhone: đặt mật mã màn hình, cài **LocalDevVPN** từ App Store.
2. Máy tính (chỉ cần lần đầu): tải [iloader](https://github.com/nab138/iloader/releases). Windows cần thêm iTunes bản tải từ apple.com.
3. Cắm iPhone → **Tin cậy** → mở iloader, đăng nhập Apple ID (nên dùng Apple ID phụ) → **Install SideStore**.
4. iPhone: **Cài đặt → Cài đặt chung → Quản lý VPN & thiết bị** → tin cậy Apple ID; bật **Chế độ nhà phát triển** rồi khởi động lại.
5. Bật LocalDevVPN → mở SideStore, đăng nhập cùng Apple ID.
6. Tải `MangaTrans.ipa` từ Releases bằng Safari → SideStore → **My Apps** → **+** → chọn file. Nếu được hỏi về App Extensions, chọn **giữ lại** (Keep) — extension là phần quét màn hình.
7. Mỗi 7 ngày: bật LocalDevVPN → SideStore → **Refresh All**.

#### Sideloadly (Windows hoặc Mac, dùng Apple ID miễn phí)

1. Cài [Sideloadly](https://sideloadly.io). Trên Windows cần thêm iTunes và iCloud **bản tải từ web Apple** (không dùng bản Microsoft Store).
2. Cắm iPhone vào máy tính bằng cáp và bấm **Tin cậy** trên điện thoại.
3. Kéo file `MangaTrans-unsigned.ipa` vào Sideloadly, nhập Apple ID rồi bấm **Start**. Nên dùng một Apple ID phụ.
4. Trên iPhone, vào **Cài đặt → Cài đặt chung → Quản lý VPN & thiết bị** → chọn Apple ID của bạn → **Tin cậy**.
5. iOS 16 trở lên: vào **Cài đặt → Quyền riêng tư & bảo mật → Chế độ nhà phát triển** → bật, rồi khởi động lại máy.

Apple ID miễn phí: app hết hạn sau **7 ngày** và phải cài lại bằng Sideloadly (dữ liệu vẫn giữ nguyên). Mỗi Apple ID chỉ cài được tối đa 3 app sideload cùng lúc.

#### Các cách khác

- **AltStore**: tương tự Sideloadly, cũng hạn 7 ngày, nhưng tự gia hạn qua Wi-Fi khi máy tính chạy AltServer.
- **Chứng chỉ trả phí** (eSign, Scarlet, Feather…): ký trực tiếp trên điện thoại, không cần máy tính, dùng được lâu hơn. Chứng chỉ phải hỗ trợ App Groups.
- **TrollStore** (chỉ iOS 14.0 – 17.0): cài vĩnh viễn, không phải ký lại.
- **Tài khoản Apple Developer** (99$/năm) + Mac: build bằng Xcode, app dùng được 1 năm.

## Sử dụng

1. Mở app → chọn bộ dịch (vào **Cài đặt** để nhập API key Gemini/DeepSeek, bấm **Dịch thử** để kiểm tra).
2. Nhấn **Bắt đầu** → cửa sổ nổi hiện lên → chọn **Bắt đầu phát sóng** (Start Broadcast).
3. Mở trang truyện. Mỗi lần dừng cuộn, bản dịch các bóng thoại đang hiện trên màn hình sẽ xuất hiện trong cửa sổ nổi.
4. Dừng: nhấn X trên cửa sổ nổi, hoặc chạm vào thanh đỏ ở góc trên màn hình.

### Mẹo

- Trang nhiều chữ: mỗi lần hiện tối đa **2 bóng thoại** (chỉnh 1–6 ở Trang chủ hoặc Cài đặt → Cửa sổ dịch). Cuộn xuống thì app bỏ qua các bóng đã hiện và hiện tiếp các bóng bên dưới (đã dịch sẵn); không cuộn thì giữ nguyên.
- Kéo cửa sổ nổi sát mép trên/dưới màn hình. App tự lọc chữ của chính cửa sổ nổi, nhưng để ở mép thì bóng thoại không bị che.
- Nếu việc quét màn hình tự dừng sau vài giây (iOS giới hạn extension khoảng 50 MB RAM), hãy chuyển **Độ chính xác OCR** sang **Nhanh**. App cũng tự chuyển nếu phát hiện lần trước bị tắt giữa chừng.
- Dịch chậm hoặc nhảy liên tục: tăng **Chờ đứng yên**.
- Bị dịch cả thanh công cụ trình duyệt: tăng **Bỏ qua mép dưới**.

## Chế độ Trình duyệt (không cần quay màn hình)

Tab **Trình duyệt** là một trình duyệt web bên trong app, mở được mọi trang truyện. Mỗi khi bạn ngừng cuộn, app chụp vùng web đang xem, nhận dạng chữ rồi dịch. Không cần phát sóng màn hình, không có thanh đỏ, đỡ tốn pin hơn.

- Nút **khung / bóng thoại** trên thanh công cụ đổi cách hiện bản dịch:
  - **Khung dịch nổi**: khung ở trên trang, kéo phần đầu khung để di chuyển, bấm ⌃ để thu gọn.
  - **Đè lên bóng thoại**: chữ Việt hiện đúng chỗ chữ Anh, tự ẩn khi đang cuộn.
- **Nhiều tab** (tối đa 6) để đọc nhiều truyện cùng lúc: nút ô vuông có số trên thanh công cụ → chạm tab để chuyển, ✕ để đóng, **＋ Tab mới**. Mỗi tab nhớ trang và ngữ cảnh dịch riêng; app nhớ các tab cho lần sau.
- Nút **☆** lưu dấu trang, nút **📖** mở danh sách dấu trang. App nhớ trang bạn xem lần cuối.
- Nút **bong bóng chữ** bật/tắt dịch.
- Đăng nhập, cookie và quảng cáo của trình duyệt trong app tách riêng với Safari. Cửa sổ quảng cáo tự bật lên sẽ bị chặn.

## Bộ dịch

| Bộ dịch | Key | Ghi chú |
|---|---|---|
| Google (miễn phí) | Không cần | Endpoint web không chính thức, nhanh, có thể bị giới hạn nếu dùng quá nhiều |
| Google Cloud | [console.cloud.google.com](https://console.cloud.google.com/apis/library/translate.googleapis.com) | API chính thức (Basic v2), miễn phí 500.000 ký tự/tháng, cần gắn thẻ thanh toán |
| Gemini | [aistudio.google.com/apikey](https://aistudio.google.com/apikey) | Mặc định `gemini-3.6-flash`; đổi model được trong Cài đặt |
| DeepSeek | [platform.deepseek.com](https://platform.deepseek.com) | Mặc định `deepseek-v4-flash` |
| OpenRouter | [openrouter.ai/keys](https://openrouter.ai/keys) | Một key dùng nhiều model (DeepSeek, Gemini, GPT, Claude…). Mặc định `deepseek/deepseek-v4-flash` |

Bộ dịch AI nhận cả ngữ cảnh 8 câu trước để giữ cách xưng hô (ta/ngươi, anh/em…) nhất quán. API key được lưu trong UserDefaults của App Group trên máy.

## Giới hạn hiện tại

- Chỉ nhận dạng chữ tiếng Anh, chữ ngang.
- Cửa sổ nổi chỉ hiển thị bản dịch, không vẽ đè lên bóng thoại (iOS không cho app vẽ đè lên app khác).
- ReplayKit không quay được nội dung có DRM (ví dụ Netflix). Trang web truyện thì quay bình thường.
