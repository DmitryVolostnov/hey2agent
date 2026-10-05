import Foundation
import Network
import Observation
import VoiceLoopLink

/// Finds the Mac over Bonjour, connects with the pairing code, mirrors its HUD.
@MainActor @Observable
final class RemoteModel {
    enum Status: Equatable { case searching, connecting, connected, badCode, lost }

    var macs: [NWBrowser.Result] = []
    var status: Status = .searching
    var snapshot: LinkSnapshot?
    var code = UserDefaults.standard.string(forKey: "code") ?? ""
    var macName = UserDefaults.standard.string(forKey: "mac")

    private var browser: NWBrowser?
    private var link: LinkConnection?
    private var retry: Task<Void, Never>?
    private var lastMessage = Date()
    private var watchdog: Task<Void, Never>?

    var paired: Bool { macName != nil && code.count == 6 }

    func start() {
        // After the phone read a summary aloud, listen for the answer (same flow as on the Mac).
        speaker.onFinished = { [weak self] in
            guard let self, self.snapshot?.active?.state == "reading", !self.recorder.active else { return }
            self.recordOnPhone(for: nil)
        }
        startBrowser()
        guard watchdog == nil else { return }
        // Every 5 s: ping the Mac; reconnect when there is no link (after a failure, coming back
        // from the background…); drop a link that went silent for 15 s.
        watchdog = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                guard let self, !self.inBackground else { continue }
                if self.status == .connected { self.send(.ping) }
                if self.link == nil {
                    self.autoConnect()
                } else if self.status == .connected, Date().timeIntervalSince(self.lastMessage) > 15 {
                    self.link?.cancel()
                    self.link = nil
                    self.status = .lost
                    self.autoConnect()
                }
            }
        }
    }

    private func startBrowser() {
        browser?.cancel()
        let b = NWBrowser(for: .bonjour(type: VoiceLoopLink.serviceType, domain: nil), using: .tcp)
        b.browseResultsChangedHandler = { [weak self] results, _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.macs = Array(results)
                self.autoConnect()
            }
        }
        b.start(queue: .main)
        browser = b
    }

    static func name(_ r: NWBrowser.Result) -> String {
        if case let .service(name, _, _, _) = r.endpoint { return name }
        return "\(r.endpoint)"
    }

    private func autoConnect() {
        guard paired, link == nil, status != .badCode,
              let r = macs.first(where: { Self.name($0) == macName }) else { return }
        connect(r)
    }

    func pair(_ r: NWBrowser.Result, code: String) {
        self.code = code
        macName = Self.name(r)
        status = .searching
        connect(r)
    }

    func unpair() {
        link?.cancel()
        link = nil
        macName = nil
        snapshot = nil
        status = .searching
        UserDefaults.standard.removeObject(forKey: "mac")
    }

    private func connect(_ r: NWBrowser.Result) {
        link?.cancel()
        status = .connecting
        let c = LinkConnection(NWConnection(to: r.endpoint, using: VoiceLoopLink.parameters(code: code)))
        c.onState = { [weak self, weak c] state in
            guard let self, let c, c === self.link else { return }
            switch state {
            case .ready:
                self.status = .connected
                self.lastMessage = Date()
                UserDefaults.standard.set(self.code, forKey: "code")
                UserDefaults.standard.set(self.macName, forKey: "mac")
            case .failed(let err), .waiting(let err):
                if case .tls = err, self.snapshot == nil {
                    self.status = .badCode  // PSK mismatch: wrong pairing code
                } else {
                    self.status = .lost
                }
                self.link?.cancel()
                self.link = nil
                self.scheduleRetry()
            case .cancelled:
                break
            default:
                break
            }
        }
        c.onEnvelope = { [weak self] env in
            self?.lastMessage = Date()
            if let s = env.snapshot, s != self?.snapshot {
                self?.snapshot = s
                // The Mac is silent while the phone is connected: read the summary here.
                if let a = s.active, a.state == "reading", let text = a.summary {
                    self?.speaker.speakOnce(text, key: "\(a.session_id ?? a.project ?? "")|\(text)")
                }
            }
        }
        link = c
        c.start()
    }

    private func scheduleRetry() {
        guard status != .badCode else { return }
        retry?.cancel()
        retry = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            self?.autoConnect()
        }
    }

    let recorder = Recorder()
    let speaker = Speaker()
    /// Which chat the phone is recording for; nil while recording = answer to the running conversation.
    var recordingFor: LinkSession?
    var recordingTitle = ""
    var micDenied = false

    private var cancelAll = false
    private var holdSent = Date.distantPast

    /// Scrolling the answer: the phone mic (or the Mac's) keeps waiting instead of giving up.
    func readingHold() {
        if recorder.active { recorder.hold() }
        guard snapshot?.active?.state == "listening", Date().timeIntervalSince(holdSent) > 0.4 else { return }
        holdSent = Date()
        send(.control("hover"))
    }

    /// Stop recording for the running conversation and cancel that conversation entirely.
    func cancelConversation() {
        speaker.stop()
        if recorder.active && recordingFor == nil {
            cancelAll = true
            recorder.finish(send: false)
        } else {
            send(.control("cancel"))
        }
    }

    /// Record on the phone and send the audio to the Mac.
    func recordOnPhone(for session: LinkSession?) {
        guard !recorder.active else { return }
        recordingFor = session
        recordingTitle = session?.title ?? snapshot?.active?.project ?? ""
        if session == nil { send(.phoneRecording) }  // Mac stops listening to its own mic
        recorder.start(waitForSpeech: session == nil ? 10 : 8) { [weak self] data in
            guard let self else { return }
            if let data {
                self.send(.audio(session: session?.id, data: data))
            } else if session == nil {
                // «Cancel» ends the whole conversation, same as on the Mac. Silence alone: while
                // the Mac waits for the phone, go back to reading; otherwise release the turn.
                let waiting = ["reading", "phone"].contains(self.snapshot?.active?.state ?? "")
                self.send(.control(waiting && !self.cancelAll ? "reading" : "cancel"))
            }
            self.cancelAll = false
            self.recordingFor = nil
        }
    }

    /// Locked / backgrounded: tell the Mac and disconnect, so its panel comes back immediately.
    private var inBackground = false

    func goAway() {
        inBackground = true
        guard link != nil else { return }
        link?.send(LinkEnvelope(command: .bye))
        let l = link
        link = nil
        status = .lost
        Task { try? await Task.sleep(for: .milliseconds(300)); l?.cancel() }
    }

    /// Back in the foreground: reconnect.
    func comeBack() {
        inBackground = false
        if status == .badCode { return }
        startBrowser()  // fresh Bonjour results after the background
        if link == nil { autoConnect() }
    }

    func send(_ cmd: LinkCommand) {
        link?.send(LinkEnvelope(command: cmd))
    }
}
