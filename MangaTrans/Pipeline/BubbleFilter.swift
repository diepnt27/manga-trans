import Foundation
import CoreGraphics

/// Ảnh độ sáng thu nhỏ — đủ để kiểm tra nền quanh chữ, rẻ hơn nhiều so với ảnh gốc.
struct LuminanceImage {
    let width: Int
    let height: Int
    let pixels: [UInt8]

    init(width: Int, height: Int, pixels: [UInt8]) {
        self.width = width
        self.height = height
        self.pixels = pixels
    }

    init?(cgImage: CGImage, maxWidth: Int = 400) {
        let scale = min(1, Double(maxWidth) / Double(max(1, cgImage.width)))
        let width = max(1, Int(Double(cgImage.width) * scale))
        let height = max(1, Int(Double(cgImage.height) * scale))
        var pixels = [UInt8](repeating: 0, count: width * height)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height,
                                          bitsPerComponent: 8, bytesPerRow: width,
                                          space: CGColorSpaceCreateDeviceGray(),
                                          bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            context.interpolationQuality = .low
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }
        self.init(width: width, height: height, pixels: pixels)
    }

    /// Toạ độ chuẩn hoá 0...1, gốc trên-trái.
    func value(atX x: Double, y: Double) -> UInt8? {
        let px = Int(x * Double(width)), py = Int(y * Double(height))
        guard px >= 0, py >= 0, px < width, py < height else { return nil }
        return pixels[py * width + px]
    }
}

/// Phân biệt chữ trong bóng thoại / khung lời dẫn với chữ hiệu ứng âm thanh, watermark vẽ đè lên tranh.
enum BubbleFilter {
    /// Tỉ lệ điểm ảnh trong vành quanh dòng chữ có cùng màu nền (0...1); `nil` nếu không đủ điểm để đo.
    /// Bóng thoại: nền trắng/đồng màu → gần 1. Chữ vẽ đè lên tranh: nền lổn nhổn → thấp.
    /// Bỏ qua điểm rơi vào các dòng chữ khác (dòng trên/dưới trong cùng bóng thoại).
    static func backgroundUniformity(around rect: CGRect, lineHeight: Double, excluding textRects: [CGRect],
                                     in image: LuminanceImage) -> Double? {
        let aspect = Double(image.height) / Double(max(1, image.width))
        let marginY = lineHeight * 0.45
        let marginX = marginY * aspect // cùng khoảng cách thật theo chiều ngang
        let outer = CGRect(x: Double(rect.minX) - marginX, y: Double(rect.minY) - marginY,
                           width: Double(rect.width) + marginX * 2, height: Double(rect.height) + marginY * 2)
        let padY = lineHeight * 0.15, padX = padY * aspect
        let blocked = textRects.map { $0.insetBy(dx: -padX, dy: -padY) }

        let steps = 24
        var samples: [UInt8] = []
        samples.reserveCapacity(steps * 16)
        for i in 0...steps {
            let t = Double(i) / Double(steps)
            // Hai vòng: sát mép ngoài và giữa vành.
            for inset in [0.0, 0.5] {
                let ix = marginX * inset, iy = marginY * inset
                let left = Double(outer.minX) + ix, right = Double(outer.maxX) - ix
                let top = Double(outer.minY) + iy, bottom = Double(outer.maxY) - iy
                let x = left + (right - left) * t
                let y = top + (bottom - top) * t
                for point in [(x, top), (x, bottom), (left, y), (right, y)] {
                    if blocked.contains(where: { $0.contains(CGPoint(x: point.0, y: point.1)) }) { continue }
                    if let v = image.value(atX: point.0, y: point.1) { samples.append(v) }
                }
            }
        }
        guard samples.count >= 12 else { return nil }
        let sorted = samples.sorted()
        let median = Int(sorted[sorted.count / 2])
        let close = samples.filter { abs(Int($0) - median) <= 28 }.count
        return Double(close) / Double(samples.count)
    }

    /// Giữ các dòng chữ nằm trên nền đồng màu (bóng thoại, khung lời dẫn); bỏ dòng vẽ đè lên tranh
    /// (chữ hiệu ứng, chữ viết tay cạnh bóng thoại, watermark). Lọc trước khi gộp để không dính vào bóng thoại thật.
    static func linesOnPlainBackground(_ lines: [OCRLine], in image: LuminanceImage, threshold: Double = 0.72) -> [OCRLine] {
        let rects = lines.map(\.rect)
        return lines.filter { line in
            guard let uniformity = backgroundUniformity(around: line.rect, lineHeight: line.h,
                                                        excluding: rects, in: image) else { return true }
            return uniformity >= threshold
        }
    }

    private static let watermark = try! NSRegularExpression(
        pattern: "(https?://|www\\.|[a-z0-9-]\\.(com|net|org|io|xyz|me|to|co)\\b|[a-z]+scans\\b|scanlation)",
        options: [.caseInsensitive]
    )

    /// Chữ rác: watermark / địa chỉ web, hoặc chữ ngắn đọc không chắc chắn (thường là chữ hiệu ứng tiếng Hàn/Nhật).
    static func isNoise(_ block: TextBlock) -> Bool {
        let text = block.displayText
        if watermark.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil { return true }

        let letters = TextNormalizer.letterCount(text)
        if letters < 2 { return true }
        if letters <= 6 {
            let confidence = block.lines.map(\.confidence).min() ?? 0
            if confidence < 0.6 || hasOddCasing(text) { return true }
        }
        return false
    }

    /// "TINg", "aBC": hoa thường lộn xộn trong cùng một từ — chữ truyện thật hầu như không có.
    static func hasOddCasing(_ text: String) -> Bool {
        for word in text.split(whereSeparator: { !$0.isLetter }) where word.count >= 3 {
            let upper = word.filter(\.isUppercase).count
            let lower = word.count - upper
            if upper >= 2 && lower >= 1 { return true }
            if let first = word.first, first.isLowercase, upper >= 1 { return true }
        }
        return false
    }
}
