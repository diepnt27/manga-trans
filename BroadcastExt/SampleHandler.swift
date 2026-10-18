import ReplayKit
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
    private var lastFingerprint: FrameFingerprint?
    private var lastRecognized: CFAbsoluteTime = 0

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
        // Màn hình đứng yên (đang đọc) → bỏ qua OCR, chỉ quét lại thưa (10 giây) phòng khi sót.
        if let fingerprint = FrameFingerprint(pixelBuffer: pixelBuffer) {
            if let last = lastFingerprint, fingerprint.difference(to: last) < 1.5, now - lastRecognized < 10 {
                markIdle()
                return
            }
            lastFingerprint = fingerprint
        }
        lastRecognized = now
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

        defaults.set(true, forKey: SettingsKey.ocrInFlight)
        let lines: [OCRLine]
        do {
            lines = try TextRecognizer.recognize(pixelBuffer: pixelBuffer, orientation: orientation, accuracy: settings.ocrAccuracy)
        } catch {
            defaults.set(false, forKey: SettingsKey.ocrInFlight)
            return
        }
        defaults.set(false, forKey: SettingsKey.ocrInFlight)

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
