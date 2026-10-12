import Foundation
import UIKit
import WebKit

/// Chế độ Trình duyệt: mở trang truyện ngay trong app, chụp vùng web đang hiển thị khi ngừng cuộn,
/// nhận dạng chữ rồi dịch — không cần quay màn hình.
@MainActor
final class BrowserModel: NSObject, ObservableObject {
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

    static let homeURL = "https://www.google.com"
    static let idleStatus = "Dừng cuộn để dịch"

    let webView: WKWebView

    @Published private(set) var currentURL = ""
    @Published private(set) var title = ""
    @Published private(set) var hasPage = false
    @Published private(set) var canGoBack = false
    @Published private(set) var canGoForward = false
    @Published private(set) var isLoading = false
    @Published private(set) var progress: Double = 0
    @Published private(set) var isScrolling = false
    @Published private(set) var entries: [PiPEntry] = []
    @Published private(set) var overlays: [Overlay] = []
    @Published private(set) var status = idleStatus
    @Published private(set) var bookmarks: [Bookmark] = []
    @Published var isTranslationEnabled = true {
        didSet {
            if isTranslationEnabled {
                lastKeys = []
                scheduleScan(after: 0.1)
            } else {
                translateTask?.cancel()
                overlays = []
                status = "Đã tắt dịch"
            }
        }
    }

    private let translation: TranslationService
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

    private let lastURLKey = "browserLastURL"
    private let bookmarksKey = "browserBookmarks"

    init(translation: TranslationService) {
        self.translation = translation
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
    }

    // MARK: - Điều hướng

    func restoreIfNeeded() {
        guard !hasPage else { return }
        load(UserDefaults.standard.string(forKey: lastURLKey) ?? Self.homeURL)
    }

    func load(_ input: String) {
        guard let url = Self.url(from: input) else { return }
        hasPage = true
        webView.load(URLRequest(url: url))
    }

    func goBack() { webView.goBack() }
    func goForward() { webView.goForward() }

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
            webView.scrollView.observe(\.contentOffset, options: [.new]) { [weak self] _, _ in
                Task { @MainActor in self?.didScroll() }
            },
        ]
    }

    private func didScroll() {
        generation += 1
        if !isScrolling {
            isScrolling = true
            overlays = []
            let settings = AppSettings.load()
            stableDelay = max(0.25, settings.stableDelay)
            prefetchEnabled = settings.prefetchWhileScrolling
        }
        followUpTimer?.invalidate()
        scheduleScan(after: stableDelay)
        // Đang cuộn: cứ ~0.8 giây quét một lần để dịch sẵn, dừng lại là hiện ngay.
        if prefetchEnabled, !isScanning, Date().timeIntervalSince(lastPrefetchScan) > 0.8 {
            prefetchScan()
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
        guard isTranslationEnabled, hasPage, webView.bounds.width > 0 else { return }
        if isScanning {
            needsRescan = true
            rescanFollowUp = rescanFollowUp || followUp
            return
        }
        let scanGeneration = generation
        captureLines(afterScreenUpdates: true) { [weak self] lines, size in
            self?.process(lines, imageSize: size, generation: scanGeneration, followUp: followUp)
        }
    }

    /// Quét lúc đang cuộn: chỉ dịch sẵn vào cache, không hiển thị.
    private func prefetchScan() {
        guard isTranslationEnabled, hasPage, webView.bounds.width > 0 else { return }
        lastPrefetchScan = Date()
        captureLines(afterScreenUpdates: false) { [weak self] lines, size in
            guard let self else { return }
            let blocks = Self.makeBlocks(lines, imageSize: size)
            // Chỉ dịch bóng thoại thấy ở 2 lần quét liên tiếp — bỏ qua đoạn lướt nhanh và bóng thoại bị cắt ở mép.
            self.translation.prefetch(blocks.filter { self.previousPrefetchKeys.contains($0.key) }, settings: AppSettings.load())
            self.previousPrefetchKeys = Set(blocks.map(\.key))
        }
    }

    /// Chụp vùng web đang hiển thị rồi nhận dạng chữ (chạy nền).
    private func captureLines(afterScreenUpdates: Bool, _ handler: @escaping ([OCRLine], CGSize) -> Void) {
        isScanning = true
        let configuration = WKSnapshotConfiguration()
        configuration.afterScreenUpdates = afterScreenUpdates
        let minimumTextHeight = Self.minimumTextHeight
        webView.takeSnapshot(with: configuration) { [weak self] image, _ in
            Task { @MainActor in
                guard let self else { return }
                guard let cgImage = image?.cgImage else {
                    self.finishScan()
                    return
                }
                let size = CGSize(width: cgImage.width, height: cgImage.height)
                let lines = await Task.detached(priority: .userInitiated) {
                    (try? TextRecognizer.recognize(cgImage: cgImage, accuracy: .accurate,
                                                   minimumTextHeight: minimumTextHeight)) ?? []
                }.value
                handler(lines, size)
                self.finishScan()
            }
        }
    }

    private static func makeBlocks(_ lines: [OCRLine], imageSize: CGSize) -> [TextBlock] {
        TextGrouper.group(lines.filter { $0.confidence >= 0.3 }, imageSize: imageSize)
            .filter { TextNormalizer.letterCount($0.displayText) >= 2 }
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

    private func process(_ lines: [OCRLine], imageSize: CGSize, generation scanGeneration: Int, followUp: Bool) {
        // Đã cuộn tiếp trong lúc nhận dạng → khung hình cũ, bỏ.
        guard scanGeneration == generation, isTranslationEnabled else { return }

        if followUp {
            // Ảnh truyện thường tải chậm hơn → quét lại một lần nữa sau khi dừng.
            followUpTimer?.invalidate()
            followUpTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: false) { [weak self] _ in
                Task { @MainActor in self?.scan(followUp: false) }
            }
        }

        let blocks = Self.makeBlocks(lines, imageSize: imageSize)
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
        let initial: [(String, PiPEntry.State)] = blocks.map { block in
            if let cached = translation.cached(block, engine: settings.engine) { return (cached, .done) }
            return ("…", .pending)
        }
        show(blocks, initial, generation: scanGeneration)
        guard initial.contains(where: { $0.1 == .pending }) else {
            status = "Đã dịch \(blocks.count) bóng thoại"
            return
        }

        status = "Đang dịch…"
        translateTask?.cancel()
        translateTask = Task { [weak self] in
            guard let self else { return }
            do {
                let results = try await self.translation.translate(blocks, settings: settings)
                guard !Task.isCancelled else { return }
                self.status = "Đã dịch \(blocks.count) bóng thoại"
                self.show(blocks, results.map { ($0, .done) }, generation: scanGeneration)
            } catch {
                guard !Task.isCancelled else { return }
                let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                self.status = "Lỗi: \(message)"
                self.lastKeys = []
                self.show(blocks, initial.map { item -> (String, PiPEntry.State) in item.1 == .pending ? ("Lỗi dịch", .error) : item }, generation: scanGeneration)
            }
        }
    }

    private func show(_ blocks: [TextBlock], _ results: [(String, PiPEntry.State)], generation scanGeneration: Int) {
        // Khung dịch: chỉ các bóng thoại trong vùng đọc, vừa đủ độ dài. Kiểu đè lên bóng thoại: hiện tất cả.
        let settings = AppSettings.load()
        let focused = Set(FocusSelector.select(blocks, zone: settings.readingZone,
                                               maxCharacters: settings.windowSize.maxCharacters).map(\.key))
        let panelEntries = zip(blocks, results)
            .filter { focused.contains($0.0.key) }
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
    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        overlays = []
        entries = []
        lastKeys = []
        status = Self.idleStatus
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        if let url = webView.url?.absoluteString {
            UserDefaults.standard.set(url, forKey: lastURLKey)
        }
        scheduleScan(after: 0.6)
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
