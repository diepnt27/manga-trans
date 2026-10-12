import Foundation

struct TranslationPair: Codable, Equatable {
    let source: String
    let target: String
}

protocol Translator {
    /// Dịch nhiều bóng thoại cùng lúc; kết quả cùng số lượng, cùng thứ tự với `texts`.
    /// `context` là vài câu trước đó (đã dịch) để giữ cách xưng hô nhất quán.
    func translate(_ texts: [String], context: [TranslationPair]) async throws -> [String]
}

enum TranslatorError: LocalizedError {
    case missingAPIKey(String)
    case http(Int, String)
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .missingAPIKey(let name): return "Chưa nhập API key \(name) trong Cài đặt."
        case .http(let code, let message): return "HTTP \(code): \(message)"
        case .invalidResponse: return "Phản hồi từ bộ dịch không hợp lệ."
        }
    }
}

enum TranslatorFactory {
    static func make(_ settings: AppSettings) -> any Translator {
        switch settings.engine {
        case .google:
            return GoogleFreeTranslator()
        case .gemini:
            return GeminiTranslator(apiKey: settings.geminiKey, model: settings.geminiModel, fastMode: settings.geminiFastMode)
        case .deepseek:
            return DeepSeekTranslator(apiKey: settings.deepseekKey, model: settings.deepseekModel)
        }
    }
}

enum HTTP {
    static func postJSON(_ url: URL, body: [String: Any], headers: [String: String] = [:]) async throws -> Data {
        var request = URLRequest(url: url, timeoutInterval: 30)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        headers.forEach { request.setValue($0.value, forHTTPHeaderField: $0.key) }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return try await send(request)
    }

    static func send(_ request: URLRequest) async throws -> Data {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw TranslatorError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            throw TranslatorError.http(http.statusCode, errorMessage(from: data))
        }
        return data
    }

    static func errorMessage(from data: Data) -> String {
        if let json = try? JSONSerialization.jsonObject(with: data) {
            if let dict = json as? [String: Any] {
                if let error = dict["error"] as? [String: Any], let message = error["message"] as? String { return message }
                if let message = dict["error"] as? String { return message }
                if let message = dict["message"] as? String { return message }
            }
            if let array = json as? [[String: Any]],
               let error = array.first?["error"] as? [String: Any],
               let message = error["message"] as? String { return message }
        }
        return String(decoding: data.prefix(200), as: UTF8.self)
    }
}

/// Bộ nhớ đệm bản dịch để cuộn lại không phải dịch lại.
struct TranslationCache {
    let limit: Int
    private var store: [String: String] = [:]
    private var order: [String] = []

    init(limit: Int = 600) {
        self.limit = limit
    }

    func value(engine: TranslatorEngine, key: String) -> String? {
        store[engine.rawValue + "|" + key]
    }

    mutating func set(_ value: String, engine: TranslatorEngine, key: String) {
        let k = engine.rawValue + "|" + key
        if store.updateValue(value, forKey: k) == nil {
            order.append(k)
        }
        if order.count > limit {
            let overflow = order.count - limit
            order.prefix(overflow).forEach { store.removeValue(forKey: $0) }
            order.removeFirst(overflow)
        }
    }

    var count: Int { store.count }
}
