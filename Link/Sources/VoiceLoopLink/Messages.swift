import Foundation

/// What the Mac is doing right now (mirrors ~/.voice-loop/state.json).
public struct LinkVoiceState: Codable, Equatable, Sendable {
    public var state: String
    public var project: String?
    public var summary: String?
    public var text: String?
    public var level: Double?
    public var left: Double?
    public var delivery: String?
    public var code: String?
    public var details: String?
    public var session_id: String?
    public var cancellable: Bool?
    public var t: Double

    public init(state: String, project: String? = nil, summary: String? = nil, text: String? = nil,
                level: Double? = nil, left: Double? = nil, delivery: String? = nil, code: String? = nil,
                details: String? = nil, session_id: String? = nil, cancellable: Bool? = nil, t: Double) {
        self.state = state; self.project = project; self.summary = summary; self.text = text
        self.level = level; self.left = left; self.delivery = delivery; self.code = code; self.details = details
        self.session_id = session_id; self.cancellable = cancellable; self.t = t
    }
}

/// An agent chat (mirrors an entry of ~/.voice-loop/sessions.json).
public struct LinkSession: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var project: String
    public var title: String
    public var status: String  // working | waiting | finished | idle | stopping
    public var since: Double
    public var ended: Double?
    public var agent: String?

    public init(id: String, project: String, title: String, status: String, since: Double,
                ended: Double? = nil, agent: String? = nil) {
        self.id = id; self.project = project; self.title = title; self.status = status
        self.since = since; self.ended = ended; self.agent = agent
    }
}

/// Mac → iPhone: everything the HUD shows.
public struct LinkSnapshot: Codable, Equatable, Sendable {
    public var mac: String
    public var enabled: Bool
    public var muted: Bool
    /// The active conversation step, or nil when idle.
    public var active: LinkVoiceState?
    public var sessions: [LinkSession]
    public var recent: [LinkSession]

    public init(mac: String, enabled: Bool, muted: Bool, active: LinkVoiceState?,
                sessions: [LinkSession], recent: [LinkSession]) {
        self.mac = mac; self.enabled = enabled; self.muted = muted; self.active = active
        self.sessions = sessions; self.recent = recent
    }
}

/// iPhone → Mac.
public enum LinkCommand: Codable, Equatable, Sendable {
    /// Raw control for the running conversation: send | cancel | skip | repeat | again | hold.
    case control(String)
    /// Typed reply for the running conversation.
    case reply(String)
    /// Record (with the Mac mic) a message for a chat that isn't waiting.
    case dictate(session: String)
    /// Bring this chat to the front on the Mac.
    case open(session: String)
    /// «Отменить» after sending.
    case cancelSent(session: String)
    /// The user started recording on the iPhone: the Mac stops listening to its own mic.
    case phoneRecording
    /// A recording made on the iPhone (wav/m4a). session nil = answer to the running conversation.
    case audio(session: String?, data: Data)
    /// Phone heartbeat (every 5 s) so the Mac notices a vanished phone and shows its panel again.
    case ping
    case setMuted(Bool)
    case setEnabled(Bool)
}

public struct LinkEnvelope: Codable, Sendable {
    public var snapshot: LinkSnapshot?
    public var command: LinkCommand?

    public init(snapshot: LinkSnapshot? = nil, command: LinkCommand? = nil) {
        self.snapshot = snapshot; self.command = command
    }
}
