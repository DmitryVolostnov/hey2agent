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
    private var lastSpoken: Double?

    override init() {
        super.init()
        synth.delegate = self
    }

    /// Speak once per conversation step (keyed by the step timestamp).
    func speakOnce(_ text: String, key: Double) {
        guard enabled, lastSpoken != key, !text.isEmpty else { return }
        lastSpoken = key
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
        try? AVAudioSession.sharedInstance().setActive(true)
        let u = AVSpeechUtterance(string: text)
        let lang = NLLanguageRecognizer.dominantLanguage(for: text)?.rawValue ?? Locale.current.identifier
        u.voice = AVSpeechSynthesisVoice(language: lang)
        u.rate = min(rate, AVSpeechUtteranceMaximumSpeechRate)
        synth.stopSpeaking(at: .immediate)
        synth.speak(u)
        speaking = true
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
