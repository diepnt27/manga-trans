import Foundation
import CoreGraphics

enum TranslatorEngine: String, CaseIterable, Identifiable {
    case google, gemini, deepseek

    var id: String { rawValue }

    var title: String {
        switch self {
        case .google: return "Google (miễn phí)"
        case .gemini: return "Gemini"
        case .deepseek: return "DeepSeek"
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
    static let deepseekModel = "deepseekModel"
    static let windowSize = "windowSize"
    static let showOriginal = "showOriginal"
    static let fontScale = "fontScale"
    static let scanInterval = "scanInterval"
    static let stableDelay = "stableDelay"
    static let ocrAccuracy = "ocrAccuracy"
    static let marginTop = "marginTop"
    static let marginBottom = "marginBottom"

    // Trạng thái nội bộ (extension ghi)
    static let broadcastActive = "broadcastActive"
    static let ocrInFlight = "ocrInFlight"
    static let autoSwitchedToFast = "autoSwitchedToFast"
}

struct AppSettings {
    static let defaultGeminiModel = "gemini-3.6-flash"
    static let defaultDeepSeekModel = "deepseek-v4-flash"

    var engine: TranslatorEngine
    var geminiKey: String
    var geminiModel: String
    var geminiFastMode: Bool
    var deepseekKey: String
    var deepseekModel: String
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

    static let defaultValues: [String: Any] = [
        SettingsKey.engine: TranslatorEngine.google.rawValue,
        SettingsKey.geminiModel: defaultGeminiModel,
        SettingsKey.geminiFastMode: true,
        SettingsKey.deepseekModel: defaultDeepSeekModel,
        SettingsKey.windowSize: WindowSize.normal.rawValue,
        SettingsKey.showOriginal: true,
        SettingsKey.fontScale: 1.0,
        SettingsKey.scanInterval: 0.6,
        SettingsKey.stableDelay: 0.6,
        SettingsKey.ocrAccuracy: OCRAccuracy.accurate.rawValue,
        SettingsKey.marginTop: 0.05,
        SettingsKey.marginBottom: 0.08,
    ]

    static func registerDefaults(_ defaults: UserDefaults = AppGroup.defaults) {
        defaults.register(defaults: defaultValues)
    }

    static func load(_ d: UserDefaults = AppGroup.defaults) -> AppSettings {
        registerDefaults(d)
        func string(_ key: String) -> String {
            (d.string(forKey: key) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let geminiModel = string(SettingsKey.geminiModel)
        let deepseekModel = string(SettingsKey.deepseekModel)
        return AppSettings(
            engine: TranslatorEngine(rawValue: string(SettingsKey.engine)) ?? .google,
            geminiKey: string(SettingsKey.geminiKey),
            geminiModel: geminiModel.isEmpty ? defaultGeminiModel : geminiModel,
            geminiFastMode: d.bool(forKey: SettingsKey.geminiFastMode),
            deepseekKey: string(SettingsKey.deepseekKey),
            deepseekModel: deepseekModel.isEmpty ? defaultDeepSeekModel : deepseekModel,
            windowSize: WindowSize(rawValue: string(SettingsKey.windowSize)) ?? .normal,
            showOriginal: d.bool(forKey: SettingsKey.showOriginal),
            fontScale: d.double(forKey: SettingsKey.fontScale),
            scanInterval: d.double(forKey: SettingsKey.scanInterval),
            stableDelay: d.double(forKey: SettingsKey.stableDelay),
            ocrAccuracy: OCRAccuracy(rawValue: string(SettingsKey.ocrAccuracy)) ?? .accurate,
            marginTop: d.double(forKey: SettingsKey.marginTop),
            marginBottom: d.double(forKey: SettingsKey.marginBottom)
        )
    }
}
