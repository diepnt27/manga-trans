import Foundation
import UIKit

/// Điều phối: nhận OCR từ extension → lọc → gom bóng thoại → chờ màn hình đứng yên → dịch → hiện lên cửa sổ nổi.
@MainActor
final class TranslationCoordinator: ObservableObject {
    enum Phase: Equatable {
        case idle
        case waiting
        case translating
        case showing
        case error(String)
    }

    static let idleMessage = "Nhấn \"Bắt đầu\" để dịch màn hình"
    static let waitingMessage = "Đang chờ chữ trên màn hình…"
    static let sampleText = "I DON'T UNDERSTAND WHAT YOU'RE TRYING TO SAY."

    @Published private(set) var isBroadcasting = false
    @Published private(set) var phase: Phase = .idle
    @Published private(set) var entries: [PiPEntry] = []

    let pip = PiPManager()
    let translation = TranslationService()
    private(set) lazy var tabs = BrowserTabs(translation: translation)

    private var filter = ScreenFilter()
    private var displayedKeys: [String] = []
    private var pendingKeys: [String] = []
    private var previousScanKeys: Set<String> = []
    private var queue = BubbleQueue()
    private var pendingBlocks: [TextBlock] = []
    private var debounceTask: Task<Void, Never>?
    private var translateTask: Task<Void, Never>?
    private var lastFrameTimestamp: TimeInterval = 0
    private var content = PiPContent.message(idleMessage)
    private var renderSignature = ""

    init() {
        AppSettings.registerDefaults()
        let center = DarwinNotificationCenter.shared
        center.observe(DarwinName.ocrUpdated) { [weak self] in
            Task { @MainActor in self?.handleOCRUpdate() }
        }
        center.observe(DarwinName.broadcastStarted) { [weak self] in
            Task { @MainActor in self?.broadcastDidStart() }
        }
        center.observe(DarwinName.broadcastFinished) { [weak self] in
            Task { @MainActor in self?.broadcastDidFinish() }
        }
        pip.onUserClosed = { [weak self] in
            Task { @MainActor in self?.stop() }
        }
        // Đổi cài đặt (cỡ cửa sổ, cỡ chữ...) → vẽ lại ngay.
        NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.redraw() }
        }

        if AppGroup.defaults.bool(forKey: SettingsKey.broadcastActive) && UIScreen.main.isCaptured {
            broadcastDidStart()
        } else {
            show(.message(Self.idleMessage))
        }
    }

    // MARK: - Điều khiển

    func start() {
        pip.start()
        // Mở hộp thoại phát sóng sau khi cửa sổ nổi đã hiện.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            BroadcastLauncher.shared.present()
        }
    }

    func stop() {
        DarwinNotificationCenter.shared.post(DarwinName.stopRequest)
        broadcastDidFinish()
    }

    func testTranslation() async -> String {
        let settings = AppSettings.load()
        guard settings.translationConsent else {
            return "Lỗi: \(TranslatorError.consentRequired.localizedDescription)"
        }
        do {
            let input = TextNormalizer.translationInput(Self.sampleText)
            let started = Date()
            let result = try await TranslatorFactory.make(settings).translate([input], context: [])
            let seconds = Date().timeIntervalSince(started)
            return (result.first ?? "") + String(format: "  (%.1f giây)", seconds)
        } catch {
            return "Lỗi: \(error.localizedDescription)"
        }
    }

    // MARK: - Trạng thái phát sóng

    private func broadcastDidStart() {
        isBroadcasting = true
        phase = .waiting
        displayedKeys = []
        pendingKeys = []
        previousScanKeys = []
        queue.reset()
        lastFrameTimestamp = 0
        filter.reset()
        entries = []
        pip.startsAutomaticallyInBackground = true
        show(.message(Self.waitingMessage))
    }

    private func broadcastDidFinish() {
        guard isBroadcasting || pip.isActive else { return }
        isBroadcasting = false
        phase = .idle
        debounceTask?.cancel()
        translateTask?.cancel()
        pip.startsAutomaticallyInBackground = false
        pip.stop()
        show(.message(Self.idleMessage))
    }

    // MARK: - Xử lý OCR

    private func handleOCRUpdate() {
        guard
            let data = try? Data(contentsOf: AppGroup.ocrFileURL),
            let frame = try? JSONDecoder().decode(OCRFrame.self, from: data),
            frame.timestamp != lastFrameTimestamp
        else { return }
        lastFrameTimestamp = frame.timestamp
        if !isBroadcasting { broadcastDidStart() }

        let settings = AppSettings.load()
        filter.marginTop = settings.marginTop
        filter.marginBottom = settings.marginBottom

        let lines = filter.filter(frame.lines)
        let allBlocks = TextGrouper.group(lines, imageSize: CGSize(width: frame.width, height: frame.height),
                                          rightToLeft: settings.rightToLeft)
            .filter { !BubbleFilter.isNoise($0) && !filter.isEchoOfTranslation($0) }

        // Dịch trước: bóng thoại có ở 2 lần quét liên tiếp (kể cả khi đang cuộn) thì dịch sẵn vào cache,
        // dừng lại là hiện ngay. Bóng thoại bị cắt ở mép màn hình đổi chữ liên tục nên không bị dịch nhầm.
        // Dịch cả bóng thoại ngoài vùng đọc để cuộn tới là có ngay.
        if settings.prefetchWhileScrolling {
            translation.prefetch(allBlocks.filter { previousScanKeys.contains($0.key) }, settings: settings)
        }
        previousScanKeys = Set(allBlocks.map(\.key))

        // Chỉ hiện tối đa N bóng thoại trong vùng đọc; cuộn xuống thì chuyển sang các bóng chưa hiện.
        let inZone = allBlocks.filter { settings.readingZone.verticalRange.contains(Double($0.rect.midY)) }
        let blocks = queue.select(inZone, maxCount: settings.maxBubbles)
        let keys = blocks.map(\.key)

        // Không có chữ, hoặc chỉ còn các bóng thoại đang hiển thị → giữ nguyên.
        if keys.isEmpty || Set(keys).isSubset(of: Set(displayedKeys)) {
            debounceTask?.cancel()
            pendingKeys = []
            return
        }

        pendingBlocks = blocks
        // Đang chờ đúng nội dung này rồi → không đặt lại hẹn giờ.
        if keys == pendingKeys, debounceTask != nil { return }
        pendingKeys = keys
        debounceTask?.cancel()
        let delay = UInt64(max(0.1, settings.stableDelay) * 1_000_000_000)
        debounceTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: delay)
            guard !Task.isCancelled, let self else { return }
            self.debounceTask = nil
            self.pendingKeys = []
            self.commit(self.pendingBlocks)
        }
    }

    private func commit(_ blocks: [TextBlock]) {
        displayedKeys = blocks.map(\.key)
        queue.markShown(blocks)
        let settings = AppSettings.load()

        let initialEntries = blocks.map { block -> PiPEntry in
            if let cached = translation.cached(block, engine: settings.engine) {
                return PiPEntry(original: block.displayText, translation: cached, state: .done)
            }
            return PiPEntry(original: block.displayText, translation: "", state: .pending)
        }
        showEntries(initialEntries)
        guard initialEntries.contains(where: { $0.state == .pending }) else {
            phase = .showing
            return
        }

        phase = .translating
        translateTask?.cancel()
        translateTask = Task { [weak self] in
            guard let self else { return }
            do {
                let results = try await self.translation.translate(blocks, settings: settings)
                guard !Task.isCancelled else { return }
                self.phase = .showing
                self.showEntries(zip(blocks, results).map {
                    PiPEntry(original: $0.displayText, translation: $1, state: .done)
                })
            } catch {
                guard !Task.isCancelled else { return }
                let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                self.phase = .error(message)
                // Lỗi thì lần sau thử dịch lại.
                self.displayedKeys = []
                self.showEntries(initialEntries.map { entry in
                    guard entry.state == .pending else { return entry }
                    return PiPEntry(original: entry.original, translation: "Lỗi: \(message)", state: .error)
                })
            }
        }
    }

    // MARK: - Hiển thị

    private func showEntries(_ newEntries: [PiPEntry]) {
        entries = newEntries
        show(PiPContent(entries: newEntries))
    }

    private func show(_ newContent: PiPContent) {
        content = newContent
        filter.setDisplayed(
            originals: newContent.entries.map(\.original),
            translations: newContent.entries.map(\.translation) + [newContent.message ?? ""]
        )
        let settings = AppSettings.load()
        renderSignature = Self.renderSignature(settings)
        pip.display(newContent, settings: settings)
    }

    /// Cài đặt đổi → chỉ vẽ lại khi những mục ảnh hưởng đến cửa sổ nổi thực sự đổi.
    private func redraw() {
        let settings = AppSettings.load()
        let signature = Self.renderSignature(settings)
        guard signature != renderSignature else { return }
        renderSignature = signature
        pip.display(content, settings: settings)
    }

    private static func renderSignature(_ settings: AppSettings) -> String {
        "\(settings.windowSize.rawValue)|\(settings.showOriginal)|\(settings.fontScale)"
    }
}
