import AVKit
import AVFoundation
import UIKit

/// Cửa sổ nổi dùng Picture-in-Picture: nội dung được vẽ thành khung hình video
/// và đẩy vào AVSampleBufferDisplayLayer. PiP nổi trên mọi app và giữ app chạy nền.
final class PiPManager: NSObject, ObservableObject {
    let displayLayer = AVSampleBufferDisplayLayer()

    @Published private(set) var isActive = false
    @Published private(set) var isPossible = false
    @Published private(set) var isSupported = AVPictureInPictureController.isPictureInPictureSupported()

    /// Người dùng bấm X trên cửa sổ nổi.
    var onUserClosed: (() -> Void)?

    private var controller: AVPictureInPictureController?
    private var possibleObservation: NSKeyValueObservation?
    private var lastPixelBuffer: CVPixelBuffer?
    private var heartbeat: Timer?
    private var pendingStart = false
    private var isRestoring = false
    private var isStoppingProgrammatically = false

    override init() {
        super.init()
        displayLayer.videoGravity = .resizeAspect
        displayLayer.backgroundColor = UIColor.black.cgColor
        activateAudioSession()
        setupController()
        // Đẩy lại khung hình định kỳ để PiP luôn có nội dung.
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.reenqueue() }
        RunLoop.main.add(timer, forMode: .common)
        heartbeat = timer
    }

    /// Tự bật cửa sổ nổi khi rời app (chỉ nên bật khi đang dịch).
    var startsAutomaticallyInBackground: Bool {
        get { controller?.canStartPictureInPictureAutomaticallyFromInline ?? false }
        set { controller?.canStartPictureInPictureAutomaticallyFromInline = newValue }
    }

    func display(_ content: PiPContent, settings: AppSettings) {
        guard let buffer = PiPRenderer.render(
            content,
            size: settings.windowSize.canvasSize,
            showOriginal: settings.showOriginal,
            fontScale: CGFloat(settings.fontScale)
        ) else { return }
        lastPixelBuffer = buffer
        enqueue(buffer)
    }

    func start() {
        guard let controller else { return }
        activateAudioSession()
        if controller.isPictureInPicturePossible {
            controller.startPictureInPicture()
        } else {
            pendingStart = true
        }
    }

    func stop() {
        pendingStart = false
        guard let controller, controller.isPictureInPictureActive else { return }
        isStoppingProgrammatically = true
        controller.stopPictureInPicture()
    }

    // MARK: - Private

    private func activateAudioSession() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .moviePlayback, options: [.mixWithOthers])
        try? session.setActive(true)
    }

    private func setupController() {
        guard AVPictureInPictureController.isPictureInPictureSupported() else { return }
        let source = AVPictureInPictureController.ContentSource(sampleBufferDisplayLayer: displayLayer, playbackDelegate: self)
        let controller = AVPictureInPictureController(contentSource: source)
        controller.delegate = self
        controller.requiresLinearPlayback = true
        controller.canStartPictureInPictureAutomaticallyFromInline = false
        possibleObservation = controller.observe(\.isPictureInPicturePossible, options: [.initial, .new]) { [weak self] controller, _ in
            DispatchQueue.main.async {
                guard let self else { return }
                self.isPossible = controller.isPictureInPicturePossible
                if self.isPossible && self.pendingStart {
                    self.pendingStart = false
                    controller.startPictureInPicture()
                }
            }
        }
        self.controller = controller
    }

    private func reenqueue() {
        guard let lastPixelBuffer else { return }
        enqueue(lastPixelBuffer)
    }

    private func enqueue(_ pixelBuffer: CVPixelBuffer) {
        var format: CMVideoFormatDescription?
        CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pixelBuffer, formatDescriptionOut: &format)
        guard let format else { return }

        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: 30),
            presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()),
            decodeTimeStamp: .invalid
        )
        var sampleBuffer: CMSampleBuffer?
        CMSampleBufferCreateReadyWithImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            formatDescription: format,
            sampleTiming: &timing,
            sampleBufferOut: &sampleBuffer
        )
        guard let sampleBuffer else { return }

        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: true),
           CFArrayGetCount(attachments) > 0 {
            let dict = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(
                dict,
                Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                Unmanaged.passUnretained(kCFBooleanTrue).toOpaque()
            )
        }

        if displayLayer.status == .failed {
            displayLayer.flush()
        }
        displayLayer.enqueue(sampleBuffer)
    }
}

extension PiPManager: AVPictureInPictureControllerDelegate {
    func pictureInPictureControllerDidStartPictureInPicture(_ controller: AVPictureInPictureController) {
        isActive = true
    }

    func pictureInPictureControllerDidStopPictureInPicture(_ controller: AVPictureInPictureController) {
        isActive = false
        let closedByUser = !isRestoring && !isStoppingProgrammatically
        isRestoring = false
        isStoppingProgrammatically = false
        if closedByUser { onUserClosed?() }
    }

    func pictureInPictureController(_ controller: AVPictureInPictureController,
                                    failedToStartPictureInPictureWithError error: Error) {
        isActive = false
    }

    func pictureInPictureController(_ controller: AVPictureInPictureController,
                                    restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void) {
        isRestoring = true
        completionHandler(true)
    }
}

extension PiPManager: AVPictureInPictureSampleBufferPlaybackDelegate {
    func pictureInPictureController(_ controller: AVPictureInPictureController, setPlaying playing: Bool) {}

    func pictureInPictureControllerTimeRangeForPlayback(_ controller: AVPictureInPictureController) -> CMTimeRange {
        // Phát "trực tiếp" vô hạn → ẩn thanh tua.
        CMTimeRange(start: .negativeInfinity, duration: .positiveInfinity)
    }

    func pictureInPictureControllerIsPlaybackPaused(_ controller: AVPictureInPictureController) -> Bool {
        false
    }

    func pictureInPictureController(_ controller: AVPictureInPictureController,
                                    didTransitionToRenderSize newRenderSize: CMVideoDimensions) {}

    func pictureInPictureController(_ controller: AVPictureInPictureController,
                                    skipByInterval skipInterval: CMTime,
                                    completion completionHandler: @escaping () -> Void) {
        completionHandler()
    }
}
