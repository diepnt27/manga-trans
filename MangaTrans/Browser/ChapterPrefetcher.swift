import Foundation
import ImageIO
import WebKit

/// Dịch trước cả chương: lấy các ảnh truyện trên trang, nhận dạng chữ ngầm rồi gom bóng thoại
/// gửi dịch theo lô lớn (cả chương chỉ 1–vài lần gửi). Bản dịch vào cache — cuộn tới đâu hiện ngay tới đó,
/// khung dịch vẫn hiện như cấu hình.
@MainActor
final class ChapterPrefetcher {
    /// Số bóng thoại đã dịch sẵn của trang hiện tại; `working`: đang nhận dạng / dịch.
    var onProgress: ((_ ready: Int, _ working: Bool) -> Void)?

    private var task: Task<Void, Never>?
    /// Ảnh đã nhận dạng của trang hiện tại (theo URL).
    private var processed: Set<String> = []
    private var ready = 0
    private var lastRefresh = Date.distantPast
    private var needsRerun = false
    /// Lô dịch lỗi (key sai, hết hạn mức...) → dừng nhận dạng tiếp cho đỡ tốn pin.
    private var stopped = false
    /// Sau lỗi dịch, tạm nghỉ một lúc thay vì gửi lại mỗi lần dừng cuộn.
    private var pausedUntil = Date.distantPast

    /// Chuyển trang: huỷ việc đang làm (lô chưa gửi không tốn token nữa).
    func reset() {
        task?.cancel()
        task = nil
        processed = []
        ready = 0
        needsRerun = false
        lastRefresh = .distantPast
        onProgress?(0, false)
    }

    /// Gọi khi trang tải xong và mỗi lần dừng cuộn: trang tải ảnh dần (lazy load) hoặc nối chương sau
    /// thì chỉ xử lý thêm các ảnh mới.
    func refresh(webView: WKWebView, translation: TranslationService, conversation: String, force: Bool = false) {
        guard force || Date().timeIntervalSince(lastRefresh) > 8, Date() >= pausedUntil else { return }
        let settings = AppSettings.load()
        guard settings.chapterPrefetch, settings.translationConsent, settings.engine.chapterBatchSize != nil,
              webView.bounds.width > 0 else { return }
        // Tiết kiệm pin / máy đang nóng: chỉ dịch phần đang xem.
        let thermal = ProcessInfo.processInfo.thermalState
        guard !ProcessInfo.processInfo.isLowPowerModeEnabled, thermal != .serious, thermal != .critical else { return }
        if task != nil {
            needsRerun = true
            return
        }
        lastRefresh = Date()
        task = Task { [weak self] in
            await self?.run(webView: webView, translation: translation, conversation: conversation, settings: settings)
            guard let self, !Task.isCancelled else { return }
            self.task = nil
            self.onProgress?(self.ready, false)
            if self.needsRerun {
                self.needsRerun = false
                self.refresh(webView: webView, translation: translation, conversation: conversation, force: true)
            }
        }
    }

    private func run(webView: WKWebView, translation: TranslationService, conversation: String,
                     settings: AppSettings) async {
        guard let page = await Self.collectImages(in: webView) else { return }
        let fresh = page.images.filter { !processed.contains($0) }
        // Ít ảnh lớn → không giống trang đọc truyện (trang tìm kiếm, trang tin...) → bỏ qua.
        guard !fresh.isEmpty, page.images.count >= 3,
              let batchSize = settings.engine.chapterBatchSize else { return }
        onProgress?(ready, true)

        let session = Self.makeSession(cookies: await Self.cookies(of: webView), userAgent: page.userAgent)
        defer { session.finishTasksAndInvalidate() }
        let job = RecognitionJob(
            session: session,
            referer: webView.url?.absoluteString,
            // Cùng độ phân giải và tỉ lệ khung với ảnh chụp màn hình lúc đọc → OCR ra cùng câu, khớp cache.
            targetWidth: max(320, Int(webView.bounds.width * 2)),
            tileAspect: min(2.4, max(1.2, Double(webView.bounds.height / webView.bounds.width))),
            bubbleOnly: settings.bubbleTextOnly
        )

        var continuation: AsyncStream<[TextBlock]>.Continuation?
        let stream = AsyncStream<[TextBlock]> { continuation = $0 }
        guard let batches = continuation else { return }
        stopped = false

        await withTaskGroup(of: Void.self) { group in
            // Dịch: lần lượt từng lô để lô sau có ngữ cảnh (xưng hô) của lô trước.
            group.addTask { @MainActor in
                for await batch in stream {
                    guard !Task.isCancelled, !self.stopped else { continue }
                    do {
                        let count = try await translation.translateChapter(batch, settings: settings,
                                                                           conversation: conversation)
                        guard !Task.isCancelled else { continue }
                        self.ready += count
                        self.onProgress?(self.ready, true)
                    } catch {
                        // Lỗi key / mạng / hết hạn mức: dừng, phần đang xem vẫn dịch như thường.
                        self.stopped = true
                        if !Task.isCancelled { self.pausedUntil = Date().addingTimeInterval(60) }
                    }
                }
            }
            // Nhận dạng: từng ảnh theo thứ tự đọc, đủ một lô thì gửi dịch, vẫn nhận dạng tiếp trong lúc chờ.
            group.addTask { @MainActor in
                var pending: [TextBlock] = []
                for url in fresh {
                    if Task.isCancelled || self.stopped { break }
                    let blocks = await Task.detached(priority: .utility) { await job.recognize(url) }.value
                    if Task.isCancelled { break }
                    self.processed.insert(url)
                    pending += blocks
                    if pending.count >= batchSize {
                        batches.yield(pending)
                        pending = []
                    }
                }
                if !pending.isEmpty { batches.yield(pending) }
                batches.finish()
            }
        }
    }

    // MARK: - Lấy ảnh trên trang

    private struct PageImages: Decodable {
        let userAgent: String
        let images: [String]
    }

    /// Ảnh lớn (gần hết bề ngang trang) theo thứ tự từ trên xuống, kể cả ảnh chưa tải (lazy load: data-src...).
    private static let collectScript = """
    (() => {
      const vw = window.innerWidth;
      const lazy = ['data-src', 'data-lazy-src', 'data-original', 'data-url', 'data-echo', 'data-lazy'];
      const skip = /logo|avatar|icon|banner|sprite|emoji|gravatar|[\\/._-]ads?[\\/._-]/i;
      const seen = new Set();
      const found = [];
      for (const img of document.images) {
        let src = img.currentSrc || img.src || '';
        if (!src || src.startsWith('data:') || (img.complete && img.naturalWidth > 0 && img.naturalWidth < 50)) {
          for (const name of lazy) {
            const value = img.getAttribute(name);
            if (value && !value.startsWith('data:')) { src = value; break; }
          }
        }
        try { src = new URL(src.trim(), document.baseURI).href; } catch (e) { continue; }
        if (!/^https?:/.test(src) || seen.has(src) || skip.test(src)) continue;
        const box = img.getBoundingClientRect();
        if (box.width < vw * 0.5 && img.naturalWidth < 500) continue;
        if (box.height > 0 && box.height < 80) continue;
        seen.add(src);
        found.push({ src, top: box.top + window.scrollY });
      }
      found.sort((a, b) => a.top - b.top);
      return JSON.stringify({ userAgent: navigator.userAgent, images: found.slice(0, 200).map(f => f.src) });
    })()
    """

    private static func collectImages(in webView: WKWebView) async -> PageImages? {
        let json: String? = await withCheckedContinuation { continuation in
            webView.evaluateJavaScript(collectScript) { result, _ in
                continuation.resume(returning: result as? String)
            }
        }
        guard let json else { return nil }
        return try? JSONDecoder().decode(PageImages.self, from: Data(json.utf8))
    }

    private static func cookies(of webView: WKWebView) async -> [HTTPCookie] {
        await withCheckedContinuation { continuation in
            webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { continuation.resume(returning: $0) }
        }
    }

    /// Tải ảnh như trình duyệt (cookie, user agent, trang gốc) — nhiều trang truyện chặn tải ảnh từ nơi khác.
    private static func makeSession(cookies: [HTTPCookie], userAgent: String) -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpAdditionalHeaders = ["User-Agent": userAgent, "Accept": "image/*,*/*;q=0.8"]
        configuration.timeoutIntervalForRequest = 20
        configuration.httpMaximumConnectionsPerHost = 2
        cookies.forEach { configuration.httpCookieStorage?.setCookie($0) }
        return URLSession(configuration: configuration)
    }
}

/// Tải một ảnh truyện, cắt thành các khung cao bằng màn hình rồi nhận dạng chữ (chạy nền).
struct RecognitionJob: Sendable {
    let session: URLSession
    let referer: String?
    let targetWidth: Int
    let tileAspect: Double
    let bubbleOnly: Bool

    /// Ảnh lớn hơn mức này thường không phải trang truyện.
    private static let maxBytes = 25_000_000

    func recognize(_ urlString: String) async -> [TextBlock] {
        guard let url = URL(string: urlString) else { return [] }
        var request = URLRequest(url: url)
        if let referer { request.setValue(referer, forHTTPHeaderField: "Referer") }
        guard let loaded = try? await session.data(for: request),
              (loaded.1 as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) ?? true,
              loaded.0.count <= Self.maxBytes,
              let image = Self.decode(loaded.0, targetWidth: targetWidth) else { return [] }
        return blocks(in: image)
    }

    func blocks(in image: CGImage) -> [TextBlock] {
        let tileHeight = Int(Double(image.width) * tileAspect)
        var result: [TextBlock] = []
        for tile in Self.tiles(height: image.height, tileHeight: tileHeight) {
            if Task.isCancelled { break }
            let crop = CGRect(x: 0, y: tile.start, width: image.width, height: tile.end - tile.start)
            guard let piece = image.cropping(to: crop) else { continue }
            let lines = (try? TextRecognizer.recognize(cgImage: piece, accuracy: .accurate, minimumTextHeight: 0.005)) ?? []
            guard !lines.isEmpty else { continue }
            let background = bubbleOnly ? LuminanceImage(cgImage: piece) : nil
            let height = Double(tile.end - tile.start)
            let blocks = BrowserModel.makeBlocks(lines, imageSize: CGSize(width: piece.width, height: piece.height),
                                                 background: background)
            // Bóng thoại nằm ở phần chồng giữa 2 khung: chỉ lấy ở khung chứa tâm của nó.
            result += blocks.filter {
                let midY = Double(tile.start) + Double($0.rect.midY) * height
                return midY >= Double(tile.ownStart) && midY < Double(tile.ownEnd)
            }
        }
        return result
    }

    struct Tile: Equatable {
        let start: Int
        let end: Int
        /// Vùng khung này "sở hữu" (tâm bóng thoại rơi vào đây thì lấy ở khung này).
        let ownStart: Int
        let ownEnd: Int
    }

    /// Chia ảnh dài (webtoon) thành các khung chồng nhau 30% để bóng thoại ở chỗ cắt vẫn nằm trọn trong một khung.
    static func tiles(height: Int, tileHeight: Int) -> [Tile] {
        guard height > 0 else { return [] }
        let tileHeight = max(1, tileHeight)
        if height <= tileHeight * 115 / 100 {
            return [Tile(start: 0, end: height, ownStart: 0, ownEnd: height)]
        }
        let step = max(1, tileHeight * 7 / 10)
        var starts: [Int] = []
        var start = 0
        while start + tileHeight < height {
            starts.append(start)
            start += step
        }
        starts.append(height - tileHeight)
        var tiles: [Tile] = []
        for (index, start) in starts.enumerated() {
            let end = start + tileHeight
            let ownStart = index == 0 ? 0 : (start + starts[index - 1] + tileHeight) / 2
            let ownEnd = index == starts.count - 1 ? height : (starts[index + 1] + end) / 2
            tiles.append(Tile(start: start, end: end, ownStart: ownStart, ownEnd: ownEnd))
        }
        return tiles
    }

    /// Giải mã và thu nhỏ luôn khi đọc (không giải mã ảnh gốc cỡ lớn vào RAM).
    static func decode(_ data: Data, targetWidth: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width >= 300, height >= 200 else { return nil }
        let scale = min(1, Double(targetWidth) / Double(width))
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: max(1, Int(Double(max(width, height)) * scale)),
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
}
