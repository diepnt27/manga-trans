import Foundation

/// Dịch bóng thoại, có cache và ngữ cảnh hội thoại. Dùng chung cho chế độ quay màn hình và Trình duyệt.
@MainActor
final class TranslationService {
    private var cache = TranslationCache()
    private var context: [TranslationPair] = []

    func cached(_ block: TextBlock, engine: TranslatorEngine) -> String? {
        cache.value(engine: engine, key: block.key)
    }

    /// Bản dịch cho mọi bóng thoại theo đúng thứ tự; chỉ gọi bộ dịch cho những bóng chưa có trong cache.
    func translate(_ blocks: [TextBlock], settings: AppSettings) async throws -> [String] {
        let engine = settings.engine
        var seen = Set<String>()
        let missing = blocks.filter { cache.value(engine: engine, key: $0.key) == nil && seen.insert($0.key).inserted }
        if !missing.isEmpty {
            let inputs = missing.map(\.translationInput)
            let results = try await TranslatorFactory.make(settings).translate(inputs, context: Array(context.suffix(8)))
            for (block, result) in zip(missing, results) {
                let translated = result.trimmingCharacters(in: .whitespacesAndNewlines)
                cache.set(translated, engine: engine, key: block.key)
                context.append(TranslationPair(source: block.translationInput, target: translated))
            }
            if context.count > 30 { context.removeFirst(context.count - 30) }
        }
        return blocks.map { cache.value(engine: engine, key: $0.key) ?? "" }
    }
}
