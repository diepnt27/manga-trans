import UIKit
import CoreVideo

struct PiPEntry: Equatable {
    enum State: Equatable { case pending, done, error }

    var original: String
    var translation: String
    var state: State
}

/// Nội dung cửa sổ nổi: danh sách bóng thoại, hoặc một dòng thông báo khi chưa có gì.
struct PiPContent: Equatable {
    var entries: [PiPEntry] = []
    var message: String?
    var isError = false

    static func message(_ text: String, isError: Bool = false) -> PiPContent {
        PiPContent(entries: [], message: text, isError: isError)
    }
}

/// Vẽ nội dung cửa sổ nổi vào CVPixelBuffer để đưa vào AVSampleBufferDisplayLayer.
enum PiPRenderer {
    enum Palette {
        static let background = UIColor(red: 0.11, green: 0.11, blue: 0.12, alpha: 1)
        static let original = UIColor(white: 0.72, alpha: 1)
        static let translation = UIColor(red: 0.50, green: 0.82, blue: 0.78, alpha: 1)
        static let pending = UIColor(white: 0.5, alpha: 1)
        static let divider = UIColor(white: 1, alpha: 0.18)
        static let error = UIColor(red: 1.0, green: 0.45, blue: 0.42, alpha: 1)
    }

    private enum Item {
        case text(NSAttributedString)
        case divider(spacing: CGFloat)
        case spacer(CGFloat)
    }

    static func render(_ content: PiPContent, size: CGSize, showOriginal: Bool, fontScale: CGFloat) -> CVPixelBuffer? {
        let width = Int(size.width), height = Int(size.height)
        let attributes: [CFString: Any] = [
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
        ]
        var buffer: CVPixelBuffer?
        guard CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA,
                                  attributes as CFDictionary, &buffer) == kCVReturnSuccess,
              let pixelBuffer = buffer
        else { return nil }

        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }

        guard let context = CGContext(
            data: CVPixelBufferGetBaseAddress(pixelBuffer),
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer),
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return nil }

        // Lật trục Y cho khớp hệ toạ độ UIKit.
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)
        UIGraphicsPushContext(context)
        draw(content, in: CGRect(origin: .zero, size: size), showOriginal: showOriginal, fontScale: fontScale)
        UIGraphicsPopContext()
        return pixelBuffer
    }

    static func draw(_ content: PiPContent, in rect: CGRect, showOriginal: Bool, fontScale: CGFloat) {
        Palette.background.setFill()
        UIRectFill(rect)

        let unit = rect.width / 1080
        let padding = (48 * unit).rounded()
        let width = rect.width - padding * 2
        let maxHeight = rect.height - padding * 2
        let minSize = 22 * unit
        var fontSize = max(minSize, 56 * unit * fontScale)

        // Thu nhỏ chữ dần cho đến khi vừa khung.
        var items = makeItems(content, fontSize: fontSize, showOriginal: showOriginal)
        var height = measure(items, width: width)
        while height > maxHeight && fontSize > minSize {
            fontSize = max(minSize, fontSize - 2 * unit)
            items = makeItems(content, fontSize: fontSize, showOriginal: showOriginal)
            height = measure(items, width: width)
        }

        var y = rect.minY + padding + max(0, (maxHeight - height) / 2)
        for item in items {
            switch item {
            case .text(let string):
                let h = textHeight(string, width: width)
                string.draw(with: CGRect(x: padding, y: y, width: width, height: h),
                            options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil)
                y += h
            case .divider(let spacing):
                y += spacing
                Palette.divider.setFill()
                UIRectFill(CGRect(x: padding + width * 0.08, y: y, width: width * 0.84, height: max(1, 2 * unit)))
                y += spacing
            case .spacer(let h):
                y += h
            }
            if y > rect.maxY { break }
        }
    }

    private static func makeItems(_ content: PiPContent, fontSize: CGFloat, showOriginal: Bool) -> [Item] {
        guard !content.entries.isEmpty else {
            let color = content.isError ? Palette.error : Palette.original
            return [.text(attributed(content.message ?? "", size: fontSize * 0.8, weight: .medium, color: color))]
        }
        var items: [Item] = []
        for (index, entry) in content.entries.enumerated() {
            if index > 0 { items.append(.spacer(fontSize * 0.7)) }
            if showOriginal {
                items.append(.text(attributed(entry.original, size: fontSize * 0.72, weight: .semibold, color: Palette.original)))
                items.append(.divider(spacing: fontSize * 0.3))
            }
            switch entry.state {
            case .pending:
                items.append(.text(attributed("…", size: fontSize, weight: .semibold, color: Palette.pending)))
            case .done:
                items.append(.text(attributed(entry.translation, size: fontSize, weight: .medium, color: Palette.translation)))
            case .error:
                items.append(.text(attributed(entry.translation, size: fontSize * 0.75, weight: .medium, color: Palette.error)))
            }
        }
        return items
    }

    private static func attributed(_ text: String, size: CGFloat, weight: UIFont.Weight, color: UIColor) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineBreakMode = .byWordWrapping
        paragraph.lineSpacing = size * 0.12
        return NSAttributedString(string: text, attributes: [
            .font: UIFont.systemFont(ofSize: size, weight: weight),
            .foregroundColor: color,
            .paragraphStyle: paragraph,
        ])
    }

    private static func textHeight(_ string: NSAttributedString, width: CGFloat) -> CGFloat {
        let bounds = string.boundingRect(with: CGSize(width: width, height: .greatestFiniteMagnitude),
                                         options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil)
        return ceil(bounds.height)
    }

    private static func measure(_ items: [Item], width: CGFloat) -> CGFloat {
        items.reduce(0) { total, item in
            switch item {
            case .text(let string): return total + textHeight(string, width: width)
            case .divider(let spacing): return total + spacing * 2
            case .spacer(let h): return total + h
            }
        }
    }
}
