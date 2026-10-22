import Foundation

/// Dịch bóng thoại, có cache và ngữ cảnh hội thoại. Dùng chung cho chế độ quay màn hình và Trình duyệt.
@MainActor
final class TranslationService {
    private var cache = TranslationCache(limit: 2000)
    /// Các câu đã dịch theo bộ từ — nhận ra cùng bóng thoại khi OCR lúc đọc hơi khác lúc dịch trước cả chương.
    private var library: [LibraryEntry] = []
    /// Ngữ cảnh hội thoại riêng cho từng truyện (mỗi tab một cuộc hội thoại) để xưng hô không lẫn giữa các truyện.
    private var contexts: [String: [TranslationPair]] = [:]
    /// Bóng thoại đang được dịch (khoá "engine|key") — lần gọi sau chờ kết quả này thay vì gọi API lần nữa.
    private var inFlight: [String: Task<String, Error>] = [:]
    private let makeTranslator: (AppSettings) -> any Translator

    private struct LibraryEntry {
        let engine: TranslatorEngine
        let words: [String]
        let wordSet: Set<String>
        let translation: String
    }

    private static let libraryLimit = 1500

    init(makeTranslator: @escaping (AppSettings) -> any Translator = TranslatorFactory.make) {
        self.makeTranslator = makeTranslator
    }

    /// Bản dịch đã có: đúng khoá, hoặc câu gần giống đã dịch trước đó (OCR đọc khác vài từ).
    func cached(_ block: TextBlock, engine: TranslatorEngine) -> String? {
        if let exact = cache.value(engine: engine, key: block.key) { return exact }
        guard let match = libraryMatch(Self.words(block.key), engine: engine) else { return nil }
        cache.set(match, engine: engine, key: block.key)
        return match
    }

    /// Tìm câu đã dịch giống câu trên màn hình nhất (OCR mỗi lần đọc sai vài chữ cái khác nhau).
    /// Không thấy thì thử ghép 2 câu liền nhau — lúc dịch trước cả chương, một bóng thoại có thể bị tách làm hai.
    private func libraryMatch(_ words: [String], engine: TranslatorEngine) -> String? {
        guard words.count >= 3 else { return nil }
        let wordSet = Set(words)
        var best: (score: Double, text: String)?
        var previous: LibraryEntry?
        for entry in library where entry.engine == engine {
            defer { previous = entry }
            // Lọc nhanh: phải có ít nhất 1/4 số từ trùng khớp tuyệt đối.
            guard wordSet.intersection(entry.wordSet).count * 4 >= words.count else { continue }
            if let score = Self.matchScore(words, entry.words), score > (best?.score ?? 0) {
                best = (score, entry.translation)
            }
            if let previous, let score = Self.matchScore(words, previous.words + entry.words),
               score > (best?.score ?? 0) + 0.05 {
                best = (score, previous.translation + " " + entry.translation)
            }
        }
        return best?.text
    }

    /// Dịch sẵn vào cache (khi người dùng đang cuộn) để lúc dừng lại hiện ngay. Lỗi thì bỏ qua.
    func prefetch(_ blocks: [TextBlock], settings: AppSettings, conversation: String = "default") {
        let engine = settings.engine
        let missing = blocks.filter {
            cached($0, engine: engine) == nil && inFlight[Self.flightKey(engine, $0.key)] == nil
        }
        guard !missing.isEmpty else { return }
        Task { _ = try? await self.translate(missing, settings: settings, conversation: conversation) }
    }

    /// Bản dịch cho mọi bóng thoại theo đúng thứ tự; chỉ gọi bộ dịch cho những bóng chưa có trong cache.
    func translate(_ blocks: [TextBlock], settings: AppSettings, conversation: String = "default") async throws -> [String] {
        guard settings.translationConsent else { throw TranslatorError.consentRequired }
        let engine = settings.engine

        var newBlocks: [TextBlock] = []
        for block in blocks where cached(block, engine: engine) == nil
            && inFlight[Self.flightKey(engine, block.key)] == nil
            && !newBlocks.contains(where: { $0.key == block.key }) {
            newBlocks.append(block)
        }

        if !newBlocks.isEmpty {
            let inputs = newBlocks.map(\.translationInput)
            let translator = makeTranslator(settings)
            let recentContext = Array((contexts[conversation] ?? []).suffix(8))
            // Task riêng: người gọi bị huỷ (do cuộn tiếp) thì bản dịch vẫn chạy xong và vào cache.
            let batch = Task { try await Self.request(inputs, with: translator, context: recentContext) }
            for (index, block) in newBlocks.enumerated() {
                inFlight[Self.flightKey(engine, block.key)] = Task { try await batch.value[index] }
            }
            do {
                let results = try await batch.value
                store(newBlocks, results, engine: engine, conversation: conversation)
                newBlocks.forEach { inFlight[Self.flightKey(engine, $0.key)] = nil }
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

    /// Dịch trước cả chương: bóng thoại chưa có bản dịch được gửi theo lô lớn (mỗi lô `chapterBatchSize` câu)
    /// — một lần gửi prompt cho hàng chục câu thay vì mỗi câu một lần. Kết quả vào cache, cuộn tới đâu hiện ngay tới đó.
    /// Không chặn việc dịch bóng thoại đang xem: trùng vài câu còn hơn bắt người đọc chờ cả lô.
    /// Trả về số bóng thoại vừa dịch.
    @discardableResult
    func translateChapter(_ blocks: [TextBlock], settings: AppSettings, conversation: String) async throws -> Int {
        guard settings.translationConsent else { throw TranslatorError.consentRequired }
        let engine = settings.engine
        guard let batchSize = engine.chapterBatchSize else { return 0 }

        var seen = Set<String>()
        let missing = blocks.filter {
            cached($0, engine: engine) == nil && inFlight[Self.flightKey(engine, $0.key)] == nil && seen.insert($0.key).inserted
        }
        let translator = makeTranslator(settings)
        var translated = 0
        for start in stride(from: 0, to: missing.count, by: batchSize) {
            try Task.checkCancellation()
            // Bóng thoại người đọc vừa tới có thể đã được dịch trong lúc chờ lô trước.
            let chunk = missing[start..<min(start + batchSize, missing.count)].filter {
                cached($0, engine: engine) == nil && inFlight[Self.flightKey(engine, $0.key)] == nil
            }
            guard !chunk.isEmpty else { continue }
            let context = Array((contexts[conversation] ?? []).suffix(8))
            let results = try await Self.request(chunk.map(\.translationInput), with: translator, context: context)
            // Bản đang hiện (dịch lúc người đọc dừng lại) giữ nguyên, không thay chữ dưới mắt người đọc.
            let fresh = zip(chunk, results).filter { cache.value(engine: engine, key: $0.0.key) == nil }
            store(fresh.map(\.0), fresh.map(\.1), engine: engine, conversation: conversation)
            translated += fresh.count
        }
        return translated
    }

    private func store(_ blocks: [TextBlock], _ results: [String], engine: TranslatorEngine, conversation: String) {
        for (block, result) in zip(blocks, results) {
            let translated = result.trimmingCharacters(in: .whitespacesAndNewlines)
            cache.set(translated, engine: engine, key: block.key)
            let words = Self.words(block.key)
            library.append(LibraryEntry(engine: engine, words: words, wordSet: Set(words), translation: translated))
            contexts[conversation, default: []].append(TranslationPair(source: block.translationInput, target: translated))
        }
        if library.count > Self.libraryLimit { library.removeFirst(library.count - Self.libraryLimit) }
        if let count = contexts[conversation]?.count, count > 30 {
            contexts[conversation]?.removeFirst(count - 30)
        }
    }

    /// Gửi một lô; bộ dịch trả lệch số câu thì chia đôi gửi lại (tối đa 3 lần chia).
    private static func request(_ inputs: [String], with translator: any Translator, context: [TranslationPair],
                                depth: Int = 0) async throws -> [String] {
        do {
            return try await translator.translate(inputs, context: context)
        } catch TranslatorError.invalidResponse where inputs.count > 2 && depth < 3 {
            let middle = inputs.count / 2
            let first = try await request(Array(inputs[..<middle]), with: translator, context: context, depth: depth + 1)
            let second = try await request(Array(inputs[middle...]), with: translator, context: context, depth: depth + 1)
            return first + second
        }
    }

    /// Mức giống nhau (0...1) nếu là cùng một bóng thoại dù OCR đọc khác vài chữ, `nil` nếu khác câu.
    /// `a`: câu đang cần dịch, `b`: câu đã dịch. Câu dưới 3 từ phải khớp đúng khoá (dễ nhầm giữa các câu ngắn).
    nonisolated static func matchScore(_ a: [String], _ b: [String]) -> Double? {
        guard a.count >= 3, b.count >= 3 else { return nil }
        let common = Double(fuzzyCommonCount(a, b))
        let score = common / Double(max(a.count, b.count))
        // Câu ngắn chỉ khác 1 từ có thể là câu khác hẳn ("kill you" / "save you") → đòi khớp gần hết.
        // Câu dài (≥ 8 từ) gần như không trùng ngẫu nhiên → cho phép OCR sai nhiều hơn.
        let threshold = min(a.count, b.count) >= 8 ? 0.65 : 0.85
        if score >= threshold { return score }
        // Bóng thoại bị mép màn hình cắt mất một phần: gần như mọi từ thấy được đều có trong câu đã dịch.
        if a.count >= 4, common / Double(a.count) >= 0.85, Double(a.count) / Double(b.count) >= 0.5 {
            return score
        }
        return nil
    }

    nonisolated static func isSameText(_ a: [String], _ b: [String]) -> Bool {
        matchScore(a, b) != nil
    }

    /// Số từ của `a` khớp với một từ (chưa dùng) của `b`; từ dài cho phép sai 1–2 chữ cái.
    private nonisolated static func fuzzyCommonCount(_ a: [String], _ b: [String]) -> Int {
        var unused = b
        var count = 0
        for word in a {
            if let index = unused.firstIndex(of: word) ?? unused.firstIndex(where: { similarWords(word, $0) }) {
                unused.remove(at: index)
                count += 1
            }
        }
        return count
    }

    private nonisolated static func similarWords(_ a: String, _ b: String) -> Bool {
        let shorter = min(a.count, b.count)
        guard shorter >= 4, abs(a.count - b.count) <= 2 else { return false }
        return editDistance(Array(a), Array(b), limit: shorter >= 7 ? 2 : 1)
    }

    /// Khoảng cách sửa (Levenshtein) có nằm trong `limit` không.
    private nonisolated static func editDistance(_ a: [Character], _ b: [Character], limit: Int) -> Bool {
        var previous = Array(0...b.count)
        for i in 1...a.count {
            var current = [i] + Array(repeating: 0, count: b.count)
            for j in 1...b.count {
                current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1))
            }
            if current.min() ?? 0 > limit { return false }
            previous = current
        }
        return previous[b.count] <= limit
    }

    private nonisolated static func words(_ key: String) -> [String] {
        key.split(separator: " ").map(String.init)
    }

    private static func flightKey(_ engine: TranslatorEngine, _ key: String) -> String {
        engine.rawValue + "|" + key
    }
}
