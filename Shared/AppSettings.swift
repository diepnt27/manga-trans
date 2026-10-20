import Foundation
import CoreGraphics

enum TranslatorEngine: String, CaseIterable, Identifiable {
    case google, googleCloud, gemini, deepseek, openRouter

    var id: String { rawValue }

    /// Bản App Store (cờ biên dịch APPSTORE) bỏ Google miễn phí — endpoint web không chính thức,
    /// trái điều khoản của Google, dễ bị Apple từ chối.
    static var available: [TranslatorEngine] {
        #if APPSTORE
        return allCases.filter { $0 != .google }
        #else
        return allCases
        #endif
    }

    var title: String {
        switch self {
        case .google: return "Google (miễn phí)"
        case .googleCloud: return "Google Cloud (key)"
        case .gemini: return "Gemini"
        case .deepseek: return "DeepSeek"
        case .openRouter: return "OpenRouter"
        }
    }
}

enum WindowSize: String, CaseIterable, Identifiable {
    case small, normal, large

    var id: String { rawValue }

    var title: String {
        switch self {
        case .small: return "Nhỏ"
        case .normal: return "Vừa"
        case .large: return "Lớn"
        }
    }

    /// Kích thước khung hình (pixel) vẽ cho cửa sổ nổi.
    /// Tỉ lệ khung hình quyết định hình dạng cửa sổ Picture-in-Picture.
    var canvasSize: CGSize {
        switch self {
        case .small: return CGSize(width: 1080, height: 360)
        case .normal: return CGSize(width: 1080, height: 540)
        case .large: return CGSize(width: 1080, height: 810)
        }
    }
}

/// Vùng màn hình lấy bóng thoại để hiện trong cửa sổ dịch — giữ bản dịch ngắn, cuộn tới đâu dịch tới đó.
enum ReadingZone: String, CaseIterable, Identifiable {
    case top, middle, full

    var id: String { rawValue }

    var title: String {
        switch self {
        case .top: return "Nửa trên"
        case .middle: return "Giữa màn hình"
        case .full: return "Cả màn hình"
        }
    }

    /// Khoảng theo chiều dọc (0 = mép trên, 1 = mép dưới) mà tâm bóng thoại phải nằm trong.
    var verticalRange: ClosedRange<Double> {
        switch self {
        case .top: return 0...0.6
        case .middle: return 0.2...0.8
        case .full: return 0...1
        }
    }
}

enum OCRAccuracy: String, CaseIterable, Identifiable {
    case fast, accurate

    var id: String { rawValue }

    var title: String {
        switch self {
        case .fast: return "Nhanh (ít RAM)"
        case .accurate: return "Chính xác"
        }
    }
}

enum SettingsKey {
    static let engine = "engine"
    static let geminiKey = "geminiKey"
    static let geminiModel = "geminiModel"
    static let geminiFastMode = "geminiFastMode"
    static let deepseekKey = "deepseekKey"
    static let googleCloudKey = "googleCloudKey"
    static let deepseekModel = "deepseekModel"
    static let openRouterKey = "openRouterKey"
    static let openRouterModel = "openRouterModel"
    static let windowSize = "windowSize"
    static let showOriginal = "showOriginal"
    static let fontScale = "fontScale"
    static let scanInterval = "scanInterval"
    static let stableDelay = "stableDelay"
    static let ocrAccuracy = "ocrAccuracy"
    static let marginTop = "marginTop"
    static let marginBottom = "marginBottom"
    static let prefetchWhileScrolling = "prefetchWhileScrolling"
    static let readingZone = "readingZone"
    /// Người dùng đã đồng ý cho gửi chữ nhận dạng được tới bộ dịch (Apple yêu cầu hỏi trước).
    static let translationConsent = "translationConsent"
    static let bubbleTextOnly = "bubbleTextOnly"
    static let translationConsentAsked = "translationConsentAsked"
    static let maxBubbles = "maxBubbles"

    // Trạng thái nội bộ (extension ghi)
    static let broadcastActive = "broadcastActive"
    static let ocrInFlight = "ocrInFlight"
    static let autoSwitchedToFast = "autoSwitchedToFast"
}

struct AppSettings {
    static let defaultGeminiModel = "gemini-3.6-flash"
    static let defaultDeepSeekModel = "deepseek-v4-flash"
    static let defaultOpenRouterModel = "deepseek/deepseek-v4-flash"

    var engine: TranslatorEngine
    var geminiKey: String
    var geminiModel: String
    var geminiFastMode: Bool
    var deepseekKey: String
    var googleCloudKey: String
    var deepseekModel: String
    var openRouterKey: String
    var openRouterModel: String
    var windowSize: WindowSize
    var showOriginal: Bool
    var fontScale: Double
    /// Khoảng cách tối thiểu giữa 2 lần OCR (giây).
    var scanInterval: Double
    /// Màn hình phải đứng yên bao lâu (giây) mới bắt đầu dịch.
    var stableDelay: Double
    var ocrAccuracy: OCRAccuracy
    /// Bỏ qua chữ ở phần trên/dưới màn hình (tỉ lệ 0...1) — thanh trạng thái, thanh công cụ trình duyệt.
    var marginTop: Double
    var marginBottom: Double
    /// Dịch sẵn các bóng thoại khi đang cuộn để lúc dừng hiện ngay.
    var prefetchWhileScrolling: Bool
    var readingZone: ReadingZone
    var translationConsent: Bool
    /// Chỉ dịch chữ trong bóng thoại / khung lời dẫn, bỏ chữ hiệu ứng và watermark vẽ đè lên tranh.
    var bubbleTextOnly: Bool
    /// Số bóng thoại tối đa hiện mỗi lần.
    var maxBubbles: Int

    static let defaultValues: [String: Any] = [
        SettingsKey.engine: TranslatorEngine.google.rawValue,
        SettingsKey.geminiModel: defaultGeminiModel,
        SettingsKey.geminiFastMode: true,
        SettingsKey.deepseekModel: defaultDeepSeekModel,
        SettingsKey.openRouterModel: defaultOpenRouterModel,
        SettingsKey.windowSize: WindowSize.small.rawValue,
        SettingsKey.showOriginal: true,
        SettingsKey.fontScale: 0.8,
        SettingsKey.scanInterval: 0.6,
        SettingsKey.stableDelay: 0.4,
        SettingsKey.prefetchWhileScrolling: false,
        SettingsKey.readingZone: ReadingZone.middle.rawValue,
        SettingsKey.maxBubbles: 1,
        SettingsKey.bubbleTextOnly: true,
        SettingsKey.ocrAccuracy: OCRAccuracy.accurate.rawValue,
        SettingsKey.marginTop: 0.05,
        SettingsKey.marginBottom: 0.08,
    ]

    /// Chỉ đăng ký 1 lần: mỗi lần `register(defaults:)` iOS lại phát "cài đặt đã đổi",
    /// gọi liên tục (mỗi lần đọc cài đặt) gây vòng lặp vẽ lại cửa sổ nổi không ngừng.
    private static let registerSharedOnce: Void = AppGroup.defaults.register(defaults: defaultValues)

    static func registerDefaults(_ defaults: UserDefaults = AppGroup.defaults) {
        if defaults === AppGroup.defaults {
            _ = registerSharedOnce
        } else {
            defaults.register(defaults: defaultValues)
        }
    }

    static func load(_ d: UserDefaults = AppGroup.defaults) -> AppSettings {
        registerDefaults(d)
        func string(_ key: String) -> String {
            (d.string(forKey: key) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let geminiModel = string(SettingsKey.geminiModel)
        let deepseekModel = string(SettingsKey.deepseekModel)
        let openRouterModel = string(SettingsKey.openRouterModel)
        return AppSettings(
            engine: TranslatorEngine.available.first { $0.rawValue == string(SettingsKey.engine) }
                ?? TranslatorEngine.available[0],
            geminiKey: SecretStore.value(for: SettingsKey.geminiKey),
            geminiModel: geminiModel.isEmpty ? defaultGeminiModel : geminiModel,
            geminiFastMode: d.bool(forKey: SettingsKey.geminiFastMode),
            deepseekKey: SecretStore.value(for: SettingsKey.deepseekKey),
            googleCloudKey: SecretStore.value(for: SettingsKey.googleCloudKey),
            deepseekModel: deepseekModel.isEmpty ? defaultDeepSeekModel : deepseekModel,
            openRouterKey: SecretStore.value(for: SettingsKey.openRouterKey),
            openRouterModel: openRouterModel.isEmpty ? defaultOpenRouterModel : openRouterModel,
            windowSize: WindowSize(rawValue: string(SettingsKey.windowSize)) ?? .normal,
            showOriginal: d.bool(forKey: SettingsKey.showOriginal),
            fontScale: d.double(forKey: SettingsKey.fontScale),
            scanInterval: d.double(forKey: SettingsKey.scanInterval),
            stableDelay: d.double(forKey: SettingsKey.stableDelay),
            ocrAccuracy: OCRAccuracy(rawValue: string(SettingsKey.ocrAccuracy)) ?? .accurate,
            marginTop: d.double(forKey: SettingsKey.marginTop),
            marginBottom: d.double(forKey: SettingsKey.marginBottom),
            prefetchWhileScrolling: d.bool(forKey: SettingsKey.prefetchWhileScrolling),
            readingZone: ReadingZone(rawValue: string(SettingsKey.readingZone)) ?? .middle,
            translationConsent: d.bool(forKey: SettingsKey.translationConsent),
            bubbleTextOnly: d.bool(forKey: SettingsKey.bubbleTextOnly),
            maxBubbles: min(6, max(1, d.integer(forKey: SettingsKey.maxBubbles)))
        )
    }
}
