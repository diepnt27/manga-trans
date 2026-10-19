# Checklist sẵn sàng lên App Store — Manga Browser (bản Lite)

Bản đưa lên App Store nên là **bản Lite** (chỉ Trình duyệt): không có Broadcast Extension, không dùng chế độ chạy nền,
ít rủi ro bị từ chối hơn nhiều so với bản đầy đủ.

Ký hiệu: ✅ đã làm trong code · 🟡 cần bạn làm · ⚠️ rủi ro khi duyệt

---

## 1. Bảo mật
| | Mục | Ghi chú |
|---|---|---|
| ✅ | API key lưu trong **Keychain** (`AfterFirstUnlockThisDeviceOnly`), tự chuyển key cũ từ UserDefaults sang | `Shared/SecretStore.swift` |
| ✅ | API key gửi qua **header**, không nằm trên URL | Google Cloud (`x-goog-api-key`), Gemini, DeepSeek (`Authorization`) |
| ✅ | Mọi kết nối dùng **HTTPS**, không tắt App Transport Security | |
| ✅ | Trình duyệt chỉ mở `http/https/about/data/blob`; chặn `tel:`, `itms-apps:`, `file:`, scheme lạ | `BrowserModel.isAllowedNavigation` + test |
| ✅ | Chặn cửa sổ bật lên do script tự mở (quảng cáo) | `WKUIDelegate` |
| ✅ | Xoá file chữ OCR khi dừng quét màn hình (bản đầy đủ) | `SampleHandler.broadcastFinished` |
| ✅ | Kết quả dịch hiển thị dạng chữ thường, không chạy như HTML/JS | SwiftUI `Text` |
| ✅ | Không log dữ liệu người dùng (`print`/`NSLog`) | đã rà |
| 🟡 | Giới hạn API key ở bảng điều khiển nhà cung cấp (Google: Restrict key → chỉ Cloud Translation API) | |

## 2. Quyền riêng tư (bắt buộc với App Store)
| | Mục | Ghi chú |
|---|---|---|
| ✅ | **Hỏi đồng ý** trước khi gửi chữ cho dịch vụ bên thứ ba (quy định 5.1.2(i)) | `ConsentView`, chặn ở `TranslationService` + test |
| ✅ | Bật/tắt đồng ý, **xoá dữ liệu duyệt web** trong Cài đặt → Quyền riêng tư | |
| ✅ | **Privacy Manifest** `PrivacyInfo.xcprivacy` (UserDefaults: CA92.1, 1C8F.1; Other User Content → App Functionality; không tracking) | app + extension |
| ✅ | **Chính sách quyền riêng tư**: `docs/PRIVACY.md`, có link trong app | |
| 🟡 | Điền **App Privacy** trên App Store Connect: *Data Not Collected* hoặc *Other User Content — App Functionality, Not Linked, No Tracking* (khớp manifest) | |
| 🟡 | Dán link chính sách vào ô *Privacy Policy URL* | `https://github.com/diepnt27/manga-trans/blob/main/docs/PRIVACY.md` |

## 3. Hiệu năng & pin
| | Mục | Ghi chú |
|---|---|---|
| ✅ | Hết vòng lặp vẽ lại do `register(defaults:)` phát thông báo đổi cài đặt | đăng ký 1 lần |
| ✅ | Cửa sổ nổi chỉ chạy hẹn giờ/phiên âm thanh khi đang dùng | |
| ✅ | OCR chụp ở 2x thay vì 3x, chạy nền, mỗi lúc 1 lần, không quét khi màn hình đứng yên | |
| ✅ | Dịch trước khi cuộn tắt mặc định; câu đã dịch được nhớ, không gọi API trùng | |
| ✅ | Theo dõi cuộn không tạo Task mỗi khung hình (iOS 17+) | |
| ✅ | Bộ nhớ đệm giới hạn (600 câu, 30 câu ngữ cảnh, 500 bóng thoại đã xem) | |
| 🟡 | Đo thực tế bằng Xcode Instruments (Time Profiler, Energy Log) trên máy thật trước khi nộp | |

## 4. Nội dung bản build
| | Mục | Ghi chú |
|---|---|---|
| ✅ | Icon 1024×1024, không có kênh trong suốt | `Assets.xcassets/AppIcon` |
| ✅ | `ITSAppUsesNonExemptEncryption = NO` (chỉ dùng HTTPS của hệ thống) | không phải khai báo xuất khẩu mỗi lần nộp |
| ✅ | Bản Lite bỏ `UIBackgroundModes` (không dùng nền) | workflow CI |
| ✅ | Cờ `APPSTORE` ẩn bộ dịch **Google miễn phí** (endpoint không chính thức) | `TranslatorEngine.available` |
| ✅ | Chỉ iPhone, dọc; màn hình khởi động có sẵn | |
| 🟡 | Build bằng **Xcode/SDK mới nhất Apple yêu cầu** lúc nộp (kiểm tra mục *Upcoming Requirements* trên developer.apple.com) | CI hiện dùng runner `macos-15` |

## 5. Việc cần bạn làm để nộp
1. 🟡 Đăng ký **Apple Developer Program** (99 USD/năm), cần máy Mac có Xcode (hoặc CI có chứng chỉ ký).
2. 🟡 Tạo App ID + App trên **App Store Connect**; đặt tên hiển thị (tên "Manga Browser" có thể đã có người dùng → chuẩn bị tên dự phòng).
3. 🟡 Build bản App Store từ Xcode:
   - `xcodegen generate`, mở `MangaTrans.xcodeproj`
   - Target **MangaTrans → General → Frameworks, Libraries, and Embedded Content**: xoá `BroadcastExt.appex`
   - **Build Settings → Swift Active Compilation Conditions (Release)**: thêm `APPSTORE`
   - **Info**: xoá `UIBackgroundModes`
   - Chọn Team → **Product → Archive → Distribute → App Store Connect**
4. 🟡 Ảnh chụp màn hình iPhone 6.9" (và 6.5") — dùng trang truyện **có bản quyền hoặc tự vẽ**, không dùng web truyện lậu.
5. 🟡 Mô tả, từ khoá, danh mục (Sách hoặc Tiện ích), URL hỗ trợ (trang issues GitHub là được).
6. 🟡 **Xếp hạng tuổi**: app có trình duyệt web tự do → chọn *Unrestricted Web Access* (xếp hạng 18+).
7. 🟡 **Ghi chú cho người duyệt (Review Notes)**: giải thích app dịch bóng thoại; cung cấp **API key dùng thử** (Google Cloud hoặc Gemini) và một trang truyện mẫu hợp pháp để thử. Thiếu key → người duyệt không thử được → bị từ chối (2.1).
8. 🟡 Thử qua **TestFlight** trước khi gửi duyệt.

## 6. Rủi ro khi duyệt & cách giảm
| | Quy định | Rủi ro | Cách giảm |
|---|---|---|---|
| ⚠️ | 5.2.3 – Nội dung vi phạm bản quyền | App bị coi là công cụ đọc truyện lậu | Không nhắc/hiển thị web truyện lậu trong ảnh, mô tả, dấu trang mặc định; mô tả là *trình duyệt + dịch* |
| ⚠️ | 2.1 – App hoàn chỉnh | Người duyệt không có API key | Đưa key dùng thử trong Review Notes, hoặc thêm bộ dịch không cần key (Apple Translation trên máy) |
| ⚠️ | 5.1.2(i) – Gửi dữ liệu cho AI bên thứ ba | | ✅ đã có màn hình đồng ý |
| ⚠️ | 4.2 – Chức năng tối thiểu | Bị coi là "web wrapper" | Nhấn mạnh tính năng riêng: nhận dạng chữ trên máy, dịch song ngữ, khung dịch kéo được, đè lên bóng thoại |
| ⚠️ | 2.5.4 – Chế độ nền | (chỉ bản đầy đủ) | ✅ Lite đã bỏ |

## 7. Đề xuất thêm (không bắt buộc)
- Thêm bộ dịch **Apple Translation** (dịch trên máy, miễn phí, không cần key) → người duyệt dùng được ngay và hợp quy định nhất.
- Thêm trình chặn quảng cáo (WKContentRuleList) cho trải nghiệm đọc tốt hơn.
