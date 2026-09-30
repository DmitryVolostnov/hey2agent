import AppKit
import Observation
import ServiceManagement
import SwiftUI

// Reads ~/.voice-loop/state.json and sessions.json (written by voice_loop.py), writes
// ~/.voice-loop/control (send | cancel | skip | repeat | text\n…), config.json and the
// enabled flag. The script works without this app.

private let stateDir = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent(".voice-loop")
private let stateURL = stateDir.appendingPathComponent("state.json")
private let sessionsURL = stateDir.appendingPathComponent("sessions.json")
private let controlURL = stateDir.appendingPathComponent("control")
private let flagURL = stateDir.appendingPathComponent("enabled")
private let mutedURL = stateDir.appendingPathComponent("muted")
private let configURL = stateDir.appendingPathComponent("config.json")
private let logURL = stateDir.appendingPathComponent("log.txt")
private let voicesDir = stateDir.appendingPathComponent("voices")
/// `voice_loop.py install` writes "<python>\n<script>" here so the HUD can call the script.
private let scriptLocation: (python: String, script: String)? = {
    guard let text = try? String(contentsOf: stateDir.appendingPathComponent("script_path"), encoding: .utf8)
    else { return nil }
    let lines = text.split(separator: "\n").map(String.init)
    return lines.count >= 2 ? (lines[0], lines[1]) : nil
}()

struct VoiceState: Decodable, Equatable {
    var state: String
    var project: String?
    var summary: String?
    var text: String?
    var level: Double?
    var left: Double?
    var delivery: String?  // queued | resumed | clipboard (message to a recent chat)
    var session_id: String?
    var cancellable: Bool?
    var t: Double
}

struct AgentSession: Decodable, Equatable, Identifiable {
    var id: String = ""
    var project: String
    var title: String
    var status: String  // working | waiting | finished | idle
    var since: Double
    var updated: Double
    var transcript: String?
    var agent: String?
    var ended: Double?

    enum CodingKeys: String, CodingKey { case project, title, status, since, updated, transcript, agent, ended }
}

/// A voice the script can use: macOS `say` voice or a downloaded Piper model.
struct Voice: Hashable, Identifiable {
    var engine: String  // say | piper
    var name: String
    var id: String { "\(engine):\(name)" }
    var label: String {
        engine == "piper"
            ? "Piper · \(name.replacingOccurrences(of: "ru_RU-", with: "").replacingOccurrences(of: "-medium", with: ""))"
            : name
    }
}

@MainActor @Observable
final class Model {
    var current: VoiceState?
    var sessions: [AgentSession] = []  // working / waiting / finished
    var recent: [AgentSession] = []    // idle chats, newest first
    var enabled = FileManager.default.fileExists(atPath: flagURL.path)
    var muted = FileManager.default.fileExists(atPath: mutedURL.path)
    var showHUD = UserDefaults.standard.object(forKey: "showHUD") as? Bool ?? true {
        didSet { UserDefaults.standard.set(showHUD, forKey: "showHUD") }
    }
    /// The phone becomes the display: hide the Mac panel while an iPhone is connected.
    var hideWhenPhone = UserDefaults.standard.object(forKey: "hideWhenPhone") as? Bool ?? true {
        didSet { UserDefaults.standard.set(hideWhenPhone, forKey: "hideWhenPhone") }
    }
    var expanded = false
    var config: [String: Any] = [:]
    var voices: [Voice] = []
    var knownProjects: [String] = []
    var pairingCode = ""
    var phones = 0
    var onNewPairingCode: (() -> Void)?

    var launchAtLogin: Bool = SMAppService.mainApp.status == .enabled {
        didSet {
            guard launchAtLogin != (SMAppService.mainApp.status == .enabled) else { return }
            if launchAtLogin { try? SMAppService.mainApp.register() } else { try? SMAppService.mainApp.unregister() }
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }

    init() {
        loadConfig()
        voices = Self.installedVoices()
        if UserDefaults.standard.object(forKey: "launchAtLoginInitialized") == nil {
            UserDefaults.standard.set(true, forKey: "launchAtLoginInitialized")
            launchAtLogin = true
        }
    }

    // MARK: state

    /// Active conversation state, or nil when idle (finished states linger briefly).
    var active: VoiceState? {
        guard let s = current else { return nil }
        let age = Date().timeIntervalSince1970 - s.t
        switch s.state {
        case "speaking", "listening", "transcribing", "confirming", "phone":
            return age < 200 ? s : nil  // hook dies at 180 s
        case "sent":
            let linger: Double = s.delivery == "clipboard" ? 12 : (s.cancellable == true ? 10 : 4)
            return age < linger ? s : nil
        case "released": return age < 1.5 ? s : nil
        case "error": return age < 8 ? s : nil
        default: return nil
        }
    }

    var visible: Bool {
        showHUD && !(hideWhenPhone && phones > 0) && (enabled || active != nil)
    }

    private var stateStamp: Date?
    private var sessionsStamp: Date?
    private var sessionsCheckedAt = Date.distantPast

    private static func mtime(_ url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }

    /// Cheap when nothing changed: files are re-read only if their mtime moved
    /// (sessions also every 5 s, because liveness depends on transcript age).
    func poll() {
        enabled = FileManager.default.fileExists(atPath: flagURL.path)
        muted = FileManager.default.fileExists(atPath: mutedURL.path)
        let st = Self.mtime(stateURL)
        if st != stateStamp {
            stateStamp = st
            if let data = try? Data(contentsOf: stateURL),
               let s = try? JSONDecoder().decode(VoiceState.self, from: data), s != current {
                current = s
            }
        }
        let ss = Self.mtime(sessionsURL)
        if ss != sessionsStamp || Date().timeIntervalSince(sessionsCheckedAt) > 5 {
            sessionsStamp = ss
            sessionsCheckedAt = Date()
            let all = Self.loadSessions()
            let live = all.filter { $0.status != "idle" }.sorted { $0.since < $1.since }
            let idle = Array(all.filter { $0.status == "idle" }
                .sorted { ($0.ended ?? $0.updated) > ($1.ended ?? $1.updated) }.prefix(8))
            if live != sessions { sessions = live }
            if idle != recent { recent = idle }
            for p in all.map(\.project) where !knownProjects.contains(p) { knownProjects.append(p) }
        }
    }

    /// All known sessions. One "in progress" whose transcript hasn't changed for 20 min was most
    /// likely interrupted (no Stop hook fires then), so it is shown as idle.
    private static func loadSessions() -> [AgentSession] {
        guard let data = try? Data(contentsOf: sessionsURL),
              let dict = try? JSONDecoder().decode([String: AgentSession].self, from: data) else { return [] }
        let now = Date().timeIntervalSince1970
        let focusedAt = dict.values.contains { $0.status == "finished" } ? claudeAppFocus() : [:]
        return dict.compactMap { id, s -> AgentSession? in
            var s = s
            s.id = id
            var lastSeen = s.updated
            if let path = s.transcript,
               let m = try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate] as? Date {
                lastSeen = max(lastSeen, m.timeIntervalSince1970)
            }
            // «готово» (finished while muted) is news only until seen: after 10 min, or once the
            // chat was focused in the Claude app after it ended, it moves to «Недавние».
            if s.status == "finished", let ended = s.ended,
               now - ended > 10 * 60 || (focusedAt[id] ?? 0) > ended {
                s.status = "idle"
            }
            if s.status == "working",
               FileManager.default.fileExists(atPath: stateDir.appendingPathComponent("cancel/\(id)").path) {
                s.status = "stopping"  // «Отменить» pressed; Claude is winding down
            }
            if s.status == "working" || s.status == "waiting" || s.status == "stopping",
               now - lastSeen > 20 * 60 {
                s.status = "idle"
                s.ended = s.ended ?? lastSeen
            }
            return s
        }
    }

    // MARK: commands

    func send(_ command: String) {
        try? command.write(to: controlURL, atomically: true, encoding: .utf8)
    }

    /// Dictate a message for a chat that isn't waiting for an answer.
    private var dictation: Process?

    /// Bring this chat to the front (Claude app deep link / Codex app).
    func open(_ session: AgentSession) {
        guard let loc = scriptLocation else { return }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: loc.python)
        p.arguments = [loc.script, "open", session.id]
        try? p.run()
    }

    func dictate(to session: AgentSession, recording: String? = nil) {
        guard active == nil, dictation?.isRunning != true, let loc = scriptLocation else { return }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: loc.python)
        p.arguments = [loc.script, "dictate", session.id] + (recording.map { [$0] } ?? [])
        try? p.run()
        dictation = p
    }

    /// «Отменить» after sending: Claude's PreToolUse hook then denies every action and it stops.
    func cancelSent(_ sessionID: String) {
        let dir = stateDir.appendingPathComponent("cancel")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: dir.appendingPathComponent(sessionID).path, contents: nil)
    }

    func reply(_ text: String) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !t.isEmpty { send("text\n\(t)") }
    }

    func setMuted(_ on: Bool) {
        if on {
            FileManager.default.createFile(atPath: mutedURL.path, contents: nil)
            if active != nil { send("cancel") }  // stop talking right now
        } else {
            try? FileManager.default.removeItem(at: mutedURL)
        }
        muted = on
    }

    func setEnabled(_ on: Bool) {
        if on {
            try? FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: flagURL.path, contents: nil)
        } else {
            try? FileManager.default.removeItem(at: flagURL)
        }
        enabled = on
    }

    // MARK: config (~/.voice-loop/config.json overrides the script's DEFAULTS)

    func loadConfig() {
        if let data = try? Data(contentsOf: configURL),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            config = obj
        }
        for p in (config["projects"] as? [String]) ?? [] where !knownProjects.contains(p) {
            knownProjects.append(p)
        }
    }

    func set(_ key: String, _ value: Any) {
        config[key] = value
        if let data = try? JSONSerialization.data(withJSONObject: config, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: configURL, options: .atomic)
        }
    }

    func double(_ key: String, _ fallback: Double) -> Double { config[key] as? Double ?? fallback }

    var voice: Voice {
        let engine = config["tts"] as? String ?? "say"
        return engine == "piper"
            ? Voice(engine: "piper", name: config["piper_voice"] as? String ?? "ru_RU-irina-medium")
            : Voice(engine: "say", name: config["voice"] as? String ?? "Milena")
    }

    func setVoice(_ v: Voice) {
        set("tts", v.engine)
        set(v.engine == "piper" ? "piper_voice" : "voice", v.name)
    }

    func previewVoice() {
        guard let loc = scriptLocation else { return }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: loc.python)
        p.arguments = [loc.script, "say", "Привет! Так я буду рассказывать, что сделал кодекс или клод."]
        try? p.run()
    }

    var projects: [String] { config["projects"] as? [String] ?? [] }

    func toggleProject(_ name: String) {
        var list = projects
        if let i = list.firstIndex(of: name) { list.remove(at: i) } else { list.append(name) }
        set("projects", list)
    }

    /// Claude Code session id → when its chat was last focused in the Claude app (seconds).
    private static func claudeAppFocus() -> [String: Double] {
        let root = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Claude/claude-code-sessions")
        var out: [String: Double] = [:]
        guard let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else { return out }
        for case let url as URL in e where url.lastPathComponent.hasPrefix("local_") && url.pathExtension == "json" {
            guard let d = try? Data(contentsOf: url),
                  let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                  let cli = o["cliSessionId"] as? String, let f = o["lastFocusedAt"] as? Double else { continue }
            out[cli] = f / 1000
        }
        return out
    }

    private static func installedVoices() -> [Voice] {
        var result: [Voice] = []
        let p = Process()
        let pipe = Pipe()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        p.arguments = ["-v", "?"]
        p.standardOutput = pipe
        if (try? p.run()) != nil {
            p.waitUntilExit()
            let out = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            for line in out.split(separator: "\n") where line.contains("ru_RU") {
                // "Milena (Enhanced)   ru_RU    # …" → name before the locale column
                if let r = line.range(of: #"\s{2,}ru_RU"#, options: .regularExpression) {
                    result.append(Voice(engine: "say", name: String(line[..<r.lowerBound])))
                }
            }
        }
        let piper = (try? FileManager.default.contentsOfDirectory(atPath: voicesDir.path)) ?? []
        for f in piper.sorted() where f.hasSuffix(".onnx") {
            result.append(Voice(engine: "piper", name: String(f.dropLast(5))))
        }
        return result
    }
}

// MARK: - Views

struct HUDRoot: View {
    @Bindable var model: Model
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let s = model.active {
                // New identity per conversation step: the reply field never carries text over
                // into another state or another session.
                ConversationView(model: model, s: s)
                    .id("\(s.project ?? "")|\(s.state)")
            } else {
                IdleHeader(model: model)
            }
            if !model.sessions.isEmpty {
                Divider().opacity(0.4)
                SessionList(sessions: model.sessions, detailed: model.expanded || model.active != nil,
                            open: { model.open($0) }) {
                    s in s.status == "finished" && model.active == nil ? { model.dictate(to: s) } : nil
                }
            }
            if model.expanded && model.active == nil && !model.recent.isEmpty {
                Divider().opacity(0.4)
                Text("Недавние: нажмите, чтобы открыть чат, 🎙 — надиктовать")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 12)
                    .padding(.top, 8)
                SessionList(sessions: model.recent, detailed: true, open: { model.open($0) }) { s in
                    model.active == nil ? { model.dictate(to: s) } : nil
                }
            }
        }
        .frame(width: 380, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.white.opacity(0.08)))
        .padding(8)
        .onHover { inside in
            hovering = inside
            if inside {
                model.expanded = true
            } else {
                Task {
                    try? await Task.sleep(for: .milliseconds(900))
                    if !hovering { model.expanded = false }
                }
            }
        }
    }
}

struct IdleHeader: View {
    @Bindable var model: Model

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: model.muted ? "speaker.slash" : "waveform").foregroundStyle(.secondary)
            Text(headline).font(.system(size: 12, weight: .medium))
            Spacer(minLength: 8)
            Button { model.setMuted(!model.muted) } label: {
                Image(systemName: model.muted ? "speaker.slash.fill" : "speaker.wave.2")
                    .foregroundStyle(model.muted ? .orange : .secondary)
            }
            .buttonStyle(.borderless)
            .help(model.muted ? "Включить звук" : "Без звука (встреча): не говорить и не слушать")
            if model.expanded {
                SettingsMenu(model: model)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

extension IdleHeader {
    var headline: String {
        let working = model.sessions.filter { $0.status == "working" || $0.status == "waiting" }.count
        let done = model.sessions.filter { $0.status == "finished" }.count
        var parts: [String] = []
        if working > 0 { parts.append("в работе \(working)") }
        if done > 0 { parts.append("готово \(done)") }
        let base = parts.isEmpty ? "Голос включён" : parts.joined(separator: " · ").capitalizedFirst
        return model.muted ? (parts.isEmpty ? "Без звука" : "\(base) · без звука") : base
    }
}

extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}

struct ConversationView: View {
    @Bindable var model: Model
    let s: VoiceState
    @State private var typed = ""
    @State private var editMode = false
    @State private var cancelled = false
    @FocusState private var editing: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                icon.font(.system(size: 15, weight: .semibold)).frame(width: 20)
                Text(title).font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                    .fixedSize()
                if let project = s.project {
                    Text(project).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 12)
                if s.state == "listening", let left = s.left {
                    Text("\(Int(left.rounded(.up))) с")
                        .font(.system(size: 12).monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                if s.state == "confirming" && !editMode {
                    Button("Отмена") { model.send("cancel") }
                        .controlSize(.small)
                }
                if s.state == "sent", s.cancellable == true, s.delivery != "clipboard",
                   let sid = s.session_id, !cancelled {
                    Button("Отменить") {
                        model.cancelSent(sid)
                        cancelled = true
                    }
                    .controlSize(.small)
                    .help("Claude остановится: все его следующие действия будут запрещены")
                }
            }

            if s.state == "listening" {
                LevelBar(level: s.level ?? 0)
            }

            if let line = bodyText, !line.isEmpty {
                Text(line)
                    .font(.system(size: 12))
                    .foregroundStyle(s.state == "speaking" ? .secondary : .primary)
                    .lineLimit(s.state == "confirming" || s.state == "sent" ? 12 : 5)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }

            if s.state == "confirming" {
                if editMode {
                    TextField("Исправьте и нажмите ↩", text: $typed, axis: .vertical)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12))
                        .lineLimit(1...6)
                        .focused($editing)
                        .onSubmit { model.reply(typed) }
                    HStack {
                        Button("Отмена") { model.send("cancel") }
                        Spacer()
                        Button("Отправить") { model.reply(typed) }
                    }
                    .controlSize(.small)
                } else {
                    HStack(spacing: 12) {
                        Button("Изменить") {
                            typed = s.text ?? ""
                            editMode = true
                            editing = true
                            model.send("hold")  // stop the countdown while editing
                        }
                        Button("Сказать заново") { model.send("again") }
                        Spacer()
                        Button("Отправить сейчас") { model.send("send") }
                    }
                    .buttonStyle(.link)
                    .font(.system(size: 11))
                }
            }

            if s.state == "speaking" || s.state == "listening" {
                TextField("Ответить текстом и нажать ↩", text: $typed)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12))
                    .onSubmit {
                        model.reply(typed)
                        typed = ""
                    }
                HStack {
                    Button("Повторить") { model.send("repeat") }
                        .disabled(s.state != "listening")
                    Spacer()
                    Button("Отмена") { model.send("cancel") }
                    if s.state == "speaking" {
                        Button("Пропустить") { model.send("skip") }
                    } else {
                        Button("Отправить") { model.send("send") }
                    }
                }
                .controlSize(.small)
            }
        }
        .padding(14)
    }

    private var bodyText: String? {
        switch s.state {
        case "speaking": s.summary
        case _ where s.state == "sent" && s.delivery == "clipboard":
            "Скопировано. Вставьте в чат «\(s.project ?? "")» в Claude: ⌘V и ↩\n\n\(s.text ?? "")"
        case "listening", "transcribing", "sent": s.text
        case "confirming": editMode ? nil : s.text
        case "error": s.text
        default: nil
        }
    }

    private var title: String {
        switch s.state {
        case "speaking": "Говорю"
        case "listening": "Слушаю"
        case "transcribing": "Распознаю…"
        case "phone": "Говорите в iPhone…"
        case "confirming": editMode ? "Исправьте текст"
            : s.left.map { "Отправлю через \(Int($0.rounded(.up))) с" } ?? "Отправлю, когда нажмёте ↩"
        case "sent" where cancelled: "Отменено, Claude остановится"
        case "sent": s.delivery == "clipboard" ? "В буфере обмена" : s.delivery == "queued" ? "Добавлено в Codex" : "Отправлено"
        case "released": "Сессия отпущена"
        case "error": "Не получилось"
        default: ""
        }
    }

    @ViewBuilder private var icon: some View {
        switch s.state {
        case "speaking": Image(systemName: "speaker.wave.2.fill").foregroundStyle(.blue)
        case "listening": Image(systemName: "mic.fill").foregroundStyle(.red)
        case "transcribing": ProgressView().controlSize(.small)
        case "phone": Image(systemName: "iphone.radiowaves.left.and.right").foregroundStyle(.red)
        case "confirming": Image(systemName: "paperplane").foregroundStyle(.blue)
        case "error": Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        case "sent": Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        default: Image(systemName: "moon.zzz").foregroundStyle(.secondary)
        }
    }
}

struct SessionList: View {
    let sessions: [AgentSession]
    let detailed: Bool
    /// Click on a row: open the chat.
    var open: (AgentSession) -> Void = { _ in }
    /// Mic button on a row (dictate to this chat), or nil if dictation isn't possible now.
    var action: (AgentSession) -> (() -> Void)? = { _ in nil }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            VStack(alignment: .leading, spacing: 2) {
                ForEach(sessions) { s in
                    SessionRow(open: { open(s) }, dictate: action(s)) {
                        row(s, now: context.date)
                    }
                }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 6)
        }
    }

    @ViewBuilder private func row(_ s: AgentSession, now: Date) -> some View {
                    HStack(spacing: 8) {
                        Image(systemName: s.status == "finished" ? "checkmark.circle.fill" : "circle.fill")
                            .font(.system(size: s.status == "finished" ? 9 : 7))
                            .frame(width: 10)
                            .foregroundStyle(color(s.status))
                            .symbolEffect(.pulse, options: .repeating,
                                          isActive: s.status == "working" || s.status == "waiting")
                        Text(s.title)
                            .font(.system(size: 12))
                            .lineLimit(1)
                            .truncationMode(.tail)
                        Spacer(minLength: 6)
                        if detailed {
                            Text(label(s))
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                            Text(s.status == "idle" || s.status == "finished"
                                 ? ago(s.ended ?? s.updated, now: now)
                                 : elapsed(since: s.since, now: now))
                                .font(.system(size: 11).monospacedDigit())
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .help("\(s.project) · \(label(s))")
    }

    private func ago(_ t: Double, now: Date) -> String {
        let m = max(0, Int(now.timeIntervalSince1970 - t)) / 60
        if m < 1 { return "только что" }
        if m < 60 { return "\(m) мин назад" }
        if m < 24 * 60 { return "\(m / 60) ч назад" }
        return "\(m / 1440) д назад"
    }

    private func color(_ status: String) -> Color {
        switch status {
        case "waiting": .blue
        case "finished", "idle": .green
        case "stopping": .gray
        default: .orange
        }
    }

    private func label(_ s: AgentSession) -> String {
        switch s.status {
        case "waiting": "ждёт ответа"
        case "finished": "готово"
        case "idle": s.project
        case "stopping": "останавливается…"
        default: s.project
        }
    }

    private func elapsed(since: Double, now: Date) -> String {
        let sec = max(0, Int(now.timeIntervalSince1970 - since))
        return sec < 60 ? "\(sec) с" : "\(sec / 60) мин"
    }
}

/// A list row that highlights on hover and records a message for its chat on click.
struct SessionRow<Content: View>: View {
    let open: () -> Void
    let dictate: (() -> Void)?
    @ViewBuilder let content: Content
    @State private var hover = false

    var body: some View {
        HStack(spacing: 6) {
            content
            if let dictate, hover {
                Button(action: dictate) {
                    Image(systemName: "mic.fill").font(.system(size: 11))
                }
                .buttonStyle(.borderless)
                .help("Надиктовать сообщение в этот чат")
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: 6).fill(hover ? Color.primary.opacity(0.07) : .clear))
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .onTapGesture(perform: open)
        .help("Открыть чат")
    }
}

struct SettingsMenu: View {
    @Bindable var model: Model

    var body: some View {
        Menu {
            Toggle("Голосовой режим", isOn: Binding(get: { model.enabled }, set: { model.setEnabled($0) }))
            Toggle("Без звука (встреча)", isOn: Binding(get: { model.muted }, set: { model.setMuted($0) }))
            Divider()
            Picker("Голос", selection: Binding(get: { model.voice }, set: { model.setVoice($0) })) {
                ForEach(model.voices) { Text($0.label).tag($0) }
            }
            Button("Прослушать голос") { model.previewVoice() }
            Picker("Пауза, после которой отправляю", selection: Binding(
                get: { model.double("silence_sec", 2.0) }, set: { model.set("silence_sec", $0) })) {
                ForEach([1.5, 2.0, 2.5, 3.0], id: \.self) { Text(String(format: "%.1f с", $0)).tag($0) }
            }
            Picker("Можно отменить в течение", selection: Binding(
                get: { model.double("undo_sec", 3.0) }, set: { model.set("undo_sec", $0) })) {
                Text("не ждать").tag(0.0)
                ForEach([2.0, 3.0, 5.0], id: \.self) { Text("\(Int($0)) с").tag($0) }
            }
            Picker("Время, чтобы начать говорить", selection: Binding(
                get: { model.double("wait_sec", 5.0) }, set: { model.set("wait_sec", $0) })) {
                ForEach([5.0, 8.0, 10.0, 15.0], id: \.self) { Text("\(Int($0)) с").tag($0) }
            }
            Menu("Проекты") {
                Button(model.projects.isEmpty ? "✓ Все проекты" : "Все проекты") { model.set("projects", [String]()) }
                Divider()
                ForEach(model.knownProjects, id: \.self) { p in
                    Button(model.projects.contains(p) ? "✓ \(p)" : p) { model.toggleProject(p) }
                }
            }
            Divider()
            Section("iPhone") {
                Text("Код привязки: \(model.pairingCode.prefix(3)) \(model.pairingCode.suffix(3))")
                Text(model.phones > 0 ? "Подключено: \(model.phones)" : "Телефон не подключён")
                Button("Новый код (отключит телефон)") { model.onNewPairingCode?() }
            }
            Divider()
            Toggle("Запускать при входе в систему", isOn: $model.launchAtLogin)
            Toggle("Показывать плашку", isOn: $model.showHUD)
            Toggle("Прятать, когда подключён iPhone", isOn: $model.hideWhenPhone)
            Button("Открыть лог") { NSWorkspace.shared.open(logURL) }
            Button("Выйти") { NSApp.terminate(nil) }
        } label: {
            Image(systemName: "gearshape")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }
}

struct LevelBar: View {
    let level: Double

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule().fill(.red.gradient)
                    .frame(width: max(4, geo.size.width * level))
                    .animation(.linear(duration: 0.15), value: level)
            }
        }
        .frame(height: 4)
    }
}

// MARK: - Panel

/// Buttons react to the first click even though the panel never becomes active.
final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Non-activating floating panel: clickable without stealing focus from the editor.
final class HUDPanel: NSPanel {
    private let host: FirstMouseHostingView<HUDRoot>

    init(model: Model) {
        host = FirstMouseHostingView(rootView: HUDRoot(model: model))
        host.sizingOptions = [.intrinsicContentSize]
        super.init(contentRect: .zero, styleMask: [.nonactivatingPanel, .borderless],
                   backing: .buffered, defer: false)
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        isMovableByWindowBackground = true
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false  // the SwiftUI card draws its own edge; a window shadow would box the padding
        hidesOnDeactivate = false
        contentView = host
    }

    override var canBecomeKey: Bool { true }  // for the reply text field

    func placeTopCenter() {
        guard let screen = NSScreen.main else { return }
        let size = host.intrinsicContentSize
        let f = screen.visibleFrame
        setFrame(NSRect(x: f.midX - size.width / 2, y: f.maxY - size.height - 4,
                        width: size.width, height: size.height), display: true)
    }

    /// Resize to fit content, keeping the top edge where the user left it.
    func fitKeepingTop() {
        let size = host.intrinsicContentSize
        guard size != frame.size else { return }
        setFrame(NSRect(x: frame.minX, y: frame.maxY - size.height,
                        width: size.width, height: size.height), display: true)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = Model()
    private var panel: HUDPanel?
    private var link: LinkServer?
    private var placed = false

    /// Opening the app again (Spotlight, Finder, `open`) always brings the panel back.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        model.showHUD = true
        return false
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        panel = HUDPanel(model: model)
        let server = LinkServer(model: model)
        link = server
        model.onNewPairingCode = { [weak server] in server?.newCode() }
        Task { @MainActor in
            while true {
                tick()
                // Fast while talking (mic level, countdown), relaxed when idle.
                try? await Task.sleep(for: .milliseconds(model.active != nil ? 100 : 350))
            }
        }
    }

    private func tick() {
        model.poll()
        link?.tick()
        guard let panel else { return }
        if model.visible {
            panel.fitKeepingTop()
            if !panel.isVisible {
                if !placed { panel.placeTopCenter(); placed = true }
                panel.orderFrontRegardless()
            }
        } else if panel.isVisible {
            panel.orderOut(nil)
        }
    }
}

@main
struct VoiceLoopHUDApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        MenuBarExtra {
            MenuContent(model: delegate.model)
        } label: {
            Image(systemName: !delegate.model.enabled ? "waveform.slash"
                  : delegate.model.muted ? "speaker.slash" : "waveform")
        }
    }
}

struct MenuContent: View {
    @Bindable var model: Model

    var body: some View {
        Toggle("Голосовой режим", isOn: Binding(get: { model.enabled }, set: { model.setEnabled($0) }))
        Toggle("Без звука (встреча)", isOn: Binding(get: { model.muted }, set: { model.setMuted($0) }))
        Toggle("Показывать плашку", isOn: $model.showHUD)
        Toggle("Запускать при входе в систему", isOn: $model.launchAtLogin)
        Divider()
        Button("Выйти") { NSApp.terminate(nil) }.keyboardShortcut("q")
    }
}
