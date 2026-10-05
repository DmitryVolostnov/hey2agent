import AVFoundation
import NaturalLanguage
import Observation

/// Reads summaries aloud on the iPhone (the Mac stays silent while the phone is connected).
@MainActor @Observable
final class Speaker: NSObject, AVSpeechSynthesizerDelegate {
    var enabled = UserDefaults.standard.object(forKey: "readAloud") as? Bool ?? true {
        didSet { UserDefaults.standard.set(enabled, forKey: "readAloud"); if !enabled { stop() } }
    }
    var speaking = false
    /// Start recording on the phone right after the summary was read (like the Mac does).
    var listenAfter = UserDefaults.standard.object(forKey: "listenAfter") as? Bool ?? true {
        didSet { UserDefaults.standard.set(listenAfter, forKey: "listenAfter") }
    }
    /// Speech speed multiplier; iOS's default rate is noticeably slower than the Mac's `say -r 200`.
    static let speeds: [Double] = [1, 1.25, 1.5, 1.75]
    var speed = UserDefaults.standard.object(forKey: "speechSpeed") as? Double ?? 1.5 {
        didSet { UserDefaults.standard.set(speed, forKey: "speechSpeed") }
    }
    /// The utterance rate scale is non-linear (0.5 = default, 1 = max), so the steps are small.
    private var rate: Float { Float(AVSpeechUtteranceDefaultSpeechRate) + Float(speed - 1) * 0.16 }
    /// Called when an utterance finished on its own (not when stopped).
    var onFinished: (() -> Void)?
    private let synth = AVSpeechSynthesizer()
    private var lastSpoken: String?

    override init() {
        super.init()
        synth.delegate = self
    }

    /// Speak once per summary. The key must not be the state timestamp: cancelling a phone
    /// recording puts the Mac back into «reading» with a new timestamp, which re-read the summary
    /// (and then auto-started recording again).
    func speakOnce(_ text: String, key: String) {
        guard enabled, lastSpoken != key, !text.isEmpty else { return }
        lastSpoken = key
        speak(text)
    }

    /// «Read aloud» button: always speaks, doesn't touch the once-per-summary bookkeeping.
    func speak(_ text: String) {
        guard !text.isEmpty else { return }
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
        try? AVAudioSession.sharedInstance().setActive(true)
        let u = AVSpeechUtterance(string: text)
        let lang = Self.voiceLanguage(for: text)
        u.voice = AVSpeechSynthesisVoice(language: lang)
        u.rate = min(rate, AVSpeechUtteranceMaximumSpeechRate)
        synth.stopSpeaking(at: .immediate)
        synth.speak(u)
        speaking = true
    }

    /// Any Cyrillic → a Russian/Ukrainian voice (an English voice can't read Russian; a Russian
    /// one copes with English terms). Otherwise the dominant language.
    static func voiceLanguage(for text: String) -> String {
        let cyr = text.unicodeScalars.filter { (0x0400...0x04FF).contains($0.value) }
        if cyr.count >= 2 {
            let uk = cyr.filter { "іїєґІЇЄҐ".unicodeScalars.contains($0) }.count
            let ru = cyr.filter { "ыэъёЫЭЪЁ".unicodeScalars.contains($0) }.count
            return uk > ru ? "uk-UA" : "ru-RU"
        }
        return NLLanguageRecognizer.dominantLanguage(for: text)?.rawValue ?? Locale.current.identifier
    }

    func stop() {
        synth.stopSpeaking(at: .immediate)
        speaking = false
    }

    nonisolated func speechSynthesizer(_ s: AVSpeechSynthesizer, didFinish u: AVSpeechUtterance) {
        Task { @MainActor in
            self.speaking = false
            if self.listenAfter { self.onFinished?() }
        }
    }
    nonisolated func speechSynthesizer(_ s: AVSpeechSynthesizer, didCancel u: AVSpeechUtterance) {
        Task { @MainActor in self.speaking = false }
    }
}
