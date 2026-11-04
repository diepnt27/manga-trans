import Foundation
import CoreGraphics

/// Tìm lòng bóng thoại / khung lời dẫn chứa từng dòng chữ: loang màu nền từ khoảng trống quanh dòng chữ
/// (như công cụ đổ màu), viền bóng thoại và chữ là chỗ dừng.
/// - Các dòng cùng một vùng là cùng một bóng thoại, kể cả dòng dài chạm sát viền bóng hình bầu dục.
/// - Hai bóng thoại đặt sát nhau có viền ngăn cách thì không bị gộp.
/// - Chữ hiệu ứng vẽ thẳng lên tranh: nền lổn nhổn, loang không thành vùng → không thuộc bóng thoại nào.
struct BubbleSegmenter {
    struct Region {
        /// Khung bao của vùng, toạ độ chuẩn hoá 0...1.
        let rect: CGRect
        let isBubble: Bool
    }

    private let image: LuminanceImage
    /// Nhãn vùng của từng điểm ảnh (0 = chưa loang).
    private var labels: [Int32]
    private(set) var regions: [Region] = []

    /// Hai điểm cùng vùng nếu độ sáng chênh lệch với điểm bắt đầu không quá mức này.
    private static let tolerance = 30
    /// Vùng lớn hơn tỉ lệ này của ảnh là nền trang / bầu trời, không phải bóng thoại.
    private static let maxAreaFraction = 0.3

    init(image: LuminanceImage) {
        self.image = image
        labels = [Int32](repeating: 0, count: image.width * image.height)
    }

    /// Mã bóng thoại của từng dòng (`nil`: không nằm trong bóng thoại / khung chữ nào rõ ràng)
    /// và khung lòng bóng thoại (chuẩn hoá) theo mã.
    mutating func assign(_ lines: [OCRLine]) -> (ids: [Int?], rects: [Int: CGRect]) {
        let w = Double(image.width), h = Double(image.height)
        let pixelRects = lines.map { CGRect(x: $0.x * w, y: $0.y * h, width: $0.w * w, height: $0.h * h) }

        // Dòng dài chạm cả hai bên viền chia lòng bóng làm hai vùng (trên / dưới dòng):
        // khoảng trống ngay trên và ngay dưới một dòng thuộc 2 vùng → nối 2 vùng thành một bóng.
        var parent: [Int] = []
        func find(_ i: Int) -> Int {
            var i = i
            while parent[i] != i {
                parent[i] = parent[parent[i]]
                i = parent[i]
            }
            return i
        }
        func union(_ a: Int, _ b: Int) {
            let ra = find(a), rb = find(b)
            if ra != rb { parent[rb] = ra }
        }

        func bubbleRegions(_ points: [(Int, Int)]) -> [Int] {
            var found: [Int] = []
            for point in points {
                if let id = region(at: point), regions[id].isBubble { found.append(id) }
            }
            return found
        }

        var candidates: [[Int]] = []
        for rect in pixelRects {
            let (above, below, sides) = seeds(around: rect, avoiding: pixelRects)
            let up = bubbleRegions(above), down = bubbleRegions(below), side = bubbleRegions(sides)
            while parent.count < regions.count { parent.append(parent.count) }
            let bridged = up + down
            if let first = bridged.first { bridged.dropFirst().forEach { union(first, $0) } }
            candidates.append(bridged + side)
        }
        while parent.count < regions.count { parent.append(parent.count) }

        var groupRects: [Int: CGRect] = [:]
        for id in regions.indices where regions[id].isBubble {
            let root = find(id)
            groupRects[root] = groupRects[root].map { $0.union(regions[id].rect) } ?? regions[id].rect
        }

        let ids: [Int?] = zip(pixelRects, candidates).map { rect, ids in
            var votes: [Int: Int] = [:]
            for id in ids {
                let root = find(id)
                guard let box = groupRects[root], encloses(box, rect) else { continue }
                votes[root, default: 0] += 1
            }
            return votes.max { $0.value < $1.value }?.key
        }
        return (ids, groupRects)
    }

    /// Điểm bắt đầu loang: khoảng trống ngay trên, ngay dưới và hai bên dòng chữ.
    private func seeds(around rect: CGRect, avoiding textRects: [CGRect])
        -> (above: [(Int, Int)], below: [(Int, Int)], sides: [(Int, Int)]) {
        let gap = max(1, rect.height * 0.45)
        let xs = [0.2, 0.5, 0.8].map { rect.minX + rect.width * $0 }
        func valid(_ points: [CGPoint]) -> [(Int, Int)] {
            points.compactMap { point in
                let x = Int(point.x), y = Int(point.y)
                guard x >= 0, y >= 0, x < image.width, y < image.height,
                      !textRects.contains(where: { $0.contains(point) }) else { return nil }
                return (x, y)
            }
        }
        return (
            valid(xs.map { CGPoint(x: $0, y: rect.minY - gap) }),
            valid(xs.map { CGPoint(x: $0, y: rect.maxY + gap) }),
            valid([CGPoint(x: rect.minX - gap * 1.4, y: rect.midY), CGPoint(x: rect.maxX + gap * 1.4, y: rect.midY)])
        )
    }

    /// Vùng loang phải bao quanh dòng chữ (lòng bóng thoại bao lấy chữ).
    private func encloses(_ region: CGRect, _ line: CGRect) -> Bool {
        let w = Double(image.width), h = Double(image.height)
        let box = CGRect(x: region.minX * w, y: region.minY * h, width: region.width * w, height: region.height * h)
        let slackX = line.width * 0.1
        return box.minX <= line.minX + slackX && box.maxX >= line.maxX - slackX
            && box.minY <= line.minY && box.maxY >= line.maxY
    }

    /// Vùng chứa điểm (loang nếu chưa có).
    private mutating func region(at seed: (Int, Int)) -> Int? {
        let index = seed.1 * image.width + seed.0
        if labels[index] == 0 { flood(from: index) }
        let label = Int(labels[index])
        return label > 0 ? label - 1 : nil
    }

    private mutating func flood(from start: Int) {
        let width = image.width, height = image.height
        let label = Int32(regions.count + 1)
        let seedValue = Int(image.pixels[start])
        let limit = Int(Double(width * height) * Self.maxAreaFraction)
        var stack = [start]
        labels[start] = label
        var area = 0
        var minX = width, maxX = 0, minY = height, maxY = 0
        while let index = stack.popLast() {
            area += 1
            let x = index % width, y = index / width
            minX = min(minX, x); maxX = max(maxX, x)
            minY = min(minY, y); maxY = max(maxY, y)
            if area > limit { break }
            // 4 điểm kề (không tạo mảng mỗi bước — vùng có thể tới hàng chục nghìn điểm).
            for step in 0..<4 {
                let next: Int
                switch step {
                case 0: guard x > 0 else { continue }; next = index - 1
                case 1: guard x < width - 1 else { continue }; next = index + 1
                case 2: guard y > 0 else { continue }; next = index - width
                default: guard y < height - 1 else { continue }; next = index + width
                }
                guard labels[next] == 0, abs(Int(image.pixels[next]) - seedValue) <= Self.tolerance else { continue }
                labels[next] = label
                stack.append(next)
            }
        }
        // Vùng quá lớn (nền trang), quá nhỏ (tranh lổn nhổn) hoặc mảnh như sợi chỉ (chính đường viền bóng thoại,
        // nét chữ dính viền) thì không phải lòng bóng thoại.
        let boxArea = (maxX - minX + 1) * (maxY - minY + 1)
        let isBubble = area <= limit && area >= 40 && Double(area) >= Double(boxArea) * 0.3
        regions.append(Region(
            rect: CGRect(x: Double(minX) / Double(width), y: Double(minY) / Double(height),
                         width: Double(maxX - minX + 1) / Double(width), height: Double(maxY - minY + 1) / Double(height)),
            isBubble: isBubble
        ))
    }
}
