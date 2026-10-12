import Foundation
import CoreGraphics

/// Lọc các dòng OCR không thuộc nội dung truyện:
/// - chữ ở mép trên/dưới (thanh trạng thái, thanh công cụ trình duyệt);
/// - chữ của chính cửa sổ nổi (ReplayKit quay luôn cả cửa sổ PiP, nếu không lọc app sẽ tự dịch lại bản dịch của mình).
struct ScreenFilter {
    var marginTop: Double = 0.05
    var marginBottom: Double = 0.08
    var minConfidence: Float = 0.3

    private(set) var pipRect: CGRect?
    private var pipRectExpiry = Date.distantPast
    private var originalVocabulary: Set<String> = []
    private var translationVocabulary: Set<String> = []

    /// Gọi mỗi khi nội dung cửa sổ nổi thay đổi.
    mutating func setDisplayed(originals: [String], translations: [String]) {
        originalVocabulary = Set(originals.flatMap(TextNormalizer.tokens))
        translationVocabulary = Set(translations.flatMap(TextNormalizer.tokens))
    }

    mutating func reset() {
        pipRect = nil
        pipRectExpiry = .distantPast
    }

    mutating func filter(_ lines: [OCRLine], now: Date = Date()) -> [OCRLine] {
        let inContent = lines.filter { line in
            let cy = line.center.y
            return cy >= marginTop && cy <= 1 - marginBottom && line.confidence >= minConfidence
        }

        // Dòng trùng bản dịch đang hiển thị = chữ của cửa sổ nổi → học vị trí cửa sổ.
        // (Bản dịch tiếng Việt không bao giờ xuất hiện trong truyện tiếng Anh.)
        let pipFlags = inContent.map { matchesTranslation($0.text, minTokens: 2) }
        let pipLines = zip(inContent, pipFlags).filter { $0.1 }.map(\.0)
        if let first = pipLines.first {
            pipRect = pipLines.dropFirst().reduce(first.rect) { $0.union($1.rect) }
            pipRectExpiry = now.addingTimeInterval(4)
        }

        let candidates = zip(inContent, pipFlags).filter { !$0.1 }.map(\.0)
        guard let core = pipRect, now < pipRectExpiry else { return candidates }

        let coreArea = core.insetBy(dx: -0.01, dy: -0.01)
        // Câu gốc hiển thị ngay trên bản dịch trong cửa sổ nổi → mở rộng vùng theo chiều dọc.
        let nearArea = core.insetBy(dx: -0.04, dy: -(core.height + 0.03))
        return candidates.filter { line in
            let c = line.center
            if coreArea.contains(c) { return false }
            if nearArea.contains(c) {
                let isOriginal = (TextNormalizer.overlapRatio(line.text, in: originalVocabulary) ?? 0) >= 0.6
                if isOriginal || matchesTranslation(line.text, minTokens: 1) { return false }
            }
            return true
        }
    }

    /// Cả bóng thoại trùng bản dịch đang hiển thị → bỏ (chặn vòng lặp tự dịch).
    func isEchoOfTranslation(_ block: TextBlock) -> Bool {
        matchesTranslation(block.displayText, minTokens: 2)
    }

    private func matchesTranslation(_ text: String, minTokens: Int) -> Bool {
        (TextNormalizer.overlapRatio(text, in: translationVocabulary, minTokens: minTokens) ?? 0) >= 0.6
    }
}
