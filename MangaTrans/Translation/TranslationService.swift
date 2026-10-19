import Foundation

/// Dịch bóng thoại, có cache và ngữ cảnh hội thoại. Dùng chung cho chế độ quay màn hình và Trình duyệt.
@MainActor
final class TranslationService {
    private var cache = TranslationCache()
    /// Ngữ cảnh hội thoại riêng cho từng truyện (mỗi tab một cuộc hội thoại) để xưng hô không lẫn giữa các truyện.
    private var contexts: [String: [TranslationPair]] = [:]
    /// Bóng thoại đang được dịch (khoá "engine|key") — lần gọi sau chờ kết quả này thay vì gọi API lần nữa.
    private var inFlight: [String: Task<String, Error>] = [:]
    private let makeTranslator: (AppSettings) -> any Translator

    init(makeTranslator: @escaping (AppSettings) -> any Translator = TranslatorFactory.make) {
        self.makeTranslator = makeTranslator
    }

    func cached(_ block: TextBlock, engine: TranslatorEngine) -> String? {
        cache.value(engine: engine, key: block.key)
    }

    /// Dịch sẵn vào cache (khi người dùng đang cuộn) để lúc dừng lại hiện ngay. Lỗi thì bỏ qua.
    func prefetch(_ blocks: [TextBlock], settings: AppSettings, conversation: String = "default") {
        let engine = settings.engine
        let missing = blocks.filter {
            cache.value(engine: engine, key: $0.key) == nil && inFlight[Self.flightKey(engine, $0.key)] == nil
        }
        guard !missing.isEmpty else { return }
        Task { _ = try? await self.translate(missing, settings: settings, conversation: conversation) }
    }

    /// Bản dịch cho mọi bóng thoại theo đúng thứ tự; chỉ gọi bộ dịch cho những bóng chưa có trong cache.
    func translate(_ blocks: [TextBlock], settings: AppSettings, conversation: String = "default") async throws -> [String] {
        guard settings.translationConsent else { throw TranslatorError.consentRequired }
        let engine = settings.engine

        var newBlocks: [TextBlock] = []
        for block in blocks where cache.value(engine: engine, key: block.key) == nil
            && inFlight[Self.flightKey(engine, block.key)] == nil
            && !newBlocks.contains(where: { $0.key == block.key }) {
            newBlocks.append(block)
        }

        if !newBlocks.isEmpty {
            let inputs = newBlocks.map(\.translationInput)
            let translator = makeTranslator(settings)
            let recentContext = Array((contexts[conversation] ?? []).suffix(8))
            // Task riêng: người gọi bị huỷ (do cuộn tiếp) thì bản dịch vẫn chạy xong và vào cache.
            let batch = Task { try await translator.translate(inputs, context: recentContext) }
            for (index, block) in newBlocks.enumerated() {
                inFlight[Self.flightKey(engine, block.key)] = Task { try await batch.value[index] }
            }
            do {
                let results = try await batch.value
                for (block, result) in zip(newBlocks, results) {
                    let translated = result.trimmingCharacters(in: .whitespacesAndNewlines)
                    cache.set(translated, engine: engine, key: block.key)
                    contexts[conversation, default: []].append(TranslationPair(source: block.translationInput, target: translated))
                    inFlight[Self.flightKey(engine, block.key)] = nil
                }
                if let count = contexts[conversation]?.count, count > 30 {
                    contexts[conversation]?.removeFirst(count - 30)
                }
            } catch {
                newBlocks.forEach { inFlight[Self.flightKey(engine, $0.key)] = nil }
                throw error
            }
        }

        var results: [String] = []
        for block in blocks {
            if let cached = cache.value(engine: engine, key: block.key) {
                results.append(cached)
            } else if let pending = inFlight[Self.flightKey(engine, block.key)] {
                results.append(try await pending.value)
            } else {
                results.append("")
            }
        }
        return results
    }

    private static func flightKey(_ engine: TranslatorEngine, _ key: String) -> String {
        engine.rawValue + "|" + key
    }
}
