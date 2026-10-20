import XCTest
import CoreVideo
import UIKit
@testable import MangaTrans

final class TextNormalizerTests: XCTestCase {
    func testSentenceCaseForAllCapsBubble() {
        XCTAssertEqual(
            TextNormalizer.translationInput("I DON'T UNDERSTAND WHAT YOU'RE TRYING TO SAY."),
            "I don't understand what you're trying to say."
        )
        XCTAssertEqual(
            TextNormalizer.translationInput("WAIT!  WHERE ARE YOU GOING? i'M COMING"),
            "Wait! Where are you going? I'm coming"
        )
    }

    func testMixedCaseIsKept() {
        XCTAssertEqual(TextNormalizer.translationInput("Hello there, NASA"), "Hello there, NASA")
    }

    func testFoldRemovesVietnameseDiacritics() {
        XCTAssertEqual(TextNormalizer.key("Tôi không hiểu bạn đang muốn nói gì. Đi!"),
                       "toi khong hieu ban dang muon noi gi di")
    }
}

final class TextGrouperTests: XCTestCase {
    private let screen = CGSize(width: 1179, height: 2556)

    private func line(_ text: String, x: Double, y: Double, w: Double, h: Double = 0.016) -> OCRLine {
        OCRLine(text: text, confidence: 1, x: x, y: y, w: w, h: h)
    }

    func testGroupsStackedLinesIntoBubbles() {
        // Bóng thoại trong ảnh chụp: 5 dòng căn giữa, xếp sát nhau.
        let bubble = [
            line("I DON'T", x: 0.235, y: 0.390, w: 0.15),
            line("UNDERSTAND", x: 0.185, y: 0.412, w: 0.25),
            line("WHAT YOU'RE", x: 0.175, y: 0.434, w: 0.27),
            line("TRYING TO", x: 0.195, y: 0.456, w: 0.23),
            line("SAY.", x: 0.27, y: 0.478, w: 0.08),
        ]
        let other = [
            line("WHY DO", x: 0.62, y: 0.70, w: 0.14),
            line("YOU THINK THEY", x: 0.56, y: 0.722, w: 0.27),
        ]
        let blocks = TextGrouper.group((other + bubble).shuffled(), imageSize: screen)

        XCTAssertEqual(blocks.count, 2)
        XCTAssertEqual(blocks[0].displayText, "I DON'T UNDERSTAND WHAT YOU'RE TRYING TO SAY.")
        XCTAssertEqual(blocks[0].translationInput, "I don't understand what you're trying to say.")
        XCTAssertEqual(blocks[1].displayText, "WHY DO YOU THINK THEY")
    }

    func testFarApartLinesStaySeparate() {
        let blocks = TextGrouper.group([
            line("HEY!", x: 0.1, y: 0.2, w: 0.1),
            line("WHAT?", x: 0.1, y: 0.3, w: 0.1),
        ], imageSize: screen)
        XCTAssertEqual(blocks.map(\.displayText), ["HEY!", "WHAT?"])
    }

    func testSideBySideBubblesReadLeftToRight() {
        let blocks = TextGrouper.group([
            line("RIGHT", x: 0.7, y: 0.30, w: 0.15),
            line("LEFT", x: 0.1, y: 0.31, w: 0.12),
        ], imageSize: screen)
        XCTAssertEqual(blocks.map(\.displayText), ["LEFT", "RIGHT"])
    }

    func testHyphenatedLineBreak() {
        XCTAssertEqual(TextGrouper.joinRows(["IT'S SOME-", "THING ELSE"]), "IT'S SOMETHING ELSE")
        XCTAssertEqual(TextGrouper.joinRows(["WAIT--", "NO"]), "WAIT-- NO")
    }
}

final class ScreenFilterTests: XCTestCase {
    func testRemovesFloatingWindowTextButKeepsComic() {
        var filter = ScreenFilter()
        filter.marginTop = 0
        filter.marginBottom = 0
        filter.setDisplayed(
            originals: ["I DON'T UNDERSTAND WHAT YOU'RE TRYING TO SAY."],
            translations: ["Tôi không hiểu bạn đang muốn nói gì."]
        )
        let pipOriginal = OCRLine(text: "I DON'T UNDERSTAND WHAT YOU'RE TRYING", confidence: 1, x: 0.1, y: 0.08, w: 0.8, h: 0.015)
        let pipTranslation = OCRLine(text: "Toi khong hieu ban dang muon noi gi.", confidence: 1, x: 0.1, y: 0.12, w: 0.8, h: 0.015)
        let comicLine = OCRLine(text: "I DON'T UNDERSTAND", confidence: 1, x: 0.2, y: 0.40, w: 0.3, h: 0.016)
        let newBubble = OCRLine(text: "WHY DO YOU THINK", confidence: 1, x: 0.5, y: 0.70, w: 0.3, h: 0.016)

        let kept = filter.filter([pipOriginal, pipTranslation, comicLine, newBubble])
        XCTAssertEqual(kept.map(\.text), ["I DON'T UNDERSTAND", "WHY DO YOU THINK"])
        XCTAssertNotNil(filter.pipRect)
    }

    func testMarginsAndLowConfidenceAreDropped() {
        var filter = ScreenFilter()
        let statusBar = OCRLine(text: "21:04", confidence: 1, x: 0.1, y: 0.01, w: 0.1, h: 0.015)
        let toolbar = OCRLine(text: "Hỏi Gemini", confidence: 1, x: 0.1, y: 0.95, w: 0.2, h: 0.015)
        let noise = OCRLine(text: "xx", confidence: 0.1, x: 0.1, y: 0.5, w: 0.1, h: 0.015)
        let text = OCRLine(text: "HELLO", confidence: 0.9, x: 0.1, y: 0.5, w: 0.1, h: 0.015)
        XCTAssertEqual(filter.filter([statusBar, toolbar, noise, text]).map(\.text), ["HELLO"])
    }
}

final class TranslatorParsingTests: XCTestCase {
    func testGoogleResponse() throws {
        let json = #"[[["Tôi không hiểu ","I don't understand ",null,null,10],["bạn nói gì.","what you say.",null,null,10]],null,"en"]"#
        XCTAssertEqual(try GoogleFreeTranslator.parse(Data(json.utf8)), "Tôi không hiểu bạn nói gì.")
    }

    func testGoogleCloudResponse() throws {
        let json = #"{"data":{"translations":[{"translatedText":"Một","detectedSourceLanguage":"en"},{"translatedText":"Hai"}]}}"#
        XCTAssertEqual(try GoogleCloudTranslator.parse(Data(json.utf8)), ["Một", "Hai"])
    }

    func testLLMJsonWithCodeFence() throws {
        let content = "```json\n{\"translations\": [\"Một\", \"Hai\"]}\n```"
        XCTAssertEqual(try MangaPrompt.parse(content, expected: 2), ["Một", "Hai"])
    }

    func testLLMCountMismatchIsPadded() throws {
        XCTAssertEqual(try MangaPrompt.parse(#"{"translations": ["Một"]}"#, expected: 2), ["Một", "(?)"])
        // Lô lớn lệch số câu: báo lỗi (để chia nhỏ gửi lại) thay vì ghép sai bản dịch.
        XCTAssertThrowsError(try MangaPrompt.parse(#"{"translations": ["Một", "Hai"]}"#, expected: 3))
        XCTAssertEqual(try MangaPrompt.parse(#"{"translations": ["Một", "Hai"]}"#, expected: 1), ["Một Hai"])
        XCTAssertEqual(try MangaPrompt.parse("Xin chào", expected: 1), ["Xin chào"])
    }

    func testGeminiResponseSkipsThoughts() throws {
        let json = #"{"candidates":[{"content":{"parts":[{"text":"hmm","thought":true},{"text":"{\"translations\":[\"Chào\"]}"}]}}]}"#
        XCTAssertEqual(try GeminiTranslator.extractText(Data(json.utf8)), #"{"translations":["Chào"]}"#)
    }

    func testDeepSeekResponse() throws {
        let json = #"{"choices":[{"message":{"role":"assistant","content":"{\"translations\":[\"Chào\"]}"}}]}"#
        XCTAssertEqual(try DeepSeekTranslator.extractText(Data(json.utf8)), #"{"translations":["Chào"]}"#)
    }

    func testOpenRouterResponseUsesChatFormat() throws {
        let json = #"{"id":"gen-1","model":"deepseek/deepseek-v4-flash","choices":[{"index":0,"message":{"role":"assistant","content":"{\"translations\":[\"Chào\"]}"}}]}"#
        XCTAssertEqual(try MangaPrompt.parse(try ChatCompletion.extractText(Data(json.utf8)), expected: 1), ["Chào"])
    }

    func testUserMessageIsValidJSON() throws {
        let message = MangaPrompt.userMessage(["Hi"], context: [TranslationPair(source: "Yo", target: "Chào")])
        let object = try JSONSerialization.jsonObject(with: Data(message.utf8)) as? [String: Any]
        XCTAssertEqual(object?["lines"] as? [String], ["Hi"])
    }

    func testCacheEvictsOldest() {
        var cache = TranslationCache(limit: 2)
        cache.set("a", engine: .google, key: "1")
        cache.set("b", engine: .google, key: "2")
        cache.set("c", engine: .google, key: "3")
        XCTAssertNil(cache.value(engine: .google, key: "1"))
        XCTAssertEqual(cache.value(engine: .google, key: "3"), "c")
        XCTAssertNil(cache.value(engine: .gemini, key: "3"))
        XCTAssertEqual(cache.count, 2)
    }
}

final class AppGroupTests: XCTestCase {
    func testReadsGroupsFromProvisioningProfile() {
        let plist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <plist version="1.0"><dict><key>Entitlements</key><dict>
        <key>com.apple.security.application-groups</key>
        <array><string>group.com.diepnt.mangatrans.ABC123</string></array>
        </dict></dict></plist>
        """
        var data = Data([0x30, 0x82, 0x01, 0xFF, 0x00])
        data.append(Data(plist.utf8))
        data.append(Data([0xA0, 0x00, 0x31]))
        XCTAssertEqual(AppGroup.appGroups(fromProvisioningProfile: data), ["group.com.diepnt.mangatrans.ABC123"])
        XCTAssertEqual(AppGroup.appGroups(fromProvisioningProfile: Data("garbage".utf8)), [])
    }

    func testPicksRenamedGroup() {
        let configured = "group.com.diepnt.mangatrans"
        XCTAssertEqual(AppGroup.pickIdentifier(from: ["group.other", "group.com.diepnt.mangatrans.XYZ"],
                                               configured: configured, isUsable: { _ in true }),
                       "group.com.diepnt.mangatrans.XYZ")
        XCTAssertEqual(AppGroup.pickIdentifier(from: ["group.x", configured], configured: configured, isUsable: { _ in true }),
                       configured)
        XCTAssertEqual(AppGroup.pickIdentifier(from: ["group.renamed"], configured: configured, isUsable: { _ in true }),
                       "group.renamed")
        XCTAssertEqual(AppGroup.pickIdentifier(from: ["*"], configured: configured, isUsable: { _ in true }), configured)
        XCTAssertEqual(AppGroup.pickIdentifier(from: [], configured: configured, isUsable: { _ in false }), configured)
    }
}

final class PiPRendererTests: XCTestCase {
    func testRendersBufferOfRequestedSize() throws {
        let content = PiPContent(entries: [
            PiPEntry(original: "I DON'T UNDERSTAND WHAT YOU'RE TRYING TO SAY.", translation: "Tôi không hiểu bạn đang muốn nói gì.", state: .done),
            PiPEntry(original: String(repeating: "VERY LONG TEXT ", count: 40), translation: "", state: .pending),
        ])
        let buffer = try XCTUnwrap(PiPRenderer.render(content, size: CGSize(width: 1080, height: 540), showOriginal: true, fontScale: 1))
        XCTAssertEqual(CVPixelBufferGetWidth(buffer), 1080)
        XCTAssertEqual(CVPixelBufferGetHeight(buffer), 540)
    }
}

final class BrowserTests: XCTestCase {
    func testAddressInputBecomesURL() {
        XCTAssertEqual(BrowserModel.url(from: "mangadex.org")?.absoluteString, "https://mangadex.org")
        XCTAssertEqual(BrowserModel.url(from: " https://example.com/a?b=1 ")?.absoluteString, "https://example.com/a?b=1")
        XCTAssertEqual(BrowserModel.url(from: "solo leveling chapter 1")?.host, "www.google.com")
        XCTAssertEqual(BrowserModel.url(from: "manga")?.host, "www.google.com")
        XCTAssertNil(BrowserModel.url(from: "   "))
    }
}

final class TextRecognizerTests: XCTestCase {
    /// Vẽ 2 bóng thoại lên ảnh, chạy OCR thật rồi gom nhóm — kiểm tra cả chuỗi xử lý của chế độ Trình duyệt.
    func testRecognizesAndGroupsRenderedBubbles() throws {
        let size = CGSize(width: 1000, height: 1400)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(size: size, format: format).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(origin: .zero, size: size))
            let paragraph = NSMutableParagraphStyle()
            paragraph.alignment = .center
            let attributes: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 44, weight: .bold),
                .foregroundColor: UIColor.black,
                .paragraphStyle: paragraph,
            ]
            ("I DON'T\nUNDERSTAND\nWHAT YOU'RE\nTRYING TO SAY." as NSString)
                .draw(in: CGRect(x: 100, y: 150, width: 420, height: 260), withAttributes: attributes)
            ("WHERE ARE\nYOU GOING?" as NSString)
                .draw(in: CGRect(x: 450, y: 900, width: 420, height: 140), withAttributes: attributes)
        }
        let cgImage = try XCTUnwrap(image.cgImage)
        let lines = try TextRecognizer.recognize(cgImage: cgImage, accuracy: .accurate)
        let blocks = TextGrouper.group(lines, imageSize: size)

        XCTAssertEqual(blocks.count, 2, "lines: \(lines.map(\.text))")
        XCTAssertEqual(blocks.first?.key, "i don t understand what you re trying to say")
        XCTAssertEqual(blocks.last?.key, "where are you going")
    }
}

/// Bộ dịch giả: đếm số lần gọi, trả về "VI:" + câu gốc sau một chút trễ.
private final class CountingTranslator: Translator {
    private let lock = NSLock()
    private var log: [[String]] = []
    /// Lô lớn hơn mức này: giả lập mô hình trả lệch số câu.
    var maxReliableBatch = Int.max

    init(maxReliableBatch: Int = .max) {
        self.maxReliableBatch = maxReliableBatch
    }
    var requests: [[String]] {
        lock.lock(); defer { lock.unlock() }
        return log
    }

    func translate(_ texts: [String], context: [TranslationPair]) async throws -> [String] {
        lock.lock()
        log.append(texts)
        lock.unlock()
        try await Task.sleep(nanoseconds: 50_000_000)
        if texts.count > maxReliableBatch { throw TranslatorError.invalidResponse }
        return texts.map { "VI:" + $0 }
    }
}

@MainActor
final class TranslationServiceTests: XCTestCase {
    private func block(_ text: String) -> TextBlock {
        TextGrouper.group([OCRLine(text: text, confidence: 1, x: 0.1, y: 0.1, w: 0.5, h: 0.02)],
                          imageSize: CGSize(width: 1000, height: 2000))[0]
    }

    func testPrefetchedBubbleIsNotTranslatedTwice() async throws {
        let fake = CountingTranslator()
        let service = TranslationService(makeTranslator: { _ in fake })
        let defaults = UserDefaults(suiteName: "tests")!
        defaults.set(true, forKey: SettingsKey.translationConsent)
        let settings = AppSettings.load(defaults)
        let a = block("HELLO THERE"), b = block("WHERE ARE YOU")

        // Đang cuộn: dịch trước A. Dừng lại: cần A và B ngay lúc A còn đang dịch.
        service.prefetch([a], settings: settings)
        await Task.yield()
        let results = try await service.translate([a, b], settings: settings)

        XCTAssertEqual(results, ["VI:Hello there", "VI:Where are you"])
        // Mỗi câu chỉ gửi đi đúng 1 lần.
        XCTAssertEqual(fake.requests.flatMap { $0 }.sorted(), ["Hello there", "Where are you"])

        // Lần sau lấy từ cache, không gọi bộ dịch nữa.
        _ = try await service.translate([b, a], settings: settings)
        XCTAssertEqual(fake.requests.count, 2)
    }

    private func aiSettings() -> AppSettings {
        let defaults = UserDefaults(suiteName: "tests-chapter")!
        defaults.set(true, forKey: SettingsKey.translationConsent)
        defaults.set(TranslatorEngine.gemini.rawValue, forKey: SettingsKey.engine)
        return AppSettings.load(defaults)
    }

    func testWholeChapterIsTranslatedInOneRequest() async throws {
        let fake = CountingTranslator()
        let service = TranslationService(makeTranslator: { _ in fake })
        let settings = aiSettings()
        let chapter = (1...40).map { block("LINE NUMBER \($0) OF THIS CHAPTER") }

        let count = try await service.translateChapter(chapter, settings: settings, conversation: "tab")
        XCTAssertEqual(count, 40)
        XCTAssertEqual(fake.requests.count, 1)

        // Cuộn tới: OCR trên màn hình đọc hơi khác (sai 1 từ) vẫn lấy bản dịch có sẵn, không gọi API.
        let onScreen = block("LINE NUMBER 7 OF THIS CHAPTEB")
        XCTAssertEqual(service.cached(onScreen, engine: settings.engine), "VI:Line number 7 of this chapter")
        _ = try await service.translate([onScreen], settings: settings, conversation: "tab")
        XCTAssertEqual(fake.requests.count, 1)

        // Đã dịch rồi thì gọi lại cũng không gửi nữa.
        let again = try await service.translateChapter(chapter, settings: settings, conversation: "tab")
        XCTAssertEqual(again, 0)
        XCTAssertEqual(fake.requests.count, 1)
    }

    func testBatchIsSplitWhenTranslatorLosesCount() async throws {
        let fake = CountingTranslator(maxReliableBatch: 4)
        let service = TranslationService(makeTranslator: { _ in fake })
        let chapter = (1...10).map { block("BUBBLE \($0) SAYS SOMETHING") }
        try await service.translateChapter(chapter, settings: aiSettings(), conversation: "split")
        for item in chapter {
            XCTAssertEqual(service.cached(item, engine: .gemini), "VI:" + item.translationInput)
        }
    }

    func testShortBubblesNeedExactMatch() {
        let words: (String) -> Set<String> = { Set($0.split(separator: " ").map(String.init)) }
        XCTAssertFalse(TranslationService.isSameText(words("no way"), words("no way out")))
        XCTAssertFalse(TranslationService.isSameText(words("what are you doing"), words("what are they planning tonight")))
        XCTAssertTrue(TranslationService.isSameText(words("where did you go"), words("where did you go yesterday")))
    }
}

final class ChapterTilingTests: XCTestCase {
    func testShortImageIsOneTile() {
        XCTAssertEqual(RecognitionJob.tiles(height: 1500, tileHeight: 1400),
                       [RecognitionJob.Tile(start: 0, end: 1500, ownStart: 0, ownEnd: 1500)])
    }

    func testLongStripTilesOverlapAndOwnEveryRowOnce() {
        let tiles = RecognitionJob.tiles(height: 10_000, tileHeight: 1400)
        XCTAssertGreaterThan(tiles.count, 7)
        XCTAssertEqual(tiles.first?.ownStart, 0)
        XCTAssertEqual(tiles.last?.ownEnd, 10_000)
        XCTAssertEqual(tiles.last?.end, 10_000)
        for (a, b) in zip(tiles, tiles.dropFirst()) {
            // Liền nhau, không hở, không trùng; ranh giới nằm trong phần chồng nhau.
            XCTAssertEqual(a.ownEnd, b.ownStart)
            XCTAssertGreaterThan(a.end - b.start, 300)
            XCTAssertGreaterThan(a.ownEnd, b.start)
            XCTAssertLessThan(a.ownEnd, a.end)
        }
    }
}

final class BubbleQueueTests: XCTestCase {
    private func block(_ text: String, y: Double) -> TextBlock {
        TextGrouper.group([OCRLine(text: text, confidence: 1, x: 0.1, y: y, w: 0.5, h: 0.02)],
                          imageSize: CGSize(width: 1000, height: 2000))[0]
    }

    private func page(scrolledBy dy: Double) -> [TextBlock] {
        [block("ONE", y: 0.15 - dy), block("TWO", y: 0.35 - dy), block("THREE", y: 0.55 - dy), block("FOUR", y: 0.75 - dy)]
            .filter { $0.rect.midY > 0 }
    }

    func testShowsTwoThenNextTwoAfterScrolling() {
        var queue = BubbleQueue()
        let first = queue.select(page(scrolledBy: 0), maxCount: 2)
        XCTAssertEqual(first.map(\.displayText), ["ONE", "TWO"])
        queue.markShown(first)

        // Chưa cuộn → giữ nguyên, không tự nhảy sang bóng khác.
        XCTAssertEqual(queue.select(page(scrolledBy: 0.005), maxCount: 2).map(\.displayText), ["ONE", "TWO"])

        // Cuộn xuống một chút → 2 bóng dưới.
        let next = queue.select(page(scrolledBy: 0.1), maxCount: 2)
        XCTAssertEqual(next.map(\.displayText), ["THREE", "FOUR"])
        queue.markShown(next)

        // Cuộn ngược lên đoạn đã đọc → hiện lại đoạn đó.
        XCTAssertEqual(queue.select(page(scrolledBy: -0.05).prefix(2).map { $0 }, maxCount: 2).map(\.displayText),
                       ["ONE", "TWO"])
    }

    func testRespectsMaxCount() {
        let queue = BubbleQueue()
        XCTAssertEqual(queue.select(page(scrolledBy: 0), maxCount: 3).count, 3)
        XCTAssertEqual(queue.select(page(scrolledBy: 0), maxCount: 0).count, 1)
    }
}

final class PanelLayoutTests: XCTestCase {
    private let container = CGSize(width: 390, height: 600)

    func testClampKeepsPanelInsideAndAboveMinimum() {
        let dragged = PanelLayout.clamp(CGRect(x: 300, y: 580, width: 50, height: 20), in: container)
        XCTAssertEqual(dragged.size, PanelLayout.minSize)
        XCTAssertEqual(dragged.maxX, 390)
        XCTAssertEqual(dragged.maxY, 600)

        let huge = PanelLayout.clamp(CGRect(x: -40, y: -10, width: 900, height: 900), in: container)
        XCTAssertEqual(huge, CGRect(x: 0, y: 0, width: 390, height: 600))
    }

    func testFractionRoundTrip() {
        let frame = CGRect(x: 97.5, y: 150, width: 292.5, height: 150)
        let fraction = PanelLayout.fraction(of: frame, in: container)
        XCTAssertEqual(PanelLayout.frame(from: fraction, in: container), frame)
    }
}

final class FrameFingerprintTests: XCTestCase {
    private func buffer(fill: UInt8, stripeAt stripe: Int? = nil) -> CVPixelBuffer {
        var pixelBuffer: CVPixelBuffer?
        CVPixelBufferCreate(nil, 120, 240, kCVPixelFormatType_32BGRA, nil, &pixelBuffer)
        let buffer = pixelBuffer!
        CVPixelBufferLockBaseAddress(buffer, [])
        let base = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        for y in 0..<240 {
            let value: UInt8 = (stripe.map { y >= $0 && y < $0 + 60 } ?? false) ? 255 : fill
            for x in 0..<120 * 4 { base[y * bytesPerRow + x] = value }
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        return buffer
    }

    func testStillScreenIsDetectedAsUnchanged() throws {
        let a = try XCTUnwrap(FrameFingerprint(pixelBuffer: buffer(fill: 40)))
        let b = try XCTUnwrap(FrameFingerprint(pixelBuffer: buffer(fill: 40)))
        XCTAssertEqual(a.samples.count, FrameFingerprint.columns * FrameFingerprint.rows)
        XCTAssertLessThan(a.difference(to: b), 1.5)
    }

    func testScrolledScreenIsDetectedAsChanged() throws {
        let a = try XCTUnwrap(FrameFingerprint(pixelBuffer: buffer(fill: 40, stripeAt: 20)))
        let b = try XCTUnwrap(FrameFingerprint(pixelBuffer: buffer(fill: 40, stripeAt: 120)))
        XCTAssertGreaterThan(a.difference(to: b), 1.5)
    }
}

@MainActor
final class PrivacyAndSecurityTests: XCTestCase {
    func testTranslationRequiresConsent() async {
        let defaults = UserDefaults(suiteName: "tests-no-consent")!
        defaults.set(false, forKey: SettingsKey.translationConsent)
        let service = TranslationService(makeTranslator: { _ in CountingTranslator() })
        let block = TextGrouper.group([OCRLine(text: "HELLO", confidence: 1, x: 0.1, y: 0.1, w: 0.3, h: 0.02)],
                                      imageSize: CGSize(width: 1000, height: 2000))
        do {
            _ = try await service.translate(block, settings: AppSettings.load(defaults))
            XCTFail("Không được dịch khi chưa đồng ý")
        } catch {
            XCTAssertEqual((error as? TranslatorError)?.errorDescription, TranslatorError.consentRequired.errorDescription)
        }
    }

    func testBrowserOnlyOpensWebLinks() {
        XCTAssertTrue(BrowserModel.isAllowedNavigation(URL(string: "https://example.com")))
        XCTAssertTrue(BrowserModel.isAllowedNavigation(URL(string: "about:blank")))
        XCTAssertFalse(BrowserModel.isAllowedNavigation(URL(string: "tel:123456")))
        XCTAssertFalse(BrowserModel.isAllowedNavigation(URL(string: "itms-apps://apps.apple.com/app/id1")))
        XCTAssertFalse(BrowserModel.isAllowedNavigation(URL(string: "file:///etc/passwd")))
    }
}

final class BubbleFilterTests: XCTestCase {
    private func block(_ text: String, confidence: Float = 0.95, rect: CGRect = CGRect(x: 0.3, y: 0.3, width: 0.4, height: 0.04)) -> TextBlock {
        TextGrouper.group([OCRLine(text: text, confidence: confidence, x: Double(rect.minX), y: Double(rect.minY),
                                   w: Double(rect.width), h: Double(rect.height))],
                          imageSize: CGSize(width: 200, height: 400))[0]
    }

    private func image(_ value: (Int, Int) -> UInt8) -> LuminanceImage {
        var pixels: [UInt8] = []
        for y in 0..<400 { for x in 0..<200 { pixels.append(value(x, y)) } }
        return LuminanceImage(width: 200, height: 400, pixels: pixels)
    }

    private func line(_ text: String, _ rect: CGRect) -> OCRLine {
        OCRLine(text: text, confidence: 0.95, x: Double(rect.minX), y: Double(rect.minY),
                w: Double(rect.width), h: Double(rect.height))
    }

    private func contains(_ rect: CGRect, _ x: Int, _ y: Int) -> Bool {
        rect.contains(CGPoint(x: (Double(x) + 0.5) / 200, y: (Double(y) + 0.5) / 400))
    }

    func testMultiLineBubbleIsKept() {
        // Bóng thoại trắng, 2 dòng chữ đen sát nhau.
        let first = CGRect(x: 0.3, y: 0.30, width: 0.4, height: 0.03)
        let second = CGRect(x: 0.3, y: 0.34, width: 0.4, height: 0.03)
        let bubble = image { x, y in self.contains(first, x, y) || self.contains(second, x, y) ? 0 : 255 }
        let kept = BubbleFilter.linesOnPlainBackground([line("BOTH OF", first), line("YOU HAVE GREAT", second)], in: bubble)
        XCTAssertEqual(kept.map(\.text), ["BOTH OF", "YOU HAVE GREAT"])
    }

    func testTextOverArtworkNextToBubbleIsDropped() {
        // Nửa trái là bóng thoại trắng, nửa phải là tranh (nền lổn nhổn) có chữ "Hahaha!" vẽ đè.
        var seed: UInt32 = 12345
        let page = image { x, _ in
            if x < 100 { return 255 }
            seed = seed &* 1_103_515_245 &+ 12345
            return UInt8(truncatingIfNeeded: seed >> 16)
        }
        let dialogue = line("BOTH OF YOU", CGRect(x: 0.1, y: 0.4, width: 0.3, height: 0.03))
        let effect = line("Hahaha!", CGRect(x: 0.62, y: 0.4, width: 0.25, height: 0.03))
        XCTAssertEqual(BubbleFilter.linesOnPlainBackground([dialogue, effect], in: page).map(\.text), ["BOTH OF YOU"])
    }

    func testNoiseText() {
        XCTAssertTrue(BubbleFilter.isNoise(block("REAPERSCANS.COM")))
        XCTAssertTrue(BubbleFilter.isNoise(block("www.mangaread.org")))
        XCTAssertTrue(BubbleFilter.isNoise(block("TINg")))
        XCTAssertTrue(BubbleFilter.isNoise(block("NO", confidence: 0.4)))
        XCTAssertFalse(BubbleFilter.isNoise(block("WHAT?!")))
        XCTAssertFalse(BubbleFilter.isNoise(block("SCAN THE AREA NOW")))
        XCTAssertFalse(BubbleFilter.isNoise(block("I WANTED...TO SEE YOU AGAIN.")))
        XCTAssertFalse(BubbleFilter.isNoise(block("...WHO TOLD YOU TO LEAVE THEM ALONE LIKE THAT?")))
    }
}

final class BubbleQueueFuzzyTests: XCTestCase {
    private func block(_ text: String, y: Double) -> TextBlock {
        TextGrouper.group([OCRLine(text: text, confidence: 1, x: 0.1, y: y, w: 0.5, h: 0.02)],
                          imageSize: CGSize(width: 1000, height: 2000))[0]
    }

    func testSlightlyDifferentOcrCountsAsAlreadyShown() {
        var queue = BubbleQueue()
        let first = queue.select([block("BOTH OF YOU HAVE GREAT FOCUS.", y: 0.4)], maxCount: 1)
        queue.markShown(first)

        // Cuộn xuống: OCR đọc thêm "Hahaha!" vào bóng cũ, bóng mới hiện ra bên dưới.
        let next = queue.select([
            block("Hahaha! BOTH OF YOU HAVE GREAT FOCUS.", y: 0.25),
            block("AS EXPECTED OF THE TEAM LEADERS WHO PASSED THE SECOND TEST.", y: 0.55),
        ], maxCount: 1)
        XCTAssertEqual(next.map(\.displayText), ["AS EXPECTED OF THE TEAM LEADERS WHO PASSED THE SECOND TEST."])
    }

    func testShortBubblesAreNotMatchedLoosely() {
        XCTAssertFalse(BubbleQueue.isSameBubble(["no"], ["no", "way"]))
        XCTAssertTrue(BubbleQueue.isSameBubble(["both", "of", "you", "have"], ["hahaha", "both", "of", "you", "have"]))
    }
}

final class SpeechTests: XCTestCase {
    func testGoogleSpeechChunksStayUnderLimit() {
        let long = Array(repeating: "This is a fairly long sentence for the speech engine.", count: 10).joined(separator: " ")
        let chunks = GoogleSpeech.chunk(long)
        XCTAssertGreaterThan(chunks.count, 1)
        XCTAssertTrue(chunks.allSatisfy { $0.count <= GoogleSpeech.maxChunkLength })
        XCTAssertEqual(chunks.joined(separator: " "), long)
        XCTAssertEqual(GoogleSpeech.chunk("Hey! Wait."), ["Hey! Wait."])
    }

    func testOnlyMP3IsAcceptedFromGoogle() {
        XCTAssertTrue(GoogleSpeech.isMP3(Data("ID3".utf8) + Data(count: 400)))
        XCTAssertTrue(GoogleSpeech.isMP3(Data([0xFF, 0xF3, 0x44]) + Data(count: 400)))
        XCTAssertFalse(GoogleSpeech.isMP3(Data(("<html>" + String(repeating: " ", count: 400)).utf8)))
    }
}
