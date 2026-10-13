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
    /// Bóng thoại đang hiện → vị trí (tâm theo chiều dọc) lúc hiện.
    private var displayed: [String: Double] = [:]

    mutating func reset() {
        shown = []
        shownOrder = []
        displayed = [:]
    }

    /// `blocks`: các bóng thoại đang thấy trên màn hình, theo thứ tự đọc.
    func select(_ blocks: [TextBlock], maxCount: Int) -> [TextBlock] {
        let limit = max(1, maxCount)
        if !displayed.isEmpty && !hasScrolled(blocks) {
            return blocks.filter { displayed[$0.key] != nil }
        }
        let unseen = blocks.filter { !shown.contains($0.key) }
        return Array((unseen.isEmpty ? blocks : unseen).prefix(limit))
    }

    /// Gọi khi các bóng thoại được đưa lên cửa sổ dịch.
    mutating func markShown(_ blocks: [TextBlock]) {
        guard !blocks.isEmpty else { return }
        displayed = Dictionary(blocks.map { ($0.key, Double($0.rect.midY)) }, uniquingKeysWith: { first, _ in first })
        for block in blocks where shown.insert(block.key).inserted {
            shownOrder.append(block.key)
        }
        if shownOrder.count > Self.memoryLimit {
            let overflow = shownOrder.count - Self.memoryLimit
            shownOrder.prefix(overflow).forEach { shown.remove($0) }
            shownOrder.removeFirst(overflow)
        }
    }

    private func hasScrolled(_ blocks: [TextBlock]) -> Bool {
        let stillVisible = blocks.filter { displayed[$0.key] != nil }
        // Các bóng đang hiện đã ra khỏi màn hình.
        guard !stillVisible.isEmpty else { return true }
        return stillVisible.contains { block in
            abs(Double(block.rect.midY) - (displayed[block.key] ?? 0)) > Self.moveThreshold
        }
    }
}
