import Foundation

/// Google Translate qua endpoint web miễn phí (không cần key, không chính thức — có thể bị giới hạn).
struct GoogleFreeTranslator: Translator {
    var source = "en"
    var target = "vi"

    func translate(_ texts: [String], context: [TranslationPair]) async throws -> [String] {
        try await withThrowingTaskGroup(of: (Int, String).self) { group in
            for (index, text) in texts.enumerated() {
                group.addTask { (index, try await translateOne(text)) }
            }
            var results = Array(repeating: "", count: texts.count)
            for try await (index, translated) in group {
                results[index] = translated
            }
            return results
        }
    }

    private func translateOne(_ text: String) async throws -> String {
        var components = URLComponents(string: "https://translate.googleapis.com/translate_a/single")!
        components.queryItems = [
            URLQueryItem(name: "client", value: "gtx"),
            URLQueryItem(name: "sl", value: source),
            URLQueryItem(name: "tl", value: target),
            URLQueryItem(name: "dt", value: "t"),
            URLQueryItem(name: "q", value: text),
        ]
        // URLComponents không mã hoá "+", server sẽ hiểu thành dấu cách.
        components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        let request = URLRequest(url: components.url!, timeoutInterval: 15)
        return try Self.parse(try await HTTP.send(request))
    }

    /// Phản hồi dạng `[[["bản dịch","gốc",...], ...], ...]`.
    static func parse(_ data: Data) throws -> String {
        guard
            let root = try JSONSerialization.jsonObject(with: data) as? [Any],
            let segments = root.first as? [Any]
        else { throw TranslatorError.invalidResponse }
        let text = segments.compactMap { ($0 as? [Any])?.first as? String }.joined()
        guard !text.isEmpty else { throw TranslatorError.invalidResponse }
        return text
    }
}
