import XCTest
import CoreVideo
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

    func testLLMJsonWithCodeFence() throws {
        let content = "```json\n{\"translations\": [\"Một\", \"Hai\"]}\n```"
        XCTAssertEqual(try MangaPrompt.parse(content, expected: 2), ["Một", "Hai"])
    }

    func testLLMCountMismatchIsPadded() throws {
        XCTAssertEqual(try MangaPrompt.parse(#"{"translations": ["Một"]}"#, expected: 2), ["Một", "(?)"])
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
