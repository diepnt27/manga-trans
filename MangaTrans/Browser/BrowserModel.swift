import Foundation
import UIKit
import WebKit

/// Chế độ Trình duyệt: mở trang truyện ngay trong app, chụp vùng web đang hiển thị khi ngừng cuộn,
/// nhận dạng chữ rồi dịch — không cần quay màn hình.
@MainActor
final class BrowserModel: NSObject, ObservableObject, Identifiable {
    let id = UUID()
    /// Trang mở lần đầu của tab (khôi phục từ lần trước).
    let initialURL: String?
    /// Gọi khi tải xong một trang — để lưu danh sách tab.
    var onPageFinished: (() -> Void)?
    /// Ảnh thu nhỏ cho danh sách tab.
    @Published private(set) var thumbnail: UIImage?

    /// Bản dịch đặt đè lên một bóng thoại.
    struct Overlay: Identifiable, Equatable {
        let id: Int
        /// Toạ độ chuẩn hoá 0...1 theo khung web.
        let rect: CGRect
        /// Chiều cao dòng chữ gốc (chuẩn hoá) — để chọn cỡ chữ.
        let lineHeight: CGFloat
        let text: String
        let state: PiPEntry.State
    }

    struct Bookmark: Codable, Identifiable, Hashable {
        var title: String
        var url: String
        var id: String { url }
    }

    /// Trang Tab mới (giao diện của app, không phải trang web).
    static let startPageURL = "manga-browser://start"
    static let homeURL = startPageURL
    static let idleStatus = "Dừng cuộn để dịch"

    let webView: WKWebView

    @Published private(set) var currentURL = ""
    @Published private(set) var title = ""
    @Published private(set) var hasPage = false
    /// Đang hiện trang Tab mới (đè lên trang web, nếu có).
    @Published private(set) var showsStartPage = false
    @Published private(set) var canGoBack = false
    @Published private(set) var canGoForward = false
    @Published private(set) var isLoading = false
    @Published private(set) var progress: Double = 0
    @Published private(set) var isScrolling = false
    /// Thanh công cụ dưới và thanh tab đang ẩn (tự ẩn khi cuộn xuống đọc).
    @Published private(set) var isChromeHidden = false
    @Published private(set) var entries: [PiPEntry] = []
    @Published private(set) var overlays: [Overlay] = []
    @Published private(set) var status = idleStatus
    @Published private(set) var bookmarks: [Bookmark] = []
    /// Tiến độ dịch trước cả chương.
    @Published private(set) var chapterProgress = ChapterProgress()
    @Published var isTranslationEnabled = true {
        didSet {
            if isTranslationEnabled {
                lastKeys = []
                scheduleScan(after: 0.1)
                refreshChapter(force: true)
            } else {
                translateTask?.cancel()
                chapter.reset()
                overlays = []
                status = "Đã tắt dịch"
            }
        }
    }

    private let translation: TranslationService
    private let chapter = ChapterPrefetcher()
    private var chapterTimer: Timer?
    private var observations: [NSKeyValueObservation] = []
    private var scanTimer: Timer?
    private var followUpTimer: Timer?
    private var translateTask: Task<Void, Never>?
    /// Tăng mỗi lần cuộn — kết quả OCR của khung hình cũ sẽ bị bỏ.
    private var generation = 0
    private var isScanning = false
    private var needsRescan = false
    private var rescanFollowUp = false
    private var lastKeys: [String] = []
    private var lastGeneration = -1
    private var stableDelay = 0.4
    private var prefetchEnabled = true
    private var lastPrefetchScan = Date.distantPast
    private var previousPrefetchKeys: Set<String> = []
    private var autoHideChrome = true
    private var lastOffsetY: CGFloat = 0
    private var chromeTravel: CGFloat = 0
    private var queue = BubbleQueue()
    /// Các bóng thoại đang hiện trong khung dịch.
    private var focusedKeys: Set<String> = []

    static let lastURLKey = "browserLastURL"
    private let bookmarksKey = "browserBookmarks"

    init(translation: TranslationService, initialURL: String? = nil) {
        self.translation = translation
        self.initialURL = initialURL
        let configuration = WKWebViewConfiguration()
        // Một số trang chỉ hiện đúng giao diện cho Safari.
        configuration.applicationNameForUserAgent = "Version/18.0 Mobile/15E148 Safari/604.1"
        configuration.allowsInlineMediaPlayback = true
        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init()

        webView.allowsBackForwardNavigationGestures = true
        webView.navigationDelegate = self
        webView.uiDelegate = self
        observeWebView()
        bookmarks = loadBookmarks()
        chapter.onProgress = { [weak self] in self?.chapterProgress = $0 }
    }

    // MARK: - Điều hướng

    func restoreIfNeeded() {
        guard !hasPage, !showsStartPage else { return }
        load(initialURL ?? Self.homeURL)
    }

    /// Có trang web đang đọc (không phải trang Tab mới) — mới quét và dịch.
    private var isReadingPage: Bool { hasPage && !showsStartPage }

    /// Địa chỉ lưu lại cho lần mở app sau.
    var persistedURL: String {
        if showsStartPage { return Self.startPageURL }
        return currentURL.isEmpty ? (initialURL ?? Self.homeURL) : currentURL
    }

    /// Nút quay lại: từ trang Tab mới về trang web đang mở dưới nó.
    var canNavigateBack: Bool { showsStartPage ? hasPage : canGoBack }

    func showStartPage() {
        guard !showsStartPage else { return }
        showsStartPage = true
        translateTask?.cancel()
        chapterTimer?.invalidate()
        chapter.reset()
        SpeechReader.shared.stop()
        overlays = []
        entries = []
        thumbnail = nil
        isChromeHidden = false
        status = Self.idleStatus
        onPageFinished?()
    }

    func reloadBookmarks() {
        bookmarks = loadBookmarks()
    }

    func captureThumbnail() {
        guard isReadingPage, webView.bounds.width > 0 else { return }
        let configuration = WKSnapshotConfiguration()
        configuration.snapshotWidth = 240
        webView.takeSnapshot(with: configuration) { [weak self] image, _ in
            Task { @MainActor in self?.thumbnail = image }
        }
    }

    /// Đóng tab: dừng tải, huỷ mọi việc đang chạy.
    func close() {
        webView.stopLoading()
        scanTimer?.invalidate()
        followUpTimer?.invalidate()
        translateTask?.cancel()
        chapterTimer?.invalidate()
        chapter.reset()
        observations = []
    }

    func load(_ input: String) {
        if input == Self.startPageURL {
            showStartPage()
            return
        }
        guard let url = Self.url(from: input) else { return }
        hasPage = true
        showsStartPage = false
        webView.load(URLRequest(url: url))
    }

    func goBack() {
        if showsStartPage {
            showsStartPage = false
            lastKeys = []
            scheduleScan(after: 0.3)
            onPageFinished?()
        } else {
            webView.goBack()
        }
    }
    func goForward() { webView.goForward() }

    /// Xoá cookie, bộ nhớ đệm, dữ liệu đăng nhập của các trang web và trang đọc dở.
    func clearBrowsingData() {
        WKWebsiteDataStore.default().removeData(
            ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(),
            modifiedSince: .distantPast
        ) {}
    }

    /// Chỉ mở trang web; chặn link gọi điện, mở app khác, file trên máy, scheme lạ.
    nonisolated static func isAllowedNavigation(_ url: URL?) -> Bool {
        guard let scheme = url?.scheme?.lowercased() else { return true }
        return ["http", "https", "about", "data", "blob"].contains(scheme)
    }

    func reload() {
        if isLoading { webView.stopLoading() } else { webView.reload() }
    }

    /// Dịch lại vùng đang xem (bỏ qua kết quả cũ).
    func rescan() {
        lastKeys = []
        scan(followUp: false)
    }

    /// Chữ người dùng gõ → URL: có dạng tên miền thì mở trang, không thì tìm bằng Google.
    nonisolated static func url(from input: String) -> URL? {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        let lower = text.lowercased()
        if lower.hasPrefix("http://") || lower.hasPrefix("https://") {
            return URL(string: text)
        }
        if !text.contains(" "), text.contains("."), let url = URL(string: "https://" + text), url.host != nil {
            return url
        }
        var components = URLComponents(string: "https://www.google.com/search")!
        components.queryItems = [URLQueryItem(name: "q", value: text)]
        return components.url
    }

    // MARK: - Dấu trang

    var isBookmarked: Bool { bookmarks.contains { $0.url == currentURL } }

    func toggleBookmark() {
        guard !currentURL.isEmpty else { return }
        if isBookmarked {
            bookmarks.removeAll { $0.url == currentURL }
        } else {
            bookmarks.insert(Bookmark(title: title.isEmpty ? currentURL : title, url: currentURL), at: 0)
        }
        saveBookmarks()
    }

    func removeBookmarks(at offsets: IndexSet) {
        bookmarks.remove(atOffsets: offsets)
        saveBookmarks()
    }

    private func loadBookmarks() -> [Bookmark] {
        guard let data = UserDefaults.standard.data(forKey: bookmarksKey) else { return [] }
        return (try? JSONDecoder().decode([Bookmark].self, from: data)) ?? []
    }

    private func saveBookmarks() {
        UserDefaults.standard.set(try? JSONEncoder().encode(bookmarks), forKey: bookmarksKey)
    }

    // MARK: - Theo dõi WebView

    private func observeWebView() {
        observations = [
            webView.observe(\.url, options: [.new]) { [weak self] webView, _ in
                Task { @MainActor in self?.currentURL = webView.url?.absoluteString ?? "" }
            },
            webView.observe(\.title, options: [.new]) { [weak self] webView, _ in
                Task { @MainActor in self?.title = webView.title ?? "" }
            },
            webView.observe(\.estimatedProgress, options: [.new]) { [weak self] webView, _ in
                Task { @MainActor in self?.progress = webView.estimatedProgress }
            },
            webView.observe(\.isLoading, options: [.new]) { [weak self] webView, _ in
                Task { @MainActor in self?.isLoading = webView.isLoading }
            },
            webView.observe(\.canGoBack, options: [.new]) { [weak self] webView, _ in
                Task { @MainActor in self?.canGoBack = webView.canGoBack }
            },
            webView.observe(\.canGoForward, options: [.new]) { [weak self] webView, _ in
                Task { @MainActor in self?.canGoForward = webView.canGoForward }
            },
            webView.scrollView.observe(\.contentOffset, options: [.new]) { [weak self] scrollView, _ in
                let offsetY = scrollView.contentOffset.y
                let byUser = scrollView.isDragging || scrollView.isDecelerating
                // Gọi thẳng trên luồng chính (sự kiện cuộn luôn ở đó) thay vì tạo Task mỗi khung hình (tới 120 lần/giây).
                if #available(iOS 17.0, *), Thread.isMainThread {
                    MainActor.assumeIsolated { self?.didScroll(offsetY: offsetY, byUser: byUser) }
                } else {
                    Task { @MainActor in self?.didScroll(offsetY: offsetY, byUser: byUser) }
                }
            },
        ]
    }

    private func didScroll(offsetY: CGFloat, byUser: Bool) {
        updateChrome(offsetY: offsetY, byUser: byUser)
        generation += 1
        if !isScrolling {
            isScrolling = true
            overlays = []
            autoHideChrome = UserDefaults.standard.object(forKey: Self.autoHideChromeKey) as? Bool ?? true
            let settings = AppSettings.load()
            stableDelay = max(0.25, settings.stableDelay)
            prefetchEnabled = settings.prefetchWhileScrolling
        }
        followUpTimer?.invalidate()
        scheduleScan(after: stableDelay)
        // Đang cuộn: cứ ~1.2 giây quét một lần để dịch sẵn, dừng lại là hiện ngay.
        if prefetchEnabled, !isScanning, Date().timeIntervalSince(lastPrefetchScan) > 1.2 {
            prefetchScan()
        }
    }

    // MARK: - Tự ẩn thanh công cụ

    nonisolated static let autoHideChromeKey = "browserAutoHideChrome"

    /// Cuộn xuống (đang đọc) → ẩn thanh công cụ dưới và thanh tab; cuộn ngược lên hoặc về đầu trang → hiện lại.
    private func updateChrome(offsetY: CGFloat, byUser: Bool) {
        defer { lastOffsetY = offsetY }
        guard autoHideChrome else {
            if isChromeHidden { isChromeHidden = false }
            return
        }
        if offsetY <= 10 {
            chromeTravel = 0
            if isChromeHidden { isChromeHidden = false }
            return
        }
        // Bỏ qua thay đổi do trang tự đổi bố cục, chỉ tính khi người dùng cuộn.
        guard byUser else { return }
        let delta = offsetY - lastOffsetY
        if (delta > 0) != (chromeTravel > 0) { chromeTravel = 0 }
        chromeTravel += delta
        if chromeTravel > 30, !isChromeHidden {
            isChromeHidden = true
        } else if chromeTravel < -60, isChromeHidden {
            isChromeHidden = false
        }
    }

    // MARK: - Quét & dịch

    /// Chữ nhỏ nhất cần bắt (tỉ lệ theo chiều cao khung web) — đủ nhỏ cho khung lời dẫn, chú thích.
    private static let minimumTextHeight: Float = 0.005

    private func scheduleScan(after delay: TimeInterval) {
        scanTimer?.invalidate()
        scanTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            Task { @MainActor in
                self?.isScrolling = false
                self?.scan(followUp: true)
            }
        }
    }

    private func scan(followUp: Bool) {
        guard isTranslationEnabled, isReadingPage, webView.bounds.width > 0 else { return }
        if isScanning {
            needsRescan = true
            rescanFollowUp = rescanFollowUp || followUp
            return
        }
        refreshChapter()
        let scanGeneration = generation
        captureBlocks(afterScreenUpdates: true) { [weak self] blocks in
            self?.process(blocks, generation: scanGeneration, followUp: followUp)
        }
    }

    /// Dịch trước cả chương (ảnh mới tải thêm khi cuộn cũng được xử lý; tự giãn cách 8 giây).
    private func refreshChapter(force: Bool = false) {
        guard isTranslationEnabled, isReadingPage else { return }
        chapter.refresh(webView: webView, translation: translation, conversation: id.uuidString, force: force)
    }

    /// Quét lúc đang cuộn: chỉ dịch sẵn vào cache, không hiển thị.
    private func prefetchScan() {
        guard isTranslationEnabled, isReadingPage, webView.bounds.width > 0 else { return }
        lastPrefetchScan = Date()
        captureBlocks(afterScreenUpdates: false) { [weak self] blocks in
            guard let self else { return }
            // Chỉ dịch bóng thoại thấy ở 2 lần quét liên tiếp — bỏ qua đoạn lướt nhanh và bóng thoại bị cắt ở mép.
            self.translation.prefetch(blocks.filter { self.previousPrefetchKeys.contains($0.key) }, settings: AppSettings.load(),
                                     conversation: self.id.uuidString)
            self.previousPrefetchKeys = Set(blocks.map(\.key))
        }
    }

    /// Chụp vùng web đang hiển thị, nhận dạng chữ và gom bóng thoại (chạy nền).
    private func captureBlocks(afterScreenUpdates: Bool, _ handler: @escaping ([TextBlock]) -> Void) {
        isScanning = true
        let configuration = WKSnapshotConfiguration()
        configuration.afterScreenUpdates = afterScreenUpdates
        let screenScale = webView.window?.screen.scale ?? 2
        configuration.snapshotWidth = NSNumber(value: Double(Self.snapshotPixelWidth(for: webView.bounds.width) / screenScale))
        let minimumTextHeight = Self.minimumTextHeight
        let bubbleOnly = AppSettings.load().bubbleTextOnly
        webView.takeSnapshot(with: configuration) { [weak self] image, _ in
            Task { @MainActor in
                guard let self else { return }
                guard let cgImage = image?.cgImage else {
                    self.finishScan()
                    return
                }
                let blocks = await Task.detached(priority: .userInitiated) { () -> [TextBlock] in
                    let lines = (try? TextRecognizer.recognize(cgImage: cgImage, accuracy: .accurate,
                                                               minimumTextHeight: minimumTextHeight)) ?? []
                    guard !lines.isEmpty else { return [] }
                    let background = bubbleOnly ? LuminanceImage(cgImage: cgImage) : nil
                    return Self.makeBlocks(lines, imageSize: CGSize(width: cgImage.width, height: cgImage.height),
                                           background: background)
                }.value
                handler(blocks)
                self.finishScan()
            }
        }
    }

    /// Độ rộng (pixel) ảnh chụp để nhận dạng chữ: mật độ 2x thay vì 3x (ít hơn ~55% điểm ảnh, chữ truyện vẫn đủ nét),
    /// tối đa 1200 px — màn hình iPad lớn thì chữ truyện cũng to, không cần chụp nét hơn.
    nonisolated static func snapshotPixelWidth(for pointWidth: CGFloat) -> CGFloat {
        min(pointWidth * 2, 1200)
    }

    /// `background` có thì chỉ giữ chữ nằm trong bóng thoại / khung lời dẫn (nền đồng màu).
    nonisolated static func makeBlocks(_ lines: [OCRLine], imageSize: CGSize, background: LuminanceImage?) -> [TextBlock] {
        let confident = lines.filter { $0.confidence >= 0.3 }
        let inBubbles = background.map { BubbleFilter.linesOnPlainBackground(confident, in: $0) } ?? confident
        return TextGrouper.group(inBubbles, imageSize: imageSize)
            .filter { !BubbleFilter.isNoise($0) }
    }

    private func finishScan() {
        isScanning = false
        if needsRescan {
            needsRescan = false
            let followUp = rescanFollowUp
            rescanFollowUp = false
            scan(followUp: followUp)
        }
    }

    private func process(_ blocks: [TextBlock], generation scanGeneration: Int, followUp: Bool) {
        // Đã cuộn tiếp trong lúc nhận dạng → khung hình cũ, bỏ.
        guard scanGeneration == generation, isTranslationEnabled else { return }

        if followUp && blocks.isEmpty {
            // Chưa thấy chữ — có thể ảnh truyện còn đang tải → quét lại một lần sau khi dừng.
            followUpTimer?.invalidate()
            followUpTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: false) { [weak self] _ in
                Task { @MainActor in self?.scan(followUp: false) }
            }
        }

        let keys = blocks.map(\.key)
        if keys == lastKeys && scanGeneration == lastGeneration { return }
        lastKeys = keys
        lastGeneration = scanGeneration

        guard !blocks.isEmpty else {
            overlays = []
            status = entries.isEmpty ? "Không thấy chữ tiếng Anh" : Self.idleStatus
            return
        }

        let settings = AppSettings.load()
        // Khung dịch: tối đa N bóng thoại trong vùng đọc; cuộn xuống thì chuyển sang các bóng chưa hiện.
        let inZone = blocks.filter { settings.readingZone.verticalRange.contains(Double($0.rect.midY)) }
        let focused = queue.select(inZone, maxCount: settings.maxBubbles)
        queue.markShown(focused)
        if !focused.isEmpty { focusedKeys = Set(focused.map(\.key)) }

        // Kiểu khung dịch: chỉ dịch các bóng đang hiện trong khung (đỡ tốn token). Kiểu đè lên bóng thoại: dịch hết.
        let panelOnly = UserDefaults.standard.string(forKey: BrowserDisplayMode.storageKey) != BrowserDisplayMode.overlay.rawValue
        let targets = panelOnly ? blocks.filter { focusedKeys.contains($0.key) } : blocks
        guard !targets.isEmpty else {
            status = Self.idleStatus
            return
        }

        let initial: [(String, PiPEntry.State)] = targets.map { block in
            if let cached = translation.cached(block, engine: settings.engine) { return (cached, .done) }
            return ("…", .pending)
        }
        show(targets, initial, generation: scanGeneration)
        guard initial.contains(where: { $0.1 == .pending }) else {
            status = "Đã dịch \(targets.count) bóng thoại"
            return
        }

        status = "Đang dịch…"
        translateTask?.cancel()
        translateTask = Task { [weak self] in
            guard let self else { return }
            do {
                let results = try await self.translation.translate(targets, settings: settings, conversation: self.id.uuidString)
                guard !Task.isCancelled else { return }
                self.status = "Đã dịch \(targets.count) bóng thoại"
                self.show(targets, results.map { ($0, .done) }, generation: scanGeneration)
            } catch {
                guard !Task.isCancelled else { return }
                let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                self.status = "Lỗi: \(message)"
                self.lastKeys = []
                self.show(targets, initial.map { item -> (String, PiPEntry.State) in item.1 == .pending ? ("Lỗi dịch", .error) : item }, generation: scanGeneration)
            }
        }
    }

    private func show(_ blocks: [TextBlock], _ results: [(String, PiPEntry.State)], generation scanGeneration: Int) {
        // Khung dịch: chỉ các bóng thoại đã chọn. Kiểu đè lên bóng thoại: hiện tất cả.
        let panelEntries = zip(blocks, results)
            .filter { focusedKeys.contains($0.0.key) }
            .map { PiPEntry(original: $0.displayText, translation: $1.0, state: $1.1) }
        // Vùng đọc trống (ví dụ chỉ có chữ ở cuối màn hình) → giữ bản dịch đang hiện.
        if !panelEntries.isEmpty { entries = panelEntries }
        // Vị trí chỉ còn đúng nếu chưa cuộn.
        guard scanGeneration == generation else { return }
        overlays = zip(blocks, results).enumerated().map { index, item in
            let (block, result) = item
            let lineHeight = block.lines.map(\.h).reduce(0, +) / Double(max(1, block.lines.count))
            return Overlay(id: index, rect: block.rect, lineHeight: CGFloat(lineHeight), text: result.0, state: result.1)
        }
    }
}

extension BrowserModel: WKNavigationDelegate {
    func webView(_ webView: WKWebView,
                 decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
        Self.isAllowedNavigation(navigationAction.request.url) ? .allow : .cancel
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        SpeechReader.shared.stop()
        chapterTimer?.invalidate()
        chapter.reset()
        overlays = []
        entries = []
        lastKeys = []
        queue.reset()
        focusedKeys = []
        status = Self.idleStatus
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        onPageFinished?()
        DiscoverStore.shared.recordVisit(pageTitle: webView.title ?? "", url: webView.url?.absoluteString ?? "")
        scheduleScan(after: 0.6)
        // Chờ trang dựng xong danh sách ảnh rồi mới dịch trước cả chương.
        chapterTimer?.invalidate()
        chapterTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.refreshChapter(force: true) }
        }
    }
}

extension BrowserModel: WKUIDelegate {
    /// Link mở tab mới (target=_blank): mở luôn trong khung hiện tại. Cửa sổ bật lên do script tự mở (thường là quảng cáo) bị chặn.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if navigationAction.targetFrame == nil, navigationAction.navigationType == .linkActivated {
            webView.load(navigationAction.request)
        }
        return nil
    }
}
