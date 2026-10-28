import Foundation

/// Hàng chờ bóng thoại: mỗi lần hiện tối đa N bóng, lần lượt từ trên xuống.
/// Trang có 4 bóng, N = 2: hiện 2 bóng trên; cuộn xuống thì bỏ qua 2 bóng đã hiện, hiện tiếp 2 bóng dưới.
/// Chưa cuộn thì giữ nguyên; cuộn ngược lên đoạn đã đọc thì hiện lại đoạn đó.
struct BubbleQueue {
    /// Bóng thoại xê dịch quá mức này (tỉ lệ chiều cao màn hình) mới tính là đã cuộn — bỏ qua rung nhẹ của OCR.
    static let moveThreshold = 0.02
    static let memoryLimit = 500

    private var shown: Set<String> = []
    private var shownOrder: [String] = []
    /// Bộ từ của các bóng thoại đã hiện gần đây — nhận ra cùng bóng thoại dù OCR đọc hơi khác
    /// (thêm/bớt một chữ hiệu ứng, sai 1 từ).
    private var recentTokens: [Set<String>] = []
    /// Bóng thoại đang hiện → vị trí (tâm theo chiều dọc) lúc hiện.
    private var displayed: [String: Double] = [:]

    mutating func reset() {
        shown = []
        shownOrder = []
        recentTokens = []
        displayed = [:]
    }

    /// `blocks`: các bóng thoại đang thấy trên màn hình, theo thứ tự đọc.
    func select(_ blocks: [TextBlock], maxCount: Int) -> [TextBlock] {
        let limit = max(1, maxCount)
        if !displayed.isEmpty && !hasScrolled(blocks) {
            return blocks.filter { displayedMidY(for: $0) != nil }
        }
        let unseen = blocks.filter { !wasShown($0.key) }
        let pool = unseen.isEmpty ? blocks : unseen
        var chosen = Array(pool.prefix(limit))
        // Truyện kiểu cũ: nhiều bóng thoại nhỏ cạnh nhau trong cùng một hàng tranh được đọc liền nhau
        // → hiện luôn cùng lúc (thêm tối đa `rowCompanions` bóng), không bắt cuộn từng chút một.
        for block in pool.dropFirst(chosen.count) where chosen.count < limit + Self.rowCompanions
            && chosen.contains(where: { Self.isSameRow($0, block) }) {
            chosen.append(block)
        }
        return chosen
    }

    static let rowCompanions = 3

    /// Hai bóng thoại nằm cùng một hàng tranh: chồng nhau theo chiều dọc ít nhất 30% bóng thấp hơn.
    static func isSameRow(_ a: TextBlock, _ b: TextBlock) -> Bool {
        let overlap = min(a.rect.maxY, b.rect.maxY) - max(a.rect.minY, b.rect.minY)
        return overlap > min(a.rect.height, b.rect.height) * 0.3
    }

    /// Gọi khi các bóng thoại được đưa lên cửa sổ dịch.
    mutating func markShown(_ blocks: [TextBlock]) {
        guard !blocks.isEmpty else { return }
        displayed = Dictionary(blocks.map { ($0.key, Double($0.rect.midY)) }, uniquingKeysWith: { first, _ in first })
        for block in blocks where shown.insert(block.key).inserted {
            shownOrder.append(block.key)
            recentTokens.append(Self.tokens(block.key))
        }
        if recentTokens.count > 100 { recentTokens.removeFirst(recentTokens.count - 100) }
        if shownOrder.count > Self.memoryLimit {
            let overflow = shownOrder.count - Self.memoryLimit
            shownOrder.prefix(overflow).forEach { shown.remove($0) }
            shownOrder.removeFirst(overflow)
        }
    }

    private func hasScrolled(_ blocks: [TextBlock]) -> Bool {
        let stillVisible = blocks.compactMap { block in displayedMidY(for: block).map { (block, $0) } }
        // Các bóng đang hiện đã ra khỏi màn hình.
        guard !stillVisible.isEmpty else { return true }
        return stillVisible.contains { block, midY in
            abs(Double(block.rect.midY) - midY) > Self.moveThreshold
        }
    }

    private func displayedMidY(for block: TextBlock) -> Double? {
        if let exact = displayed[block.key] { return exact }
        let tokens = Self.tokens(block.key)
        return displayed.first { Self.isSameBubble(tokens, Self.tokens($0.key)) }?.value
    }

    private func wasShown(_ key: String) -> Bool {
        if shown.contains(key) { return true }
        let tokens = Self.tokens(key)
        return recentTokens.contains { Self.isSameBubble(tokens, $0) }
    }

    private static func tokens(_ key: String) -> Set<String> {
        Set(key.split(separator: " ").map(String.init))
    }

    /// Cùng một bóng thoại nếu ≥ 80% từ của bên ngắn hơn có trong bên kia (bên ngắn hơn có ít nhất 3 từ).
    static func isSameBubble(_ a: Set<String>, _ b: Set<String>) -> Bool {
        let shorter = min(a.count, b.count)
        guard shorter >= 3 else { return false }
        return Double(a.intersection(b).count) / Double(shorter) >= 0.8
    }
}
