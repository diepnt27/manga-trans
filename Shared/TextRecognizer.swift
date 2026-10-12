import Foundation
import Vision
import ImageIO

/// Nhận dạng chữ tiếng Anh bằng Vision. Dùng chung cho Broadcast Extension và chế độ Trình duyệt.
enum TextRecognizer {
    static func recognize(pixelBuffer: CVPixelBuffer, orientation: CGImagePropertyOrientation, accuracy: OCRAccuracy,
                          minimumTextHeight: Float = 0.008) throws -> [OCRLine] {
        let request = makeRequest(accuracy: accuracy, minimumTextHeight: minimumTextHeight)
        try VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: orientation, options: [:]).perform([request])
        return lines(from: request)
    }

    /// `minimumTextHeight`: chiều cao chữ nhỏ nhất (tỉ lệ theo chiều cao ảnh) — nhỏ hơn thì bắt được chữ nhỏ nhưng chậm hơn.
    static func recognize(cgImage: CGImage, accuracy: OCRAccuracy, minimumTextHeight: Float = 0.008) throws -> [OCRLine] {
        let request = makeRequest(accuracy: accuracy, minimumTextHeight: minimumTextHeight)
        try VNImageRequestHandler(cgImage: cgImage, options: [:]).perform([request])
        return lines(from: request)
    }

    private static func makeRequest(accuracy: OCRAccuracy, minimumTextHeight: Float) -> VNRecognizeTextRequest {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = accuracy == .fast ? .fast : .accurate
        request.recognitionLanguages = ["en-US"]
        request.usesLanguageCorrection = true
        request.minimumTextHeight = minimumTextHeight
        return request
    }

    private static func lines(from request: VNRecognizeTextRequest) -> [OCRLine] {
        (request.results ?? []).compactMap { observation in
            guard let candidate = observation.topCandidates(1).first else { return nil }
            let box = observation.boundingBox // gốc dưới-trái
            return OCRLine(
                text: candidate.string,
                confidence: candidate.confidence,
                x: Double(box.minX),
                y: Double(1 - box.maxY),
                w: Double(box.width),
                h: Double(box.height)
            )
        }
    }
}
