import Foundation

/// Chọn các bóng thoại sẽ hiện trong cửa sổ dịch: chỉ trong vùng đọc, theo thứ tự đọc, dừng khi đủ dài.
/// Trang nhiều chữ sẽ được hiện từng đoạn — cuộn tới đâu hiện tới đó (giống iTranscreen).
enum FocusSelector {
    static func select(_ blocks: [TextBlock], zone: ReadingZone, maxCharacters: Int) -> [TextBlock] {
        var selected: [TextBlock] = []
        var total = 0
        for block in blocks where zone.verticalRange.contains(Double(block.rect.midY)) {
            let length = block.displayText.count
            // Luôn lấy ít nhất 1 bóng thoại, kể cả khi nó dài.
            if !selected.isEmpty && total + length > maxCharacters { break }
            selected.append(block)
            total += length
        }
        return selected
    }
}
