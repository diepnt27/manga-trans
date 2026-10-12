import Foundation

enum TextNormalizer {
    private static let standaloneI = try! NSRegularExpression(pattern: "\\bi\\b")
    private static let whitespace = try! NSRegularExpression(pattern: "\\s+")

    /// Bỏ dấu, chữ thường — để so khớp văn bản OCR (OCR tiếng Anh đọc chữ Việt thường mất dấu).
    static func fold(_ text: String) -> String {
        text.folding(options: [.diacriticInsensitive, .caseInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US"))
            .lowercased()
            .replacingOccurrences(of: "đ", with: "d")
    }

    static func tokens(_ text: String) -> [String] {
        fold(text)
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
    }

    /// Khoá so sánh/cache của một bóng thoại.
    static func key(_ text: String) -> String {
        tokens(text).joined(separator: " ")
    }

    static func letterCount(_ text: String) -> Int {
        text.unicodeScalars.filter { CharacterSet.letters.contains($0) }.count
    }

    /// Dọn văn bản OCR: gộp khoảng trắng, sửa vài lỗi hay gặp.
    static func clean(_ text: String) -> String {
        let range = NSRange(text.startIndex..., in: text)
        var result = whitespace.stringByReplacingMatches(in: text, range: range, withTemplate: " ")
        result = result.replacingOccurrences(of: " | ", with: " I ")
        if result.hasPrefix("| ") { result = "I " + result.dropFirst(2) }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Văn bản đưa vào bộ dịch: chữ IN HOA của truyện được đổi sang dạng câu thường để dịch tốt hơn.
    static func translationInput(_ text: String) -> String {
        let cleaned = clean(text)
        return isMostlyUppercase(cleaned) ? sentenceCase(cleaned) : cleaned
    }

    static func isMostlyUppercase(_ text: String) -> Bool {
        let letters = text.filter(\.isLetter)
        guard letters.count >= 2 else { return false }
        let upper = letters.filter(\.isUppercase).count
        return Double(upper) / Double(letters.count) >= 0.8
    }

    static func sentenceCase(_ text: String) -> String {
        var result = ""
        var capitalizeNext = true
        for ch in text.lowercased() {
            if capitalizeNext && ch.isLetter {
                result += ch.uppercased()
                capitalizeNext = false
            } else {
                result.append(ch)
                if ch.isNumber { capitalizeNext = false }
            }
            if ".!?…".contains(ch) { capitalizeNext = true }
        }
        let range = NSRange(result.startIndex..., in: result)
        return standaloneI.stringByReplacingMatches(in: result, range: range, withTemplate: "I")
    }

    /// Tỉ lệ từ của `text` có trong `vocabulary`; `nil` nếu `text` có ít hơn `minTokens` từ.
    static func overlapRatio(_ text: String, in vocabulary: Set<String>, minTokens: Int = 1) -> Double? {
        let words = tokens(text)
        guard words.count >= minTokens, !words.isEmpty, !vocabulary.isEmpty else { return nil }
        let hits = words.filter(vocabulary.contains).count
        return Double(hits) / Double(words.count)
    }
}
