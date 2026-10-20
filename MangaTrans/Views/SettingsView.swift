import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var coordinator: TranslationCoordinator

    @AppStorage(SettingsKey.engine, store: AppGroup.defaults) private var engine: TranslatorEngine = .google
    @AppStorage(SettingsKey.geminiModel, store: AppGroup.defaults) private var geminiModel = AppSettings.defaultGeminiModel
    @AppStorage(SettingsKey.geminiFastMode, store: AppGroup.defaults) private var geminiFastMode = true
    // API key: lưu trong Keychain, không qua UserDefaults.
    @State private var geminiKey = SecretStore.value(for: SettingsKey.geminiKey)
    @State private var deepseekKey = SecretStore.value(for: SettingsKey.deepseekKey)
    @State private var googleCloudKey = SecretStore.value(for: SettingsKey.googleCloudKey)
    @State private var openRouterKey = SecretStore.value(for: SettingsKey.openRouterKey)
    @AppStorage(SettingsKey.openRouterModel, store: AppGroup.defaults) private var openRouterModel = AppSettings.defaultOpenRouterModel
    @AppStorage(SettingsKey.translationConsent, store: AppGroup.defaults) private var translationConsent = false
    @State private var showClearConfirm = false
    @State private var clearedBrowsingData = false
    @AppStorage(SettingsKey.deepseekModel, store: AppGroup.defaults) private var deepseekModel = AppSettings.defaultDeepSeekModel
    @AppStorage(SettingsKey.windowSize, store: AppGroup.defaults) private var windowSize: WindowSize = .small
    @AppStorage(SettingsKey.showOriginal, store: AppGroup.defaults) private var showOriginal = true
    @AppStorage(SettingsKey.readingZone, store: AppGroup.defaults) private var readingZone: ReadingZone = .middle
    @AppStorage(SettingsKey.maxBubbles, store: AppGroup.defaults) private var maxBubbles = 1
    @AppStorage(SettingsKey.bubbleTextOnly, store: AppGroup.defaults) private var bubbleTextOnly = true
    @AppStorage(SettingsKey.fontScale, store: AppGroup.defaults) private var fontScale = 0.8
    @AppStorage(SettingsKey.ocrAccuracy, store: AppGroup.defaults) private var ocrAccuracy: OCRAccuracy = .accurate
    @AppStorage(SettingsKey.scanInterval, store: AppGroup.defaults) private var scanInterval = 0.6
    @AppStorage(SettingsKey.stableDelay, store: AppGroup.defaults) private var stableDelay = 0.4
    @AppStorage(SettingsKey.prefetchWhileScrolling, store: AppGroup.defaults) private var prefetchWhileScrolling = false
    @AppStorage(SettingsKey.marginTop, store: AppGroup.defaults) private var marginTop = 0.05
    @AppStorage(SettingsKey.marginBottom, store: AppGroup.defaults) private var marginBottom = 0.08

    @AppStorage(BrowserModel.autoHideChromeKey) private var autoHideChrome = true
    @State private var testResult: String?
    @State private var isTesting = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Bộ dịch", selection: $engine) {
                        ForEach(TranslatorEngine.available) { Text($0.title).tag($0) }
                    }
                    Button {
                        Task {
                            isTesting = true
                            testResult = await coordinator.testTranslation()
                            isTesting = false
                        }
                    } label: {
                        HStack {
                            Text("Dịch thử")
                            if isTesting { Spacer(); ProgressView() }
                        }
                    }
                    .disabled(isTesting)
                    if let testResult {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(TranslationCoordinator.sampleText).font(.caption).foregroundStyle(.secondary)
                            Text(testResult)
                        }
                    }
                } header: {
                    Text("Bộ dịch")
                } footer: {
                    Text("Google miễn phí không cần key nhưng có thể bị chặn. Google Cloud dùng key chính thức, ổn định hơn. Gemini/DeepSeek dịch tự nhiên hơn (xưng hô theo ngữ cảnh).")
                }

                Section {
                    SecureField("API key", text: $googleCloudKey)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .onChange(of: googleCloudKey) { SecretStore.set($0, for: SettingsKey.googleCloudKey) }
                } header: {
                    Text("Google Cloud Translation")
                } footer: {
                    Text("Tạo key tại console.cloud.google.com: bật \"Cloud Translation API\" → APIs & Services → Credentials → Create API key. Miễn phí 500.000 ký tự mỗi tháng (cần gắn thẻ thanh toán).")
                }

                Section {
                    SecureField("API key", text: $geminiKey)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .onChange(of: geminiKey) { SecretStore.set($0, for: SettingsKey.geminiKey) }
                    TextField("Model", text: $geminiModel)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Toggle("Trả lời nhanh (giảm suy nghĩ)", isOn: $geminiFastMode)
                } header: {
                    Text("Gemini")
                } footer: {
                    Text("Lấy key tại aistudio.google.com/apikey. Mặc định: \(AppSettings.defaultGeminiModel).")
                }

                Section {
                    SecureField("API key", text: $deepseekKey)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .onChange(of: deepseekKey) { SecretStore.set($0, for: SettingsKey.deepseekKey) }
                    TextField("Model", text: $deepseekModel)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } header: {
                    Text("DeepSeek")
                } footer: {
                    Text("Lấy key tại platform.deepseek.com. Mặc định: \(AppSettings.defaultDeepSeekModel).")
                }

                Section {
                    SecureField("API key", text: $openRouterKey)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .onChange(of: openRouterKey) { SecretStore.set($0, for: SettingsKey.openRouterKey) }
                    TextField("Model", text: $openRouterModel)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } header: {
                    Text("OpenRouter")
                } footer: {
                    Text("Lấy key tại openrouter.ai/keys. Một key dùng được nhiều model: DeepSeek, Gemini, GPT, Claude… — xem tên model tại openrouter.ai/models (dạng hãng/tên-model). Mặc định: \(AppSettings.defaultOpenRouterModel).")
                }

                Section {
                    Toggle("Cho phép gửi chữ đi dịch", isOn: $translationConsent)
                    Button("Xoá dữ liệu duyệt web", role: .destructive) { showClearConfirm = true }
                        .confirmationDialog("Xoá cookie, bộ nhớ đệm và lịch sử đăng nhập của trình duyệt?",
                                            isPresented: $showClearConfirm, titleVisibility: .visible) {
                            Button("Xoá", role: .destructive) {
                                coordinator.tabs.clearBrowsingData()
                                clearedBrowsingData = true
                            }
                        }
                    if clearedBrowsingData {
                        Text("Đã xoá dữ liệu duyệt web.").foregroundStyle(.secondary)
                    }
                    Link("Chính sách quyền riêng tư", destination: AppLinks.privacyPolicy)
                } header: {
                    Text("Quyền riêng tư")
                } footer: {
                    Text("Chữ tiếng Anh nhận dạng được trên màn hình (không phải hình ảnh) được gửi tới bộ dịch bạn chọn để dịch. API key được lưu trong Keychain của máy. App không thu thập hay gửi dữ liệu nào khác.")
                }

                Section {
                    Picker("Cỡ cửa sổ", selection: $windowSize) {
                        ForEach(WindowSize.allCases) { Text($0.title).tag($0) }
                    }
                    Stepper("Số bóng thoại mỗi lần: \(maxBubbles)", value: $maxBubbles, in: 1...6)
                    Picker("Vùng đọc", selection: $readingZone) {
                        ForEach(ReadingZone.allCases) { Text($0.title).tag($0) }
                    }
                    Toggle("Hiện câu gốc", isOn: $showOriginal)
                    slider("Cỡ chữ", value: $fontScale, range: 0.6...1.6, step: 0.1, format: "×%.1f")
                } header: {
                    Text("Cửa sổ dịch")
                } footer: {
                    Text("Mỗi lần hiện tối đa số bóng thoại đã chọn, từ trên xuống. Cuộn xuống: bỏ qua các bóng đã hiện, hiện tiếp các bóng bên dưới (đã dịch sẵn). Không cuộn thì giữ nguyên. Vùng đọc: chỉ lấy bóng thoại trong vùng này của màn hình.")
                }

                Section {
                    Toggle("Tự ẩn thanh công cụ khi cuộn", isOn: $autoHideChrome)
                } header: {
                    Text("Trình duyệt")
                } footer: {
                    Text("Cuộn xuống để đọc: thanh công cụ và thanh tab ẩn đi. Cuộn ngược lên một chút hoặc về đầu trang để hiện lại.")
                }

                Section {
                    Picker("Độ chính xác OCR", selection: $ocrAccuracy) {
                        ForEach(OCRAccuracy.allCases) { Text($0.title).tag($0) }
                    }
                    Toggle("Chỉ dịch chữ trong bóng thoại", isOn: $bubbleTextOnly)
                    Toggle("Dịch trước khi đang cuộn", isOn: $prefetchWhileScrolling)
                    slider("Quét mỗi", value: $scanInterval, range: 0.3...2.0, step: 0.1, format: "%.1f giây")
                    slider("Chờ đứng yên", value: $stableDelay, range: 0.2...2.0, step: 0.1, format: "%.1f giây")
                    slider("Bỏ qua mép trên", value: $marginTop, range: 0...0.25, step: 0.01, format: "%.0f%%", scale: 100)
                    slider("Bỏ qua mép dưới", value: $marginBottom, range: 0...0.25, step: 0.01, format: "%.0f%%", scale: 100)
                } header: {
                    Text("Nhận dạng chữ")
                } footer: {
                    Text("\"Dịch trước khi đang cuộn\": bóng thoại được dịch sẵn lúc bạn cuộn chậm, dừng lại là hiện ngay (tốn thêm lượt gọi API cho đoạn chỉ lướt qua). Nếu việc quét màn hình tự tắt, hãy chọn OCR \"Nhanh\". \"Chờ đứng yên\": thời gian màn hình phải dừng cuộn trước khi dịch. Bỏ qua mép trên/dưới để không dịch thanh trạng thái và thanh công cụ trình duyệt.")
                }
            }
            .navigationTitle("Cài đặt")
        }
    }

    private func slider(_ title: String, value: Binding<Double>, range: ClosedRange<Double>, step: Double,
                        format: String, scale: Double = 1) -> some View {
        VStack(alignment: .leading) {
            HStack {
                Text(title)
                Spacer()
                Text(String(format: format, value.wrappedValue * scale)).foregroundStyle(.secondary)
            }
            Slider(value: value, in: range, step: step)
        }
    }
}
