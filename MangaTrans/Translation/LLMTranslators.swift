import Foundation

/// Prompt dùng chung cho các bộ dịch AI.
enum MangaPrompt {
    static let system = """
    You translate English comic / manga / manhwa / webtoon speech bubbles into Vietnamese.

    Input is JSON: {"context": [{"source": ..., "target": ...}], "lines": [...]}.
    - "lines" are the bubbles currently on screen, in reading order. Translate every one of them.
    - "context" holds earlier bubbles with their accepted translations. Use it only to stay consistent \
    (names, pronouns, tone); do not translate it again.

    Rules:
    - The text comes from OCR: silently fix obvious OCR mistakes and ignore stray symbols. Text may be ALL CAPS.
    - Write natural, concise spoken Vietnamese, as in professionally translated Vietnamese comics.
    - Pick pronouns (tôi/cậu, ta/ngươi, anh/em, tao/mày, ông/cháu...) that fit the relationship and tone, \
    and keep them consistent with the context. Martial-arts / historical settings usually use ta/ngươi, huynh/đệ, tiền bối.
    - Keep personal names as they are. Translate sound effects briefly.
    - Return ONLY a JSON object: {"translations": ["...", ...]} with exactly one item per line, in the same order.
    """

    static func userMessage(_ texts: [String], context: [TranslationPair]) -> String {
        struct Payload: Encodable {
            let context: [TranslationPair]
            let lines: [String]
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        let data = (try? encoder.encode(Payload(context: context, lines: texts))) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    static func parse(_ content: String, expected: Int) throws -> [String] {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        var json = trimmed
        if let start = json.firstIndex(of: "{"), let end = json.lastIndex(of: "}"), start < end {
            json = String(json[start...end])
        }
        struct Response: Decodable { let translations: [String] }
        guard let response = try? JSONDecoder().decode(Response.self, from: Data(json.utf8)) else {
            // Mô hình trả lời văn bản thường thay vì JSON — vẫn dùng được khi chỉ có 1 câu.
            if expected == 1, !trimmed.isEmpty, !trimmed.contains("{") { return [trimmed] }
            throw TranslatorError.invalidResponse
        }
        let items = response.translations
        if items.count == expected { return items }
        if expected == 1 { return [items.joined(separator: " ")] }
        if items.count > expected { return Array(items.prefix(expected)) }
        return items + Array(repeating: "(?)", count: expected - items.count)
    }
}

struct GeminiTranslator: Translator {
    let apiKey: String
    let model: String
    /// Giảm "suy nghĩ" của mô hình để trả lời nhanh hơn.
    let fastMode: Bool

    func translate(_ texts: [String], context: [TranslationPair]) async throws -> [String] {
        guard !apiKey.isEmpty else { throw TranslatorError.missingAPIKey("Gemini") }
        guard !texts.isEmpty else { return [] }
        do {
            return try await request(texts, context: context, limitThinking: fastMode)
        } catch TranslatorError.http(let code, _) where code == 400 && fastMode {
            // Mô hình không hỗ trợ thinkingConfig → thử lại không có nó.
            return try await request(texts, context: context, limitThinking: false)
        }
    }

    private func request(_ texts: [String], context: [TranslationPair], limitThinking: Bool) async throws -> [String] {
        var modelName = model
        if modelName.hasPrefix("models/") { modelName.removeFirst("models/".count) }
        guard let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(modelName):generateContent") else {
            throw TranslatorError.invalidResponse
        }
        var generationConfig: [String: Any] = ["responseMimeType": "application/json"]
        if limitThinking {
            generationConfig["thinkingConfig"] = ["thinkingLevel": "minimal"]
        }
        let body: [String: Any] = [
            "systemInstruction": ["parts": [["text": MangaPrompt.system]]],
            "contents": [["role": "user", "parts": [["text": MangaPrompt.userMessage(texts, context: context)]]]],
            "generationConfig": generationConfig,
        ]
        let data = try await HTTP.postJSON(url, body: body, headers: ["x-goog-api-key": apiKey])
        return try MangaPrompt.parse(try Self.extractText(data), expected: texts.count)
    }

    static func extractText(_ data: Data) throws -> String {
        struct Response: Decodable {
            struct Candidate: Decodable {
                struct Content: Decodable {
                    struct Part: Decodable {
                        let text: String?
                        let thought: Bool?
                    }
                    let parts: [Part]?
                }
                let content: Content?
            }
            let candidates: [Candidate]?
        }
        let response = try JSONDecoder().decode(Response.self, from: data)
        let text = (response.candidates?.first?.content?.parts ?? [])
            .filter { $0.thought != true }
            .compactMap(\.text)
            .joined()
        guard !text.isEmpty else { throw TranslatorError.invalidResponse }
        return text
    }
}

/// DeepSeek dùng API tương thích OpenAI.
struct DeepSeekTranslator: Translator {
    let apiKey: String
    let model: String

    func translate(_ texts: [String], context: [TranslationPair]) async throws -> [String] {
        guard !apiKey.isEmpty else { throw TranslatorError.missingAPIKey("DeepSeek") }
        guard !texts.isEmpty else { return [] }
        let body: [String: Any] = [
            "model": model,
            "messages": [
                ["role": "system", "content": MangaPrompt.system],
                ["role": "user", "content": MangaPrompt.userMessage(texts, context: context)],
            ],
            "response_format": ["type": "json_object"],
            "temperature": 1.3,
            "stream": false,
        ]
        let data = try await HTTP.postJSON(
            URL(string: "https://api.deepseek.com/chat/completions")!,
            body: body,
            headers: ["Authorization": "Bearer \(apiKey)"]
        )
        return try MangaPrompt.parse(try Self.extractText(data), expected: texts.count)
    }

    static func extractText(_ data: Data) throws -> String {
        struct Response: Decodable {
            struct Choice: Decodable {
                struct Message: Decodable { let content: String? }
                let message: Message
            }
            let choices: [Choice]
        }
        let response = try JSONDecoder().decode(Response.self, from: data)
        guard let text = response.choices.first?.message.content, !text.isEmpty else {
            throw TranslatorError.invalidResponse
        }
        return text
    }
}
