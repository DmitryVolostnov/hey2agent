import Foundation
import Network
import VoiceLoopLink

/// Serves the HUD to the iPhone remote over the local network (Bonjour + TLS-PSK).
@MainActor
final class LinkServer {
    private let model: Model
    private var listener: NWListener?
    private var clients: [ObjectIdentifier: LinkConnection] = [:]
    private var pending: [ObjectIdentifier: LinkConnection] = [:]
    private var last: LinkSnapshot?
    private var lastSent = Date.distantPast
    private(set) var code: String

    init(model: Model) {
        self.model = model
        if let saved = UserDefaults.standard.string(forKey: "pairingCode") {
            code = saved
        } else {
            code = makePairingCode()
            UserDefaults.standard.set(code, forKey: "pairingCode")
        }
        model.pairingCode = code
        start()
    }

    func newCode() {
        code = makePairingCode()
        UserDefaults.standard.set(code, forKey: "pairingCode")
        model.pairingCode = code
        start()  // drops paired phones: they must enter the new code
    }

    private func start() {
        listener?.cancel()
        clients.values.forEach { $0.cancel() }
        clients = [:]
        model.phones = 0
        guard let l = try? NWListener(using: VoiceLoopLink.parameters(code: code)) else { return }
        l.service = NWListener.Service(name: Host.current().localizedName ?? "Mac",
                                       type: VoiceLoopLink.serviceType)
        l.newConnectionHandler = { [weak self] c in
            MainActor.assumeIsolated { self?.accept(c) }
        }
        l.start(queue: .main)
        listener = l
    }

    private func accept(_ nw: NWConnection) {
        let c = LinkConnection(nw)
        let key = ObjectIdentifier(c)
        pending[key] = c  // keep it alive during the TLS handshake
        c.onState = { [weak self, weak c] state in
            guard let self, let c else { return }
            switch state {
            case .ready:
                self.pending[key] = nil
                self.clients[key] = c
                self.model.phones = self.clients.count
                c.send(LinkEnvelope(snapshot: self.model.snapshot()))
            case .failed, .cancelled:
                self.pending[key] = nil
                self.clients[key] = nil
                self.model.phones = self.clients.count
            default:
                break
            }
        }
        c.onEnvelope = { [weak self] env in
            if let cmd = env.command { self?.handle(cmd) }
        }
        c.start()
    }

    /// Called from the HUD tick: push a snapshot whenever something changed, and at least
    /// every 5 s as a heartbeat so the phone notices a dead connection.
    func tick() {
        guard !clients.isEmpty else { return }
        let snap = model.snapshot()
        guard snap != last || Date().timeIntervalSince(lastSent) > 5 else { return }
        last = snap
        lastSent = Date()
        clients.values.forEach { $0.send(LinkEnvelope(snapshot: snap)) }
    }

    private func handle(_ cmd: LinkCommand) {
        switch cmd {
        case .control(let c): model.send(c)
        case .reply(let t): model.reply(t)
        case .dictate(let id):
            if let s = (model.sessions + model.recent).first(where: { $0.id == id }) {
                model.dictate(to: s)
            }
        case .cancelSent(let id): model.cancelSent(id)
        case .setMuted(let on): model.setMuted(on)
        case .setEnabled(let on): model.setEnabled(on)
        }
    }
}

extension Model {
    func snapshot() -> LinkSnapshot {
        func conv(_ s: AgentSession) -> LinkSession {
            LinkSession(id: s.id, project: s.project, title: s.title, status: s.status,
                        since: s.since, ended: s.ended, agent: s.agent)
        }
        let a = active.map {
            LinkVoiceState(state: $0.state, project: $0.project, summary: $0.summary, text: $0.text,
                           level: $0.level, left: $0.left, delivery: $0.delivery,
                           session_id: $0.session_id, cancellable: $0.cancellable, t: $0.t)
        }
        return LinkSnapshot(mac: Host.current().localizedName ?? "Mac", enabled: enabled, muted: muted,
                            active: a, sessions: sessions.map(conv), recent: recent.map(conv))
    }
}
