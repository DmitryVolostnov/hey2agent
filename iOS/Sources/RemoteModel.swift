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
        // The Mac sends at least every 5 s; silence for 15 s means the connection is dead
        // (e.g. the Mac slept or the HUD restarted) even if TCP hasn't noticed yet.
        watchdog = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                if let self, self.status == .connected { self.send(.ping) }
                guard let self, self.link != nil, self.status == .connected,
                      Date().timeIntervalSince(self.lastMessage) > 15 else { continue }
                self.link?.cancel()
                self.link = nil
                self.status = .lost
                self.autoConnect()
            }
        }
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
            if let s = env.snapshot, s != self?.snapshot { self?.snapshot = s }
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
    /// Which chat the phone is recording for; nil while recording = answer to the running conversation.
    var recordingFor: LinkSession?
    var recordingTitle = ""
    var micDenied = false

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
                self.send(.control("cancel"))
            }
            self.recordingFor = nil
        }
    }

    func send(_ cmd: LinkCommand) {
        link?.send(LinkEnvelope(command: cmd))
    }
}
