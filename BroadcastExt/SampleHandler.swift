import ReplayKit
import Vision
import ImageIO

/// Nhận khung hình toàn màn hình từ ReplayKit, chạy OCR (Vision) rồi ghi kết quả vào App Group.
/// Việc dịch và hiển thị do app chính đảm nhận — extension bị giới hạn RAM (~50MB) nên chỉ làm OCR.
final class SampleHandler: RPBroadcastSampleHandler {
    private let queue = DispatchQueue(label: "mangatrans.ocr", qos: .userInitiated)
    private let lock = NSLock()
    private var isBusy = false
    private var lastScan: CFAbsoluteTime = 0
    private var lastSignature = ""
    private var lastWrite: CFAbsoluteTime = 0
    private var settings = AppSettings.load()

    override func broadcastStarted(withSetupInfo setupInfo: [String: NSObject]?) {
        let defaults = AppGroup.defaults
        // Lần trước extension bị hệ thống tắt giữa lúc OCR (thường do vượt giới hạn RAM)
        // → tự chuyển sang chế độ OCR nhanh, nhẹ hơn.
        if defaults.bool(forKey: SettingsKey.ocrInFlight) {
            defaults.set(OCRAccuracy.fast.rawValue, forKey: SettingsKey.ocrAccuracy)
            defaults.set(true, forKey: SettingsKey.autoSwitchedToFast)
        }
        defaults.set(false, forKey: SettingsKey.ocrInFlight)
        defaults.set(true, forKey: SettingsKey.broadcastActive)
        settings = AppSettings.load()

        DarwinNotificationCenter.shared.observe(DarwinName.stopRequest) { [weak self] in
            let error = NSError(domain: "MangaTrans", code: 0, userInfo: [
                NSLocalizedDescriptionKey: "Đã dừng dịch màn hình.",
            ])
            self?.finishBroadcastWithError(error)
        }
        DarwinNotificationCenter.shared.post(DarwinName.broadcastStarted)
    }

    override func broadcastFinished() {
        AppGroup.defaults.set(false, forKey: SettingsKey.broadcastActive)
        AppGroup.defaults.set(false, forKey: SettingsKey.ocrInFlight)
        DarwinNotificationCenter.shared.post(DarwinName.broadcastFinished)
    }

    override func processSampleBuffer(_ sampleBuffer: CMSampleBuffer, with sampleBufferType: RPSampleBufferType) {
        guard sampleBufferType == .video else { return }

        let now = CFAbsoluteTimeGetCurrent()
        lock.lock()
        if isBusy || now - lastScan < settings.scanInterval {
            lock.unlock()
            return
        }
        isBusy = true
        lastScan = now
        lock.unlock()

        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            markIdle()
            return
        }
        let orientation = Self.orientation(of: sampleBuffer)
        queue.async { [weak self] in
            guard let self else { return }
            autoreleasepool {
                self.recognize(pixelBuffer, orientation: orientation)
            }
            self.markIdle()
        }
    }

    private func markIdle() {
        lock.lock()
        isBusy = false
        lock.unlock()
    }

    private func recognize(_ pixelBuffer: CVPixelBuffer, orientation: CGImagePropertyOrientation) {
        settings = AppSettings.load()
        let defaults = AppGroup.defaults

        let request = VNRecognizeTextRequest()
        request.recognitionLevel = settings.ocrAccuracy == .fast ? .fast : .accurate
        request.recognitionLanguages = ["en-US"]
        request.usesLanguageCorrection = true
        request.minimumTextHeight = 0.008

        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: orientation, options: [:])
        defaults.set(true, forKey: SettingsKey.ocrInFlight)
        do {
            try handler.perform([request])
        } catch {
            defaults.set(false, forKey: SettingsKey.ocrInFlight)
            return
        }
        defaults.set(false, forKey: SettingsKey.ocrInFlight)

        let lines: [OCRLine] = (request.results ?? []).compactMap { observation in
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

        // Không ghi lại nếu chữ không đổi (vẫn ghi định kỳ để app cập nhật vị trí).
        let signature = lines.map(\.text).joined(separator: "\n")
        let now = CFAbsoluteTimeGetCurrent()
        if signature == lastSignature && now - lastWrite < 3 { return }
        lastSignature = signature
        lastWrite = now

        var width = Double(CVPixelBufferGetWidth(pixelBuffer))
        var height = Double(CVPixelBufferGetHeight(pixelBuffer))
        if [.left, .right, .leftMirrored, .rightMirrored].contains(orientation) {
            swap(&width, &height)
        }
        let frame = OCRFrame(timestamp: Date().timeIntervalSince1970, width: width, height: height, lines: lines)
        guard let data = try? JSONEncoder().encode(frame) else { return }
        do {
            try data.write(to: AppGroup.ocrFileURL, options: .atomic)
            DarwinNotificationCenter.shared.post(DarwinName.ocrUpdated)
        } catch {
            // App Group chưa được cấp quyền — không có cách nào gửi kết quả.
        }
    }

    private static func orientation(of sampleBuffer: CMSampleBuffer) -> CGImagePropertyOrientation {
        guard
            let number = CMGetAttachment(sampleBuffer, key: RPVideoSampleOrientationKey as CFString, attachmentModeOut: nil) as? NSNumber,
            let orientation = CGImagePropertyOrientation(rawValue: number.uint32Value)
        else { return .up }
        return orientation
    }
}
