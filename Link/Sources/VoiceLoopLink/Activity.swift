import Foundation

/// «What the agent is doing right now», worded in the app's language.
/// kind comes from the PreToolUse hook; an action older than 8 s means it went back to thinking.
public func activityLabel(kind: String?, target: String?, at: Double?, now: Date = Date()) -> String {
    guard let kind, let at, now.timeIntervalSince1970 - at < 8 else {
        return String(localized: "Thinking…")
    }
    switch kind {
    case "read": return String(localized: "Reading \(target ?? "")")
    case "edit": return String(localized: "Editing \(target ?? "")")
    case "run": return String(localized: "Running \(target ?? "")")
    case "search": return String(localized: "Searching \(target ?? "")")
    case "web": return String(localized: "Browsing \(target ?? "")")
    case "agent": return String(localized: "Delegating: \(target ?? "")")
    default: return String(localized: "Using \(target ?? "")")
    }
}

/// Status shown next to a working chat: Claude's latest message in this turn if any, else the tool.
public func sessionStatus(note: String?, kind: String?, target: String?, at: Double?, now: Date = Date()) -> String {
    if let note, !note.isEmpty { return note }
    return activityLabel(kind: kind, target: target, at: at, now: now)
}
