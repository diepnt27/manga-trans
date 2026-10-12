import Foundation
import CoreGraphics

/// Một bóng thoại (nhóm các dòng chữ gần nhau).
struct TextBlock: Equatable {
    var lines: [OCRLine]
    /// Toạ độ chuẩn hoá 0...1.
    var rect: CGRect
    /// Văn bản gốc để hiển thị.
    var displayText: String
    /// Văn bản gửi cho bộ dịch.
    var translationInput: String
    /// Khoá so sánh/cache.
    var key: String
}

/// Gom các dòng OCR thành bóng thoại và sắp xếp theo thứ tự đọc (trên → dưới, trái → phải).
enum TextGrouper {
    static func group(_ lines: [OCRLine], imageSize: CGSize) -> [TextBlock] {
        guard !lines.isEmpty else { return [] }
        let sx = imageSize.width > 0 ? imageSize.width : 1
        let sy = imageSize.height > 0 ? imageSize.height : 1
        // So sánh trong hệ toạ độ pixel để khoảng cách ngang/dọc cùng đơn vị.
        let rects = lines.map { CGRect(x: $0.x * sx, y: $0.y * sy, width: $0.w * sx, height: $0.h * sy) }

        var parent = Array(lines.indices)
        func find(_ i: Int) -> Int {
            var i = i
            while parent[i] != i {
                parent[i] = parent[parent[i]]
                i = parent[i]
            }
            return i
        }
        for i in lines.indices {
            for j in (i + 1)..<lines.count where belongTogether(rects[i], rects[j]) {
                let a = find(i), b = find(j)
                if a != b { parent[b] = a }
            }
        }

        var groups: [Int: [Int]] = [:]
        for i in lines.indices { groups[find(i), default: []].append(i) }

        let blocks = groups.values.map { indices in
            makeBlock(indices.map { lines[$0] }, pixelRects: indices.map { rects[$0] })
        }
        return sortedInReadingOrder(blocks)
    }

    static func belongTogether(_ a: CGRect, _ b: CGRect) -> Bool {
        let hMax = max(a.height, b.height)
        let hMin = min(a.height, b.height)
        // Cỡ chữ quá khác nhau → khác bóng thoại.
        guard hMin > 0, hMin / hMax > 0.45 else { return false }

        let vOverlap = min(a.maxY, b.maxY) - max(a.minY, b.minY)
        let hOverlap = min(a.maxX, b.maxX) - max(a.minX, b.minX)

        // Cùng một hàng (Vision đôi khi tách một dòng làm hai).
        if vOverlap > hMin * 0.5 {
            return hOverlap > -hMax * 1.2
        }
        let vGap = -vOverlap
        guard vGap < hMax * 0.9 else { return false }
        // Chữ trong bóng thoại thường căn giữa: chồng nhau theo chiều ngang hoặc có tâm gần nhau.
        return hOverlap > 0 || abs(a.midX - b.midX) < max(a.width, b.width) * 0.6
    }

    private static func makeBlock(_ lines: [OCRLine], pixelRects: [CGRect]) -> TextBlock {
        // Chia các dòng thành hàng, mỗi hàng đọc trái → phải.
        let ordered = zip(lines, pixelRects).sorted { $0.1.minY < $1.1.minY }
        var rows: [[(OCRLine, CGRect)]] = []
        for item in ordered {
            if let last = rows.last, let ref = last.first?.1,
               item.1.midY > ref.minY, item.1.midY < ref.maxY {
                rows[rows.count - 1].append(item)
            } else {
                rows.append([item])
            }
        }
        let rowTexts = rows.map { row in
            row.sorted { $0.1.minX < $1.1.minX }
                .map { TextNormalizer.clean($0.0.text) }
                .joined(separator: " ")
        }
        let text = joinRows(rowTexts)
        let rect = lines.map(\.rect).reduce(lines[0].rect) { $0.union($1) }
        return TextBlock(
            lines: lines,
            rect: rect,
            displayText: text,
            translationInput: TextNormalizer.translationInput(text),
            key: TextNormalizer.key(text)
        )
    }

    /// Nối các dòng, xử lý từ bị ngắt bằng gạch nối cuối dòng ("SOME-" + "THING").
    static func joinRows(_ rows: [String]) -> String {
        var result = ""
        for raw in rows {
            let row = raw.trimmingCharacters(in: .whitespaces)
            guard !row.isEmpty else { continue }
            if result.isEmpty {
                result = row
            } else if result.hasSuffix("-"), !result.hasSuffix("--"), row.first?.isLetter == true {
                result.removeLast()
                result += row
            } else {
                result += " " + row
            }
        }
        return result
    }

    private static func sortedInReadingOrder(_ blocks: [TextBlock]) -> [TextBlock] {
        let byTop = blocks.sorted { $0.rect.minY < $1.rect.minY }
        var bands: [[TextBlock]] = []
        var bandBottom: CGFloat = -1
        for block in byTop {
            if !bands.isEmpty, block.rect.minY < bandBottom {
                bands[bands.count - 1].append(block)
                bandBottom = max(bandBottom, block.rect.maxY)
            } else {
                bands.append([block])
                bandBottom = block.rect.maxY
            }
        }
        return bands.flatMap { $0.sorted { $0.rect.minX < $1.rect.minX } }
    }
}
