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
    var code: String?      // error code from the script: no_mic | failed
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
    /// The visible card inside the (larger, transparent) panel, in SwiftUI window coordinates.
    var cardFrame: CGRect = .zero
    /// «Закрыть» on a finished step: hidden until the next state change.
    var dismissedAt: Double?
    /// «Ещё» in «Недавние»: 5 → 10 rows (reset when the panel folds).
    var showMoreRecent = false
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
        guard let s = current, s.t != dismissedAt else { return nil }
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

    /// Nothing in progress and not hovered: shrink to a square with just the app icon.
    var isSquare: Bool { active == nil && sessions.isEmpty && !expanded }

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
                .sorted { ($0.ended ?? $0.updated) > ($1.ended ?? $1.updated) }.prefix(10))
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

    // MARK: interface language (empty = follow the system)

    static let appLanguages: [String] = Bundle.main.localizations.filter { $0 != "Base" }
        .sorted { languageName($0) < languageName($1) }

    static func languageName(_ code: String) -> String {
        let name = Locale(identifier: code).localizedString(forIdentifier: code) ?? code
        return name.prefix(1).uppercased() + name.dropFirst()
    }

    var appLanguage: String {
        (UserDefaults.standard.persistentDomain(forName: Bundle.main.bundleIdentifier ?? "")?["AppleLanguages"]
            as? [String])?.first ?? ""
    }

    /// Stores the per-app language and relaunches (AppKit reads it only at startup).
    func setAppLanguage(_ code: String) {
        guard code != appLanguage else { return }
        if code.isEmpty {
            UserDefaults.standard.removeObject(forKey: "AppleLanguages")
        } else {
            UserDefaults.standard.set([code], forKey: "AppleLanguages")
        }
        UserDefaults.standard.synchronize()
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "sleep 1; /usr/bin/open \"\(Bundle.main.bundlePath)\""]
        try? p.run()
        NSApp.terminate(nil)
    }

    /// Bring this chat to the front (Claude app deep link / Codex app).
    func open(_ session: AgentSession) {
        guard let loc = scriptLocation else { return }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: loc.python)
        p.arguments = [loc.script, "open", session.id]
        try? p.run()
    }

    /// «Открыть чат» during a conversation: release the hook silently and jump to the chat.
    func openActive() {
        guard let sid = active?.session_id else { return }
        send("cancel")
        let entry = (sessions + recent).first { $0.id == sid }
        if let entry { open(entry) } else { openByID(sid) }
    }

    private func openByID(_ id: String) {
        guard let loc = scriptLocation else { return }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: loc.python)
        p.arguments = [loc.script, "open", id]
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

    /// Downloaded whisper models; tag "" = automatic (large-v3-turbo when present).
    static func whisperModels() -> [(path: String, label: String)] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        var urls: [URL] = []
        let own = home.appendingPathComponent(".voice-loop/models")
        urls += ((try? FileManager.default.contentsOfDirectory(at: own, includingPropertiesForKeys: nil)) ?? [])
        let hf = home.appendingPathComponent(".cache/huggingface/hub/models--ggerganov--whisper.cpp/snapshots")
        for snap in (try? FileManager.default.contentsOfDirectory(at: hf, includingPropertiesForKeys: nil)) ?? [] {
            urls += (try? FileManager.default.contentsOfDirectory(at: snap, includingPropertiesForKeys: nil)) ?? []
        }
        var out: [(String, String)] = [("", String(localized: "Automatic (best available)"))]
        for u in urls where u.lastPathComponent.hasPrefix("ggml-") && u.pathExtension == "bin" {
            let size = (try? u.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            guard size > 50_000_000 else { continue }  // still downloading
            let name = u.deletingPathExtension().lastPathComponent
                .replacingOccurrences(of: "ggml-", with: "")
            out.append((u.path, "\(name) · \(size / 1_000_000) MB"))
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

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let s = model.active {
                // New identity per conversation step: the reply field never carries text over
                // into another state or another session.
                ConversationView(model: model, s: s)
                    .id("\(s.project ?? "")|\(s.state)")
            } else if model.isSquare {
                IdleBadge(muted: model.muted)
            } else {
                IdleHeader(model: model)
            }
            if !model.sessions.isEmpty {
                Divider().opacity(0.4)
                SessionList(sessions: model.sessions, detailed: model.expanded || model.active != nil,
                            wide: model.active != nil,
                            open: { model.open($0) }) {
                    s in s.status == "finished" && model.active == nil ? { model.dictate(to: s) } : nil
                }
            }
            if model.expanded && model.active == nil && !model.recent.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                Divider().opacity(0.4)
                Text(String(localized: "Recent"))
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 12)
                    .padding(.top, 8)
                SessionList(sessions: Array(model.recent.prefix(model.showMoreRecent ? 10 : 5)),
                            detailed: true, wide: false, open: { model.open($0) }) { s in
                    model.active == nil ? { model.dictate(to: s) } : nil
                }
                if model.recent.count > 5 && !model.showMoreRecent {
                    Button {
                        model.showMoreRecent = true
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "ellipsis").frame(width: 10)
                            Text(String(localized: "More \(model.recent.count - 5)"))
                        }
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 12)
                        .padding(.bottom, 8)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        // Narrow pill; hover only unfolds it downward. Full width only while talking/dictating.
        .frame(width: model.active != nil ? 380 : (model.isSquare ? IdleBadge.side : 190), alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.white.opacity(0.08)))
        .background(GeometryReader { g in
            Color.clear
                .onAppear { model.cardFrame = g.frame(in: .global) }
                .onChange(of: g.frame(in: .global)) { _, f in model.cardFrame = f }
        })
        .animation(.spring(response: 0.32, dampingFraction: 0.88), value: model.expanded)
        .animation(.spring(response: 0.32, dampingFraction: 0.88), value: model.isSquare)
        .animation(.spring(response: 0.32, dampingFraction: 0.88), value: model.showMoreRecent)
        .animation(.spring(response: 0.32, dampingFraction: 0.88), value: model.active?.state)
        .padding(.top, 4)
        // The window never resizes (that caused the jitter): the card sits at the top of a fixed,
        // transparent canvas and grows downward inside it.
        .frame(width: HUDPanel.canvas.width, height: HUDPanel.canvas.height, alignment: .top)
    }
}

struct IdleBadge: View {
    static let side: CGFloat = 40
    let muted: Bool

    var body: some View {
        Group {
            if muted {
                Image(systemName: "speaker.slash.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.orange)
            } else {
                LogoView()  // edge to edge, no inset
            }
        }
        .frame(width: Self.side, height: Self.side)
        .help(muted ? String(localized: "Muted") : "voice-loop")
    }
}

struct IdleHeader: View {
    @Bindable var model: Model

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: model.muted ? "speaker.slash" : "waveform").foregroundStyle(.secondary)
            Text(headline).font(.system(size: 12, weight: .medium)).lineLimit(1)
            Spacer(minLength: 8)
            Button { model.setMuted(!model.muted) } label: {
                Image(systemName: model.muted ? "speaker.slash.fill" : "speaker.wave.2")
                    .foregroundStyle(model.muted ? .orange : .secondary)
            }
            .buttonStyle(.borderless)
            .help(model.muted ? String(localized: "Unmute") : String(localized: "Mute (meeting): don’t speak or listen"))
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
        if working > 0 { parts.append(String(localized: "in progress \(working)")) }
        if done > 0 { parts.append(String(localized: "done \(done)")) }
        let base = parts.isEmpty ? String(localized: "Voice on") : parts.joined(separator: " · ").capitalizedFirst
        // Collapsed: the crossed-out speaker already says «без звука».
        // The crossed-out speaker already says «без звука».
        return model.muted && parts.isEmpty ? String(localized: "Muted") : base
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

    // One fixed layout for every step of a conversation: same height, buttons never move
    // (switching from «speaking» to «listening» used to shrink the card → misclicks).
    static let textHeight: CGFloat = 60

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            header

            LevelBar(level: s.level ?? 0)
                .opacity(s.state == "listening" ? 1 : 0)

            Group {
                if s.state == "confirming" && editMode {
                    TextField(String(localized: "Edit and press ↩"), text: $typed, axis: .vertical)
                        .textFieldStyle(.roundedBorder)
                        .lineLimit(1...5)
                        .focused($editing)
                        .onSubmit { model.reply(typed) }
                } else {
                    Text(bodyText ?? "")
                        .foregroundStyle(s.state == "speaking" ? .secondary : .primary)
                        .lineLimit(4)
                        .textSelection(.enabled)
                }
            }
            .font(.system(size: 12))
            .frame(maxWidth: .infinity, minHeight: Self.textHeight, maxHeight: Self.textHeight, alignment: .topLeading)

            TextField(String(localized: "Type a reply and press ↩"), text: $typed)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12))
                .onSubmit {
                    model.reply(typed)
                    typed = ""
                }
                .opacity(replyField ? 1 : 0)
                .disabled(!replyField)

            buttonRow
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .padding(.bottom, 10)
    }

    private var replyField: Bool { s.state == "speaking" || s.state == "listening" }

    @ViewBuilder private var header: some View {
        HStack(spacing: 8) {
            icon.font(.system(size: 15, weight: .semibold)).frame(width: 20)
            Text(title).font(.system(size: 13, weight: .semibold))
                .lineLimit(1)
                .fixedSize()
            if let project = s.project {
                Text(project).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                    .onTapGesture { if s.session_id != nil { model.openActive() } }
                    .help(s.session_id != nil ? String(localized: "Open this chat") : "")
            }
            Spacer(minLength: 12)
            if s.state == "listening", let left = s.left {
                Text(String(localized: "\(Int(left.rounded(.up))) s"))
                    .font(.system(size: 12).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            if s.session_id != nil && ["speaking", "listening", "phone"].contains(s.state) {
                Button { model.openActive() } label: { Image(systemName: "arrow.up.forward.app") }
                    .buttonStyle(.borderless)
                    .help(String(localized: "Open this chat and reply there"))
            }
            if ["sent", "released", "error"].contains(s.state) {
                Button { model.dismissedAt = s.t } label: { Image(systemName: "xmark") }
                    .buttonStyle(.borderless)
                    .help(String(localized: "Close"))
            }
        }
        .frame(height: 20)
    }

    /// [Cancel] [secondary …]  Spacer  [Primary] — natural widths; «Cancel» is always first on the
    /// left and the primary button always at the right edge, so neither moves between steps.
    @ViewBuilder private var buttonRow: some View {
        HStack(spacing: 8) {
            cancelSlot
            switch s.state {
            case "speaking", "listening":
                Button(String(localized: "Repeat")) { model.send("repeat") }
                    .disabled(s.state != "listening")
            case "confirming" where !editMode:
                HStack(spacing: 8) {
                    Button(String(localized: "Edit")) {
                        typed = s.text ?? ""
                        editMode = true
                        editing = true
                        model.send("hold")  // stop the countdown while editing
                    }
                    Button(String(localized: "Add more")) { model.send("append") }
                        .help(String(localized: "Keep the text and dictate more"))
                    Button(String(localized: "Say again")) { model.send("again") }
                }
                .buttonStyle(.link)
                .font(.system(size: 11))
            default:
                EmptyView()
            }
            Spacer(minLength: 0)
            primarySlot
        }
        .controlSize(.small)
        .frame(height: 22)
    }

    @ViewBuilder private var cancelSlot: some View {
        switch s.state {
        case "speaking", "listening", "phone", "confirming":
            Button(String(localized: "Cancel")) { model.send("cancel") }
        case "sent" where s.cancellable == true && s.delivery != "clipboard" && !cancelled:
            if let sid = s.session_id {
                Button(String(localized: "Undo")) {
                    model.cancelSent(sid)
                    cancelled = true
                }
                .help(String(localized: "Claude will stop: all its next actions will be blocked"))
            }
        default:
            EmptyView()
        }
    }

    @ViewBuilder private var primarySlot: some View {
        switch s.state {
        case "speaking":
            Button(String(localized: "Skip")) { model.send("skip") }.keyboardShortcut(.defaultAction)
        case "listening", "phone":
            Button(String(localized: "Send")) { model.send("send") }.keyboardShortcut(.defaultAction)
        case "confirming":
            Button(editMode ? String(localized: "Send") : String(localized: "Send now")) {
                editMode ? model.reply(typed) : model.send("send")
            }
            .keyboardShortcut(.defaultAction)
        case "transcribing":
            Button(String(localized: "Send")) {}.disabled(true)
        default:
            EmptyView()
        }
    }

    private var bodyText: String? {
        switch s.state {
        case "speaking": s.summary
        case _ where s.state == "sent" && s.delivery == "clipboard":
            String(localized: "Copied. Paste into “\(s.project ?? "")” in Claude: ⌘V and ↩\n\n\(s.text ?? "")")
        case "listening", "transcribing", "sent": s.text
        case "confirming": editMode ? nil : s.text
        case "error": errorText(code: s.code, detail: s.text)
        default: nil
        }
    }

    private var title: String {
        switch s.state {
        case "speaking": String(localized: "Speaking")
        case "listening": String(localized: "Listening")
        case "transcribing": String(localized: "Transcribing…")
        case "phone": String(localized: "Speak into the iPhone…")
        case "confirming": editMode ? String(localized: "Edit the text")
            : s.left.map { String(localized: "Sending in \(Int($0.rounded(.up))) s") } ?? String(localized: "Sending when you press ↩")
        case "sent" where cancelled: String(localized: "Cancelled, Claude will stop")
        case "sent": s.delivery == "clipboard" ? String(localized: "In the clipboard") : s.delivery == "queued" ? String(localized: "Added to Codex") : String(localized: "Sent")
        case "released": String(localized: "Session released")
        case "error": String(localized: "Didn’t work")
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
    /// Wide panel: project/status label too; narrow: time only.
    var wide = true
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
                            if wide {
                                Text(label(s))
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            Text(s.status == "idle" || s.status == "finished"
                                 ? (wide ? ago(s.ended ?? s.updated, now: now) : short(s.ended ?? s.updated, now: now))
                                 : elapsed(since: s.since, now: now))
                                .font(.system(size: 11).monospacedDigit())
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .help("\(s.project) · \(label(s))")
    }

    private func short(_ t: Double, now: Date) -> String {
        let m = max(0, Int(now.timeIntervalSince1970 - t)) / 60
        if m < 60 { return String(localized: "\(max(m, 1)) min") }
        return m < 24 * 60 ? String(localized: "\(m / 60) h") : String(localized: "\(m / 1440) d")
    }

    private func ago(_ t: Double, now: Date) -> String {
        let m = max(0, Int(now.timeIntervalSince1970 - t)) / 60
        if m < 1 { return String(localized: "just now") }
        if m < 60 { return String(localized: "\(m) min ago") }
        if m < 24 * 60 { return String(localized: "\(m / 60) h ago") }
        return String(localized: "\(m / 1440) d ago")
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
        case "waiting": String(localized: "waiting for you")
        case "finished": String(localized: "done")
        case "idle": s.project
        case "stopping": String(localized: "stopping…")
        default: s.project
        }
    }

    private func elapsed(since: Double, now: Date) -> String {
        let sec = max(0, Int(now.timeIntervalSince1970 - since))
        return sec < 60 ? String(localized: "\(sec) s") : String(localized: "\(sec / 60) min")
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
                .help(String(localized: "Dictate a message to this chat"))
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: 6).fill(hover ? Color.primary.opacity(0.07) : .clear))
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .onTapGesture(perform: open)
        .help(String(localized: "Open chat"))
    }
}

struct SettingsMenu: View {
    @Bindable var model: Model

    var body: some View {
        Menu {
            Toggle(String(localized: "Voice mode"), isOn: Binding(get: { model.enabled }, set: { model.setEnabled($0) }))
            Toggle(String(localized: "Mute (meeting)"), isOn: Binding(get: { model.muted }, set: { model.setMuted($0) }))
            Divider()
            Picker(String(localized: "Voice"), selection: Binding(get: { model.voice }, set: { model.setVoice($0) })) {
                ForEach(model.voices) { Text($0.label).tag($0) }
            }
            Button(String(localized: "Preview voice")) { model.previewVoice() }
            Picker(String(localized: "Recognition model"), selection: Binding(
                get: { model.config["model"] as? String ?? "" }, set: { model.set("model", $0) })) {
                ForEach(Model.whisperModels(), id: \.path) { m in
                    Text(m.label).tag(m.path)
                }
            }
            Picker(String(localized: "Pause before sending"), selection: Binding(
                get: { model.double("silence_sec", 2.0) }, set: { model.set("silence_sec", $0) })) {
                ForEach([1.5, 2.0, 2.5, 3.0], id: \.self) { Text(String(format: String(localized: "%.1f s"), $0)).tag($0) }
            }
            Picker(String(localized: "Time to undo"), selection: Binding(
                get: { model.double("undo_sec", 3.0) }, set: { model.set("undo_sec", $0) })) {
                Text(String(localized: "don’t wait")).tag(0.0)
                ForEach([2.0, 3.0, 5.0], id: \.self) { Text(String(localized: "\(Int($0)) s")).tag($0) }
            }
            Picker(String(localized: "Time to start speaking"), selection: Binding(
                get: { model.double("wait_sec", 5.0) }, set: { model.set("wait_sec", $0) })) {
                ForEach([5.0, 8.0, 10.0, 15.0], id: \.self) { Text(String(localized: "\(Int($0)) s")).tag($0) }
            }
            Menu(String(localized: "Projects")) {
                Button(model.projects.isEmpty ? String(localized: "✓ All projects") : String(localized: "All projects")) { model.set("projects", [String]()) }
                Divider()
                ForEach(model.knownProjects, id: \.self) { p in
                    Button(model.projects.contains(p) ? "✓ \(p)" : p) { model.toggleProject(p) }
                }
            }
            Divider()
            Section("iPhone") {
                Text(String(localized: "Pairing code: \(String(model.pairingCode.prefix(3))) \(String(model.pairingCode.suffix(3)))"))
                Text(model.phones > 0 ? String(localized: "Connected: \(model.phones)") : String(localized: "No phone connected"))
                Button(String(localized: "New code (disconnects the phone)")) { model.onNewPairingCode?() }
            }
            Divider()
            Picker(String(localized: "Language"), selection: Binding(
                get: { model.appLanguage }, set: { model.setAppLanguage($0) })) {
                Text(String(localized: "System")).tag("")
                Divider()
                ForEach(Model.appLanguages, id: \.self) { code in
                    Text(Model.languageName(code)).tag(code)
                }
            }
            Toggle(String(localized: "Open at login"), isOn: $model.launchAtLogin)
            Toggle(String(localized: "Show panel"), isOn: $model.showHUD)
            Toggle(String(localized: "Hide when an iPhone is connected"), isOn: $model.hideWhenPhone)
            Button(String(localized: "Open log")) { NSWorkspace.shared.open(logURL) }
            Button(String(localized: "Quit")) { NSApp.terminate(nil) }
        } label: {
            Image(systemName: "gearshape")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }
}

/// Script errors arrive as codes so they can be shown in the user's language.
func errorText(code: String?, detail: String?) -> String {
    switch code {
    case "no_mic":
        String(localized: "No microphone access. Allow it for voice-loop: System Settings → Privacy & Security → Microphone.")
    default:
        String(localized: "Something went wrong: \(detail ?? "")")
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
    static let canvas = CGSize(width: 400, height: 760)
    private let host: FirstMouseHostingView<HUDRoot>
    private let model: Model
    private var hoverSince: Date?

    init(model: Model) {
        self.model = model
        host = FirstMouseHostingView(rootView: HUDRoot(model: model))
        host.sizingOptions = []
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

    /// Default: top centre, below browser tab bars; afterwards wherever the user dragged it.
    func placeTopCenter() {
        guard let screen = NSScreen.main else { return }
        let f = screen.visibleFrame
        var origin = NSPoint(x: f.midX - Self.canvas.width / 2, y: f.maxY - Self.canvas.height - 96)
        if let saved = UserDefaults.standard.string(forKey: "panelOrigin") {
            let p = NSPointFromString(saved)
            if NSScreen.screens.contains(where: { $0.frame.contains(NSPoint(x: p.x + Self.canvas.width / 2,
                                                                         y: p.y + Self.canvas.height - 20)) }) {
                origin = p
            }
        }
        setFrame(NSRect(origin: origin, size: Self.canvas), display: true)
        NotificationCenter.default.addObserver(forName: NSWindow.didMoveNotification, object: self,
                                               queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                UserDefaults.standard.set(NSStringFromPoint(self.frame.origin), forKey: "panelOrigin")
            }
        }
    }

    /// Called ~20×/s: the panel takes the mouse only over the card (the rest of the canvas is
    /// see-through and click-through), and hover is decided by geometry, not enter/exit events.
    func trackMouse() {
        let card = model.cardFrame
        let screenCard = NSRect(x: frame.minX + card.minX, y: frame.maxY - card.maxY,
                                width: card.width, height: card.height)
        let inside = screenCard.insetBy(dx: -2, dy: -2).contains(NSEvent.mouseLocation)
        if ignoresMouseEvents == inside { ignoresMouseEvents = !inside }
        if inside {
            hoverSince = nil
            if !model.expanded { model.expanded = true }
        } else if model.expanded {
            // Short grace period so moving the cursor along the edge doesn't flicker.
            if let since = hoverSince {
                if Date().timeIntervalSince(since) > 0.4 {
                    model.expanded = false
                    model.showMoreRecent = false
                    hoverSince = nil
                }
            } else {
                hoverSince = Date()
            }
        }
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
        Task { @MainActor [weak self] in
            while true {
                if let p = self?.panel, p.isVisible { p.trackMouse() }
                try? await Task.sleep(for: .milliseconds(50))
            }
        }
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
        Toggle(String(localized: "Voice mode"), isOn: Binding(get: { model.enabled }, set: { model.setEnabled($0) }))
        Toggle(String(localized: "Mute (meeting)"), isOn: Binding(get: { model.muted }, set: { model.setMuted($0) }))
        Toggle(String(localized: "Show panel"), isOn: $model.showHUD)
        Toggle(String(localized: "Open at login"), isOn: $model.launchAtLogin)
        Divider()
        Button(String(localized: "Quit")) { NSApp.terminate(nil) }.keyboardShortcut("q")
    }
}
