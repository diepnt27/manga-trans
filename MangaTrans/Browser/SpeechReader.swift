import AVFoundation

/// Giọng đọc của nút loa.
enum SpeechEngine: String, CaseIterable, Identifiable {
    /// Giọng của Google Dịch (cần mạng) — tự nhiên, giống nút loa trên Google Dịch.
    case google
    /// Giọng tiếng Anh có sẵn trên iPhone (không cần mạng, không gửi dữ liệu đi).
    case system

    var id: String { rawValue }

    var title: String {
        switch self {
        case .google: return "Google Dịch (online)"
        case .system: return "Giọng iPhone"
        }
    }

    /// Bản App Store bỏ giọng Google (endpoint web không chính thức), như bộ dịch Google miễn phí.
    static var available: [SpeechEngine] {
        #if APPSTORE
        return [.system]
        #else
        return allCases
        #endif
    }

    static var defaultEngine: SpeechEngine { available[0] }
}

enum SpeechSettingsKey {
    static let engine = "speechEngine"
    /// Định danh giọng iPhone; rỗng = tự chọn giọng tốt nhất.
    static let voice = "speechVoice"
    /// Tốc độ đọc (1 = bình thường).
    static let rate = "speechRate"
}

/// Đọc to câu tiếng Anh của bóng thoại.
@MainActor
final class SpeechReader: NSObject, ObservableObject {
    static let shared = SpeechReader()

    @Published private(set) var isSpeaking = false

    private let synthesizer = AVSpeechSynthesizer()
    /// Các câu đang đọc bằng giọng iPhone (bỏ qua sự kiện "huỷ" của lần đọc trước).
    private var utterances: Set<ObjectIdentifier> = []
    private var clips: [Data] = []
    private var player: AVAudioPlayer?
    private var loadTask: Task<Void, Never>?
    private var rate: Double = 1

    private override init() {
        super.init()
        synthesizer.delegate = self
    }

    /// Đang đọc → dừng; không thì đọc lần lượt các câu.
    func toggle(_ texts: [String]) {
        if isSpeaking {
            stop()
        } else {
            speak(texts)
        }
    }

    func speak(_ texts: [String]) {
        stop()
        // Chữ IN HOA của truyện → câu thường, để máy không đánh vần từng chữ cái.
        let sentences = texts.map(TextNormalizer.translationInput).filter { !$0.isEmpty }
        guard !sentences.isEmpty else { return }

        let defaults = UserDefaults.standard
        let engine = SpeechEngine.available.first { $0.rawValue == defaults.string(forKey: SpeechSettingsKey.engine) }
            ?? SpeechEngine.defaultEngine
        rate = min(1.5, max(0.6, defaults.object(forKey: SpeechSettingsKey.rate) as? Double ?? 1))

        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
        try? session.setActive(true)
        isSpeaking = true

        switch engine {
        case .system:
            speakWithSystemVoice(sentences)
        case .google:
            loadTask = Task { [weak self] in
                do {
                    let clips = try await GoogleSpeech.clips(for: sentences.joined(separator: " "))
                    guard let self, !Task.isCancelled else { return }
                    self.clips = clips
                    self.playNextClip()
                } catch {
                    // Mất mạng / Google chặn → đọc bằng giọng iPhone.
                    guard let self, !Task.isCancelled else { return }
                    self.speakWithSystemVoice(sentences)
                }
            }
        }
    }

    func stop() {
        loadTask?.cancel()
        loadTask = nil
        clips = []
        player?.stop()
        player = nil
        if synthesizer.isSpeaking { synthesizer.stopSpeaking(at: .immediate) }
        finish()
    }

    // MARK: - Google Dịch

    private func playNextClip() {
        guard !clips.isEmpty else {
            finish()
            return
        }
        let data = clips.removeFirst()
        guard let player = try? AVAudioPlayer(data: data) else {
            playNextClip()
            return
        }
        player.delegate = self
        player.enableRate = true
        player.rate = Float(rate)
        self.player = player
        player.play()
    }

    // MARK: - Giọng iPhone

    private func speakWithSystemVoice(_ sentences: [String]) {
        let voice = Self.voice(withIdentifier: UserDefaults.standard.string(forKey: SpeechSettingsKey.voice) ?? "")
        for sentence in sentences {
            let utterance = AVSpeechUtterance(string: sentence)
            utterance.voice = voice
            utterance.rate = min(AVSpeechUtteranceMaximumSpeechRate,
                                 AVSpeechUtteranceDefaultSpeechRate * Float(rate))
            utterance.postUtteranceDelay = 0.2
            utterances.insert(ObjectIdentifier(utterance))
            synthesizer.speak(utterance)
        }
    }

    private func utteranceEnded(_ id: ObjectIdentifier) {
        guard utterances.remove(id) != nil else { return }
        if utterances.isEmpty { finish() }
    }

    private func finish() {
        utterances = []
        guard isSpeaking else { return }
        isSpeaking = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    /// Giọng tiếng Anh dùng được: bỏ giọng "vui" (Zarvox, Bahh...), giọng robot Eloquence (Eddy, Grandpa...)
    /// và giọng cá nhân. Xếp theo chất lượng: Cao cấp → Nâng cao → Thường; cùng mức thì giọng Mỹ trước.
    static func englishVoices() -> [AVSpeechSynthesisVoice] {
        AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language.hasPrefix("en") && !isNovelty($0) }
            .sorted { a, b in
                if a.quality != b.quality { return a.quality.rawValue > b.quality.rawValue }
                if (a.language == "en-US") != (b.language == "en-US") { return a.language == "en-US" }
                return a.name < b.name
            }
    }

    static func isNovelty(_ voice: AVSpeechSynthesisVoice) -> Bool {
        if #available(iOS 17.0, *) {
            if voice.voiceTraits.contains(.isNoveltyVoice) || voice.voiceTraits.contains(.isPersonalVoice) { return true }
        }
        let id = voice.identifier.lowercased()
        return id.contains("speech.synthesis.voice") || id.contains("eloquence")
    }

    /// Giọng đã chọn; chưa chọn (hoặc đã bị xoá khỏi máy) thì lấy giọng tốt nhất, ưu tiên Samantha khi chỉ có giọng thường.
    static func voice(withIdentifier identifier: String) -> AVSpeechSynthesisVoice? {
        if !identifier.isEmpty, let chosen = AVSpeechSynthesisVoice(identifier: identifier) { return chosen }
        let voices = englishVoices()
        if let best = voices.first, best.quality != .default { return best }
        return voices.first { $0.name == "Samantha" } ?? voices.first ?? AVSpeechSynthesisVoice(language: "en-US")
    }

    static func qualityLabel(_ voice: AVSpeechSynthesisVoice) -> String {
        switch voice.quality {
        case .premium: return "Cao cấp"
        case .enhanced: return "Nâng cao"
        default: return "Thường"
        }
    }
}

extension SpeechReader: AVSpeechSynthesizerDelegate {
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        let id = ObjectIdentifier(utterance)
        Task { @MainActor in self.utteranceEnded(id) }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        let id = ObjectIdentifier(utterance)
        Task { @MainActor in self.utteranceEnded(id) }
    }
}

extension SpeechReader: AVAudioPlayerDelegate {
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        let id = ObjectIdentifier(player)
        Task { @MainActor in
            guard let current = self.player, ObjectIdentifier(current) == id else { return }
            self.playNextClip()
        }
    }
}

/// Giọng đọc của Google Dịch (endpoint web không chính thức, giống bộ dịch Google miễn phí).
enum GoogleSpeech {
    /// Google chỉ nhận khoảng 200 ký tự mỗi lần.
    static let maxChunkLength = 180

    /// Tải âm thanh (MP3) cho từng đoạn, song song; trả về theo đúng thứ tự.
    static func clips(for text: String) async throws -> [Data] {
        let chunks = chunk(text)
        return try await withThrowingTaskGroup(of: (Int, Data).self) { group in
            for (index, piece) in chunks.enumerated() {
                group.addTask { (index, try await download(piece)) }
            }
            var results = [Data?](repeating: nil, count: chunks.count)
            for try await (index, data) in group { results[index] = data }
            return results.compactMap { $0 }
        }
    }

    private static func download(_ text: String) async throws -> Data {
        var components = URLComponents(string: "https://translate.google.com/translate_tts")!
        components.queryItems = [
            URLQueryItem(name: "ie", value: "UTF-8"),
            URLQueryItem(name: "client", value: "tw-ob"),
            URLQueryItem(name: "tl", value: "en"),
            URLQueryItem(name: "q", value: text),
        ]
        components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        let data = try await HTTP.send(URLRequest(url: components.url!, timeoutInterval: 10))
        // Bị chặn thì Google trả về trang HTML thay vì âm thanh.
        guard isMP3(data) else { throw TranslatorError.invalidResponse }
        return data
    }

    /// Tệp MP3: bắt đầu bằng thẻ ID3 hoặc khung MPEG (0xFFEx/0xFFFx).
    static func isMP3(_ data: Data) -> Bool {
        let bytes = [UInt8](data.prefix(3))
        guard data.count > 200, bytes.count == 3 else { return false }
        return bytes == Array("ID3".utf8) || (bytes[0] == 0xFF && bytes[1] & 0xE0 == 0xE0)
    }

    /// Cắt theo câu, gộp lại thành các đoạn ≤ `maxChunkLength` ký tự; câu quá dài thì cắt theo từ.
    static func chunk(_ text: String) -> [String] {
        var sentences: [String] = []
        var current = ""
        for character in text {
            current.append(character)
            if ".!?…".contains(character) {
                sentences.append(current)
                current = ""
            }
        }
        sentences.append(current)

        var pieces: [String] = []
        var piece = ""
        func push(_ part: String) {
            let part = part.trimmingCharacters(in: .whitespaces)
            guard !part.isEmpty else { return }
            if piece.isEmpty {
                piece = part
            } else if piece.count + 1 + part.count <= maxChunkLength {
                piece += " " + part
            } else {
                pieces.append(piece)
                piece = part
            }
        }
        for sentence in sentences {
            if sentence.count <= maxChunkLength {
                push(sentence)
            } else {
                sentence.split(separator: " ").forEach { push(String($0)) }
            }
        }
        if !piece.isEmpty { pieces.append(piece) }
        return pieces
    }
}
