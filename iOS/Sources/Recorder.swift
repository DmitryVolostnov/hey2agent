import AVFoundation
import Observation

/// Records on the iPhone mic until a pause after speech (same rules as the Mac: calibrate the
/// room, speech = 12 dB above it, 2 s of quiet ends it). Produces a small AAC file.
@MainActor @Observable
final class Recorder {
    var level: Double = 0
    var speaking = false
    var secondsLeft: Double?
    var active = false

    private var recorder: AVAudioRecorder?
    private var timer: Task<Void, Never>?
    private var onFinish: ((Data?) -> Void)?
    private let url = FileManager.default.temporaryDirectory.appendingPathComponent("voice-loop.m4a")
    private var holdUntil = Date.distantPast

    /// The user is reading (scrolling the answer): don't give up on silence for a moment.
    func hold() { holdUntil = Date().addingTimeInterval(1.5) }

    func start(waitForSpeech: Double = 8, onFinish: @escaping (Data?) -> Void) {
        guard !active else { return }
        self.onFinish = onFinish
        AVAudioApplication.requestRecordPermission { granted in
            Task { @MainActor in
                granted ? self.begin(wait: waitForSpeech) : onFinish(nil)
            }
        }
    }

    private func begin(wait initialWait: Double) {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.record, mode: .measurement)
        try? session.setActive(true)
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 16000,
            AVNumberOfChannelsKey: 1, AVEncoderAudioQualityKey: AVAudioQuality.medium.rawValue,
        ]
        guard let r = try? AVAudioRecorder(url: url, settings: settings) else { onFinish?(nil); return }
        r.isMeteringEnabled = true
        r.record()
        recorder = r
        active = true
        speaking = false
        let started = Date()
        timer = Task { [weak self] in
            var wait = initialWait
            var calib: [Float] = []
            var floor: Float = -60
            var loudRun = 0
            var quiet = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(100))
                guard let self, let r = self.recorder else { return }
                r.updateMeters()
                let db = r.averagePower(forChannel: 0)
                if calib.count < 5 {
                    calib.append(db)
                    if calib.count == 5 { floor = max(calib.sorted()[2], -60) }
                    continue
                }
                self.level = Double(max(0, min(1, (db - floor) / 30)))
                let loud = db > floor + 12
                let t = Date().timeIntervalSince(started)
                if !self.speaking {
                    loudRun = loud ? loudRun + 1 : 0
                    let holding = Date() < self.holdUntil
                    if holding { wait = max(wait, t + 2) }
                    self.secondsLeft = holding ? nil : max(0, wait - t)
                    if loudRun >= 3 { self.speaking = true; self.secondsLeft = nil }
                    else if t > wait { self.finish(send: false); return }
                } else {
                    quiet = loud ? 0 : quiet + 1
                    if quiet >= 20 || t > 90 { self.finish(send: true); return }
                }
            }
        }
    }

    /// send=false discards the recording.
    func finish(send: Bool) {
        guard active else { return }
        timer?.cancel()
        recorder?.stop()
        recorder = nil
        active = false
        level = 0
        try? AVAudioSession.sharedInstance().setActive(false)
        let data = send && speaking ? try? Data(contentsOf: url) : nil
        let done = onFinish
        onFinish = nil
        done?(data)
    }
}
