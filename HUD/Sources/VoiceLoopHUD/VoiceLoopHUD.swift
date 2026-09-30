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
private let configURL = stateDir.appendingPathComponent("config.json")
private let logURL = stateDir.appendingPathComponent("log.txt")
private let voicesDir = stateDir.appendingPathComponent("voices")
private let script = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("SwiftUI/voice-loop/voice_loop.py")

struct VoiceState: Decodable, Equatable {
    var state: String
    var project: String?
    var summary: String?
    var text: String?
    var level: Double?
    var left: Double?
    var t: Double
}

struct AgentSession: Decodable, Equatable, Identifiable {
    var id: String = ""
    var project: String
    var title: String
    var status: String  // working | waiting
    var since: Double
    var updated: Double
    var transcript: String?

    enum CodingKeys: String, CodingKey { case project, title, status, since, updated, transcript }
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
    var sessions: [AgentSession] = []
    var enabled = FileManager.default.fileExists(atPath: flagURL.path)
    var showHUD = true
    var expanded = false
    var config: [String: Any] = [:]
    var voices: [Voice] = []
    var knownProjects: [String] = []

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
        case "speaking", "listening", "transcribing": return age < 200 ? s : nil  // hook dies at 180 s
        case "sent": return age < 4 ? s : nil
        case "released": return age < 1.5 ? s : nil
        default: return nil
        }
    }

    var visible: Bool { showHUD && (enabled || active != nil) }

    func poll() {
        enabled = FileManager.default.fileExists(atPath: flagURL.path)
        if let data = try? Data(contentsOf: stateURL),
           let s = try? JSONDecoder().decode(VoiceState.self, from: data), s != current {
            current = s
        }
        let live = Self.liveSessions()
        if live != sessions { sessions = live }
        for p in live.map(\.project) where !knownProjects.contains(p) { knownProjects.append(p) }
    }

    /// Sessions in progress. A session whose transcript hasn't changed for 20 min was most
    /// likely interrupted (no Stop hook fires then), so it is hidden.
    private static func liveSessions() -> [AgentSession] {
        guard let data = try? Data(contentsOf: sessionsURL),
              let dict = try? JSONDecoder().decode([String: AgentSession].self, from: data) else { return [] }
        let now = Date().timeIntervalSince1970
        return dict.compactMap { id, s -> AgentSession? in
            var s = s
            s.id = id
            var lastSeen = s.updated
            if let path = s.transcript,
               let m = try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate] as? Date {
                lastSeen = max(lastSeen, m.timeIntervalSince1970)
            }
            return now - lastSeen < 20 * 60 ? s : nil
        }
        .sorted { $0.since < $1.since }
    }

    // MARK: commands

    func send(_ command: String) {
        try? command.write(to: controlURL, atomically: true, encoding: .utf8)
    }

    func reply(_ text: String) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !t.isEmpty { send("text\n\(t)") }
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
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/python3")
        p.arguments = [script.path, "say", "Привет! Так я буду рассказывать, что сделал кодекс или клод."]
        try? p.run()
    }

    var projects: [String] { config["projects"] as? [String] ?? [] }

    func toggleProject(_ name: String) {
        var list = projects
        if let i = list.firstIndex(of: name) { list.remove(at: i) } else { list.append(name) }
        set("projects", list)
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
                ConversationView(model: model, s: s)
            } else {
                IdleHeader(model: model)
            }
            if !model.sessions.isEmpty {
                Divider().opacity(0.4)
                SessionList(sessions: model.sessions, detailed: model.expanded || model.active != nil)
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
            Image(systemName: "waveform").foregroundStyle(.secondary)
            Text(model.sessions.isEmpty ? "Голос включён" : "В работе: \(model.sessions.count)")
                .font(.system(size: 12, weight: .medium))
            Spacer(minLength: 8)
            if model.expanded {
                SettingsMenu(model: model)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

struct ConversationView: View {
    @Bindable var model: Model
    let s: VoiceState
    @State private var typed = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                icon.font(.system(size: 15, weight: .semibold)).frame(width: 20)
                Text(title).font(.system(size: 13, weight: .semibold))
                if let project = s.project {
                    Text(project).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 12)
                if s.state == "listening", let left = s.left {
                    Text("\(Int(left.rounded(.up))) с")
                        .font(.system(size: 12).monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }

            if s.state == "listening" {
                LevelBar(level: s.level ?? 0)
            }

            if let line = bodyText, !line.isEmpty {
                Text(line)
                    .font(.system(size: 12))
                    .foregroundStyle(s.state == "speaking" ? .secondary : .primary)
                    .lineLimit(5)
                    .fixedSize(horizontal: false, vertical: true)
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
        case "listening", "transcribing", "sent": s.text
        default: nil
        }
    }

    private var title: String {
        switch s.state {
        case "speaking": "Говорю"
        case "listening": "Слушаю"
        case "transcribing": "Распознаю…"
        case "sent": "Отправлено"
        case "released": "Сессия отпущена"
        default: ""
        }
    }

    @ViewBuilder private var icon: some View {
        switch s.state {
        case "speaking": Image(systemName: "speaker.wave.2.fill").foregroundStyle(.blue)
        case "listening": Image(systemName: "mic.fill").foregroundStyle(.red)
        case "transcribing": ProgressView().controlSize(.small)
        case "sent": Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        default: Image(systemName: "moon.zzz").foregroundStyle(.secondary)
        }
    }
}

struct SessionList: View {
    let sessions: [AgentSession]
    let detailed: Bool

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            VStack(alignment: .leading, spacing: 6) {
                ForEach(sessions) { s in
                    HStack(spacing: 8) {
                        Image(systemName: "circle.fill")
                            .font(.system(size: 7))
                            .foregroundStyle(s.status == "waiting" ? .blue : .orange)
                            .symbolEffect(.pulse, options: .repeating)
                        Text(s.title)
                            .font(.system(size: 12))
                            .lineLimit(1)
                            .truncationMode(.tail)
                        Spacer(minLength: 6)
                        if detailed {
                            Text(s.status == "waiting" ? "ждёт ответа" : s.project)
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                            Text(elapsed(since: s.since, now: context.date))
                                .font(.system(size: 11).monospacedDigit())
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .help("\(s.project) · \(s.status == "waiting" ? "ждёт ответа" : "в работе")")
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
        }
    }

    private func elapsed(since: Double, now: Date) -> String {
        let sec = max(0, Int(now.timeIntervalSince1970 - since))
        return sec < 60 ? "\(sec) с" : "\(sec / 60) мин"
    }
}

struct SettingsMenu: View {
    @Bindable var model: Model

    var body: some View {
        Menu {
            Toggle("Голосовой режим", isOn: Binding(get: { model.enabled }, set: { model.setEnabled($0) }))
            Divider()
            Picker("Голос", selection: Binding(get: { model.voice }, set: { model.setVoice($0) })) {
                ForEach(model.voices) { Text($0.label).tag($0) }
            }
            Button("Прослушать голос") { model.previewVoice() }
            Picker("Пауза, после которой отправляю", selection: Binding(
                get: { model.double("silence_sec", 2.0) }, set: { model.set("silence_sec", $0) })) {
                ForEach([1.5, 2.0, 2.5, 3.0], id: \.self) { Text(String(format: "%.1f с", $0)).tag($0) }
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
            Toggle("Запускать при входе в систему", isOn: $model.launchAtLogin)
            Toggle("Показывать плашку", isOn: $model.showHUD)
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
    private var placed = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        panel = HUDPanel(model: model)
        Task { @MainActor in
            while true {
                tick()
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
    }

    private func tick() {
        model.poll()
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
            Image(systemName: delegate.model.enabled ? "waveform" : "waveform.slash")
        }
    }
}

struct MenuContent: View {
    @Bindable var model: Model

    var body: some View {
        Toggle("Голосовой режим", isOn: Binding(get: { model.enabled }, set: { model.setEnabled($0) }))
        Toggle("Показывать плашку", isOn: $model.showHUD)
        Toggle("Запускать при входе в систему", isOn: $model.launchAtLogin)
        Divider()
        Button("Выйти") { NSApp.terminate(nil) }.keyboardShortcut("q")
    }
}
