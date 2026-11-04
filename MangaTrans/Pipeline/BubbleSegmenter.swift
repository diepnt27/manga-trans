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

    /// Mã bóng thoại của từng dòng (`nil`: không nằm trong bóng thoại / khung chữ nào rõ ràng).
    mutating func bubbleIDs(for lines: [OCRLine]) -> [Int?] {
        let w = Double(image.width), h = Double(image.height)
        let pixelRects = lines.map { CGRect(x: $0.x * w, y: $0.y * h, width: $0.w * w, height: $0.h * h) }
        return pixelRects.map { rect in
            var votes: [Int: Int] = [:]
            for seed in seeds(around: rect, avoiding: pixelRects) {
                guard let id = region(at: seed), regions[id].isBubble, encloses(regions[id].rect, rect) else { continue }
                votes[id, default: 0] += 1
            }
            return votes.max { $0.value < $1.value }?.key
        }
    }

    /// Điểm bắt đầu loang: khoảng trống ngay trên, dưới và hai bên dòng chữ.
    private func seeds(around rect: CGRect, avoiding textRects: [CGRect]) -> [(Int, Int)] {
        let gap = max(1, rect.height * 0.45)
        var points: [CGPoint] = []
        for fraction in [0.2, 0.5, 0.8] {
            let x = rect.minX + rect.width * fraction
            points.append(CGPoint(x: x, y: rect.minY - gap))
            points.append(CGPoint(x: x, y: rect.maxY + gap))
        }
        points.append(CGPoint(x: rect.minX - gap * 1.4, y: rect.midY))
        points.append(CGPoint(x: rect.maxX + gap * 1.4, y: rect.midY))
        return points.compactMap { point in
            let x = Int(point.x), y = Int(point.y)
            guard x >= 0, y >= 0, x < image.width, y < image.height,
                  !textRects.contains(where: { $0.contains(point) }) else { return nil }
            return (x, y)
        }
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
        // Vùng quá lớn (nền trang) hoặc quá nhỏ (tranh lổn nhổn) thì không phải bóng thoại.
        let isBubble = area <= limit && area >= 40
        regions.append(Region(
            rect: CGRect(x: Double(minX) / Double(width), y: Double(minY) / Double(height),
                         width: Double(maxX - minX + 1) / Double(width), height: Double(maxY - minY + 1) / Double(height)),
            isBubble: isBubble
        ))
    }
}
