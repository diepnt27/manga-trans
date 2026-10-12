import Foundation
import CoreGraphics

/// Một dòng chữ nhận dạng được trên màn hình.
/// Toạ độ chuẩn hoá 0...1, gốc ở góc trên-trái màn hình.
struct OCRLine: Codable, Equatable {
    var text: String
    var confidence: Float
    var x: Double
    var y: Double
    var w: Double
    var h: Double

    var rect: CGRect { CGRect(x: x, y: y, width: w, height: h) }
    var center: CGPoint { CGPoint(x: x + w / 2, y: y + h / 2) }
}

/// Kết quả OCR của một khung hình, extension ghi ra file JSON trong App Group.
struct OCRFrame: Codable {
    var timestamp: TimeInterval
    /// Kích thước ảnh (pixel) theo đúng hướng hiển thị.
    var width: Double
    var height: Double
    var lines: [OCRLine]
}
