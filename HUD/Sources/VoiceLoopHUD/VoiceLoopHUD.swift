import AppKit
import Observation
import SwiftUI

// Reads ~/.voice-loop/state.json (written by voice_loop.py), writes ~/.voice-loop/control
// (send | cancel | skip) and toggles ~/.voice-loop/enabled. The script works without this app.

private let stateDir = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent(".voice-loop")
private let stateURL = stateDir.appendingPathComponent("state.json")
private let controlURL = stateDir.appendingPathComponent("control")
private let flagURL = stateDir.appendingPathComponent("enabled")

struct VoiceState: Decodable, Equatable {
    var state: String
    var project: String?
    var summary: String?
    var text: String?
    var level: Double?
    var left: Double?
    var t: Double
}

@MainActor @Observable
final class Model {
    var current: VoiceState?
    var enabled = FileManager.default.fileExists(atPath: flagURL.path)
    var showHUD = true

    /// States worth showing, and how long a finished state lingers.
    var visible: Bool {
        guard showHUD, let s = current else { return false }
        let age = Date().timeIntervalSince1970 - s.t
        switch s.state {
        case "speaking", "listening", "transcribing": return age < 200  // hook is killed at 180 s
        case "sent": return age < 4
        case "released": return age < 1.5
        default: return false
        }
    }

    func poll() {
        enabled = FileManager.default.fileExists(atPath: flagURL.path)
        guard let data = try? Data(contentsOf: stateURL),
              let s = try? JSONDecoder().decode(VoiceState.self, from: data) else { return }
        if s != current { current = s }
    }

    func send(_ command: String) {
        try? command.write(to: controlURL, atomically: true, encoding: .utf8)
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
}

struct HUDView: View {
    let model: Model

    var body: some View {
        let s = model.current
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                icon(s?.state)
                    .font(.system(size: 15, weight: .semibold))
                    .frame(width: 20)
                Text(title(s?.state))
                    .font(.system(size: 13, weight: .semibold))
                if let project = s?.project {
                    Text(project).font(.system(size: 12)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 12)
                if s?.state == "listening", let left = s?.left {
                    Text("\(Int(left.rounded(.up))) с")
                        .font(.system(size: 12).monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }

            if s?.state == "listening" {
                LevelBar(level: s?.level ?? 0)
            }

            if let line = body(for: s), !line.isEmpty {
                Text(line)
                    .font(.system(size: 12))
                    .foregroundStyle(s?.state == "speaking" ? .secondary : .primary)
                    .lineLimit(4)
                    .fixedSize(horizontal: false, vertical: true)
            }

            buttons(s?.state)
        }
        .padding(14)
        .frame(width: 380, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.white.opacity(0.08)))
        .padding(8)
    }

    private func body(for s: VoiceState?) -> String? {
        switch s?.state {
        case "speaking": return s?.summary
        case "listening", "transcribing", "sent": return s?.text
        default: return nil
        }
    }

    @ViewBuilder private func buttons(_ state: String?) -> some View {
        HStack {
            Spacer()
            switch state {
            case "speaking":
                Button("Отмена") { model.send("cancel") }
                Button("Пропустить") { model.send("skip") }.keyboardShortcut(.defaultAction)
            case "listening":
                Button("Отмена") { model.send("cancel") }
                Button("Отправить") { model.send("send") }.keyboardShortcut(.defaultAction)
            default:
                EmptyView()
            }
        }
        .controlSize(.small)
    }

    private func title(_ state: String?) -> String {
        switch state {
        case "speaking": return "Говорю"
        case "listening": return "Слушаю"
        case "transcribing": return "Распознаю…"
        case "sent": return "Отправлено"
        case "released": return "Сессия отпущена"
        default: return ""
        }
    }

    @ViewBuilder private func icon(_ state: String?) -> some View {
        switch state {
        case "speaking": Image(systemName: "speaker.wave.2.fill").foregroundStyle(.blue)
        case "listening": Image(systemName: "mic.fill").foregroundStyle(.red)
        case "transcribing": ProgressView().controlSize(.small)
        case "sent": Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        default: Image(systemName: "moon.zzz").foregroundStyle(.secondary)
        }
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

/// Buttons react to the first click even though the panel never becomes active.
final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Non-activating floating panel: clickable without stealing focus from the editor.
final class HUDPanel: NSPanel {
    private let host: FirstMouseHostingView<HUDView>

    init(model: Model) {
        host = FirstMouseHostingView(rootView: HUDView(model: model))
        host.sizingOptions = [.intrinsicContentSize]
        super.init(contentRect: .zero, styleMask: [.nonactivatingPanel, .borderless],
                   backing: .buffered, defer: false)
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        isMovableByWindowBackground = true
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        hidesOnDeactivate = false
        contentView = host
    }

    override var canBecomeKey: Bool { true }

    private var contentFit: NSSize {
        host.intrinsicContentSize
    }

    func placeTopCenter() {
        guard let screen = NSScreen.main else { return }
        let size = contentFit
        let f = screen.visibleFrame
        setFrame(NSRect(x: f.midX - size.width / 2, y: f.maxY - size.height - 8,
                        width: size.width, height: size.height), display: true)
    }

    /// Resize to fit content, keeping the top edge where the user left it.
    func fitKeepingTop() {
        let size = contentFit
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
        Toggle("Голосовой режим", isOn: Binding(get: { model.enabled },
                                                 set: { model.setEnabled($0) }))
        Toggle("Показывать плашку", isOn: $model.showHUD)
        Divider()
        Button("Выйти") { NSApp.terminate(nil) }.keyboardShortcut("q")
    }
}
