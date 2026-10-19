import AVFoundation

/// Đọc to câu tiếng Anh của bóng thoại bằng giọng có sẵn trên máy (không cần mạng, không gửi dữ liệu đi).
@MainActor
final class SpeechReader: NSObject, ObservableObject {
    static let shared = SpeechReader()

    @Published private(set) var isSpeaking = false

    private let synthesizer = AVSpeechSynthesizer()
    private var pending = 0

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
        // Chữ IN HOA của truyện → câu thường, để máy không đánh vần từng chữ cái.
        let sentences = texts.map(TextNormalizer.translationInput).filter { !$0.isEmpty }
        guard !sentences.isEmpty else { return }
        synthesizer.stopSpeaking(at: .immediate)

        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
        try? session.setActive(true)

        let voice = Self.bestVoice
        pending = sentences.count
        for sentence in sentences {
            let utterance = AVSpeechUtterance(string: sentence)
            utterance.voice = voice
            utterance.rate = AVSpeechUtteranceDefaultSpeechRate * 0.95
            utterance.postUtteranceDelay = 0.25
            synthesizer.speak(utterance)
        }
        isSpeaking = true
    }

    func stop() {
        synthesizer.stopSpeaking(at: .immediate)
        finish()
    }

    private func utteranceEnded() {
        pending = max(0, pending - 1)
        if pending == 0 { finish() }
    }

    private func finish() {
        pending = 0
        isSpeaking = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    /// Ưu tiên giọng tiếng Anh chất lượng cao nhất máy đang có.
    private static var bestVoice: AVSpeechSynthesisVoice? {
        let english = AVSpeechSynthesisVoice.speechVoices().filter { $0.language.hasPrefix("en") }
        let preferred = english.filter { $0.language == "en-US" }
        let pool = preferred.isEmpty ? english : preferred
        return pool.max { $0.quality.rawValue < $1.quality.rawValue }
            ?? AVSpeechSynthesisVoice(language: "en-US")
    }
}

extension SpeechReader: AVSpeechSynthesizerDelegate {
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in self.utteranceEnded() }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in self.utteranceEnded() }
    }
}
