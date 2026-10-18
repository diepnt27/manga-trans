import Foundation
import CoreVideo

/// "Dấu vân tay" rất rẻ của một khung hình: độ sáng tại một lưới điểm thưa.
/// Dùng để bỏ qua OCR khi màn hình đứng yên (đang đọc, không cuộn) — OCR là việc tốn pin nhất.
struct FrameFingerprint: Equatable {
    static let columns = 24
    static let rows = 48

    let samples: [UInt8]

    init(samples: [UInt8]) {
        self.samples = samples
    }

    /// Hỗ trợ ảnh YUV (ReplayKit, lấy mặt phẳng độ sáng) và BGRA.
    init?(pixelBuffer: CVPixelBuffer) {
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        let base: UnsafeMutableRawPointer?
        let bytesPerRow: Int, width: Int, height: Int, bytesPerPixel: Int, channel: Int
        if CVPixelBufferIsPlanar(pixelBuffer) {
            base = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0)
            bytesPerRow = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0)
            width = CVPixelBufferGetWidthOfPlane(pixelBuffer, 0)
            height = CVPixelBufferGetHeightOfPlane(pixelBuffer, 0)
            bytesPerPixel = 1
            channel = 0
        } else {
            guard CVPixelBufferGetPixelFormatType(pixelBuffer) == kCVPixelFormatType_32BGRA else { return nil }
            base = CVPixelBufferGetBaseAddress(pixelBuffer)
            bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
            width = CVPixelBufferGetWidth(pixelBuffer)
            height = CVPixelBufferGetHeight(pixelBuffer)
            bytesPerPixel = 4
            channel = 1 // kênh xanh lá ≈ độ sáng
        }
        guard let base, width > 0, height > 0 else { return nil }

        let pixels = base.assumingMemoryBound(to: UInt8.self)
        var samples: [UInt8] = []
        samples.reserveCapacity(Self.columns * Self.rows)
        for row in 0..<Self.rows {
            let y = (row * 2 + 1) * height / (Self.rows * 2)
            for column in 0..<Self.columns {
                let x = (column * 2 + 1) * width / (Self.columns * 2)
                samples.append(pixels[y * bytesPerRow + x * bytesPerPixel + channel])
            }
        }
        self.samples = samples
    }

    /// Chênh lệch độ sáng trung bình (0...255).
    func difference(to other: FrameFingerprint) -> Double {
        guard samples.count == other.samples.count, !samples.isEmpty else { return 255 }
        let total = zip(samples, other.samples).reduce(0) { $0 + abs(Int($1.0) - Int($1.1)) }
        return Double(total) / Double(samples.count)
    }
}
