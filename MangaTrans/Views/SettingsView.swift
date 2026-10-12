import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var coordinator: TranslationCoordinator

    @AppStorage(SettingsKey.engine, store: AppGroup.defaults) private var engine: TranslatorEngine = .google
    @AppStorage(SettingsKey.geminiKey, store: AppGroup.defaults) private var geminiKey = ""
    @AppStorage(SettingsKey.geminiModel, store: AppGroup.defaults) private var geminiModel = AppSettings.defaultGeminiModel
    @AppStorage(SettingsKey.geminiFastMode, store: AppGroup.defaults) private var geminiFastMode = true
    @AppStorage(SettingsKey.deepseekKey, store: AppGroup.defaults) private var deepseekKey = ""
    @AppStorage(SettingsKey.deepseekModel, store: AppGroup.defaults) private var deepseekModel = AppSettings.defaultDeepSeekModel
    @AppStorage(SettingsKey.windowSize, store: AppGroup.defaults) private var windowSize: WindowSize = .normal
    @AppStorage(SettingsKey.showOriginal, store: AppGroup.defaults) private var showOriginal = true
    @AppStorage(SettingsKey.fontScale, store: AppGroup.defaults) private var fontScale = 1.0
    @AppStorage(SettingsKey.ocrAccuracy, store: AppGroup.defaults) private var ocrAccuracy: OCRAccuracy = .accurate
    @AppStorage(SettingsKey.scanInterval, store: AppGroup.defaults) private var scanInterval = 0.6
    @AppStorage(SettingsKey.stableDelay, store: AppGroup.defaults) private var stableDelay = 0.6
    @AppStorage(SettingsKey.marginTop, store: AppGroup.defaults) private var marginTop = 0.05
    @AppStorage(SettingsKey.marginBottom, store: AppGroup.defaults) private var marginBottom = 0.08

    @State private var testResult: String?
    @State private var isTesting = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Bộ dịch", selection: $engine) {
                        ForEach(TranslatorEngine.allCases) { Text($0.title).tag($0) }
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
                    Text("Google miễn phí, không cần key. Gemini/DeepSeek dịch tự nhiên hơn (xưng hô theo ngữ cảnh) nhưng cần API key.")
                }

                Section {
                    SecureField("API key", text: $geminiKey)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
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
                    TextField("Model", text: $deepseekModel)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } header: {
                    Text("DeepSeek")
                } footer: {
                    Text("Lấy key tại platform.deepseek.com. Mặc định: \(AppSettings.defaultDeepSeekModel).")
                }

                Section("Cửa sổ nổi") {
                    Picker("Cỡ cửa sổ", selection: $windowSize) {
                        ForEach(WindowSize.allCases) { Text($0.title).tag($0) }
                    }
                    Toggle("Hiện câu gốc", isOn: $showOriginal)
                    slider("Cỡ chữ", value: $fontScale, range: 0.6...1.6, step: 0.1, format: "×%.1f")
                }

                Section {
                    Picker("Độ chính xác OCR", selection: $ocrAccuracy) {
                        ForEach(OCRAccuracy.allCases) { Text($0.title).tag($0) }
                    }
                    slider("Quét mỗi", value: $scanInterval, range: 0.3...2.0, step: 0.1, format: "%.1f giây")
                    slider("Chờ đứng yên", value: $stableDelay, range: 0.2...2.0, step: 0.1, format: "%.1f giây")
                    slider("Bỏ qua mép trên", value: $marginTop, range: 0...0.25, step: 0.01, format: "%.0f%%", scale: 100)
                    slider("Bỏ qua mép dưới", value: $marginBottom, range: 0...0.25, step: 0.01, format: "%.0f%%", scale: 100)
                } header: {
                    Text("Nhận dạng chữ")
                } footer: {
                    Text("Nếu việc quét màn hình tự tắt, hãy chọn OCR \"Nhanh\". \"Chờ đứng yên\": thời gian màn hình phải dừng cuộn trước khi dịch. Bỏ qua mép trên/dưới để không dịch thanh trạng thái và thanh công cụ trình duyệt.")
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
