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

    private var filter = ScreenFilter()
    private var cache = TranslationCache()
    private var context: [TranslationPair] = []
    private var displayedKeys: [String] = []
    private var pendingKeys: [String] = []
    private var pendingBlocks: [TextBlock] = []
    private var debounceTask: Task<Void, Never>?
    private var translateTask: Task<Void, Never>?
    private var lastFrameTimestamp: TimeInterval = 0
    private var content = PiPContent.message(idleMessage)

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
        do {
            let input = TextNormalizer.translationInput(Self.sampleText)
            let result = try await TranslatorFactory.make(settings).translate([input], context: [])
            return result.first ?? ""
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
        let blocks = TextGrouper.group(lines, imageSize: CGSize(width: frame.width, height: frame.height))
            .filter { TextNormalizer.letterCount($0.displayText) >= 2 && !filter.isEchoOfTranslation($0) }
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
        let settings = AppSettings.load()
        let engine = settings.engine

        let newEntries = blocks.map { block -> PiPEntry in
            if let cached = cache.value(engine: engine, key: block.key) {
                return PiPEntry(original: block.displayText, translation: cached, state: .done)
            }
            return PiPEntry(original: block.displayText, translation: "", state: .pending)
        }
        showEntries(newEntries)

        let missing = blocks.indices.filter { newEntries[$0].state == .pending }
        guard !missing.isEmpty else {
            phase = .showing
            return
        }

        phase = .translating
        translateTask?.cancel()
        let translator = TranslatorFactory.make(settings)
        let inputs = missing.map { blocks[$0].translationInput }
        let recentContext = Array(context.suffix(8))
        let initialEntries = newEntries
        translateTask = Task { [weak self] in
            var newEntries = initialEntries
            do {
                let results = try await translator.translate(inputs, context: recentContext)
                guard !Task.isCancelled, let self else { return }
                for (offset, index) in missing.enumerated() {
                    let translated = results[offset].trimmingCharacters(in: .whitespacesAndNewlines)
                    newEntries[index].translation = translated
                    newEntries[index].state = .done
                    self.cache.set(translated, engine: engine, key: blocks[index].key)
                    self.context.append(TranslationPair(source: inputs[offset], target: translated))
                }
                if self.context.count > 30 { self.context.removeFirst(self.context.count - 30) }
                self.phase = .showing
                self.showEntries(newEntries)
            } catch {
                guard !Task.isCancelled, let self else { return }
                let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                for index in missing {
                    newEntries[index].translation = "Lỗi: \(message)"
                    newEntries[index].state = .error
                }
                self.phase = .error(message)
                // Lỗi thì lần sau thử dịch lại.
                self.displayedKeys = []
                self.showEntries(newEntries)
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
        pip.display(newContent, settings: AppSettings.load())
    }

    private func redraw() {
        pip.display(content, settings: AppSettings.load())
    }
}
