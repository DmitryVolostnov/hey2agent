import AVFoundation
import Network
import SwiftUI
import TipKit
import UIKit
import VoiceLoopLink

// MARK: - Pairing

struct PairingView: View {
    @Bindable var model: RemoteModel
    @State private var code = ""
    @State private var selected: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    if model.macs.isEmpty {
                        HStack(spacing: 10) {
                            ProgressView()
                            Text(String(localized: "Looking for a Mac running hey2agent on this network…")).foregroundStyle(.secondary)
                        }
                    }
                    ForEach(model.macs, id: \.endpoint) { r in
                        let name = RemoteModel.name(r)
                        Button {
                            selected = name
                        } label: {
                            HStack {
                                Image(systemName: "laptopcomputer")
                                Text(name)
                                Spacer()
                                if selected == name { Image(systemName: "checkmark") }
                            }
                        }
                        .foregroundStyle(.primary)
                    }
                } header: {
                    Text("Mac")
                } footer: {
                    Text(String(localized: "The hey2agent panel must be running and the phone and Mac on the same Wi-Fi."))
                }

                Section {
                    TextField(String(localized: "6 digits"), text: $code)
                        .keyboardType(.numberPad)
                        .font(.title2.monospacedDigit())
                        .onChange(of: code) { _, new in
                            let clean = String(new.filter(\.isNumber).prefix(6))
                            if clean != new { code = clean }
                        }
                } header: {
                    Text(String(localized: "Pairing code"))
                } footer: {
                    Text(String(localized: "On the Mac: hover the panel → gear → “Pairing code”. The code encrypts the connection; nothing goes to the internet."))
                }

                if model.status == .badCode {
                    Text(String(localized: "Wrong code. Check the digits on the Mac.")).foregroundStyle(.red)
                }

                Button(String(localized: "Connect")) {
                    if let r = model.macs.first(where: { RemoteModel.name($0) == selected }) {
                        model.pair(r, code: code)
                    }
                }
                .disabled(selected == nil || code.count != 6)
            }
            .navigationTitle("hey2agent")
            .onAppear { selected = selected ?? model.macs.first.map(RemoteModel.name) }
            .onChange(of: model.macs.count) { _, _ in
                if selected == nil { selected = model.macs.first.map(RemoteModel.name) }
            }
        }
    }
}

// MARK: - Remote HUD

struct RemoteView: View {
    @Bindable var model: RemoteModel
    @State private var dismissed: Double?
    @AppStorage("appearance") private var appearance = Appearance.system.rawValue

    var body: some View {
        let snap = model.snapshot
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header(snap)
                if let a = snap?.active, a.t != dismissed {
                    ConversationCard(state: a, send: model.send,
                                     replyByPhone: { model.speaker.stop(); model.recordOnPhone(for: nil) },
                                     close: { dismissed = a.t }, cancel: { model.cancelConversation() },
                                     speaker: model.speaker,
                                     recorder: model.recordingFor == nil ? model.recorder : nil)
                        .id("\(a.project ?? "")|\(a.state)")
                }
                if let s = snap, !s.sessions.isEmpty {
                    SessionSection(title: String(localized: "In progress"), sessions: s.sessions, model: model) { session in
                        session.status == "finished" && s.active == nil
                            ? { model.recordOnPhone(for: session) } : nil
                    }
                }
                if let s = snap, !s.recent.isEmpty {
                    TipView(OpenChatTip())
                    SessionSection(title: String(localized: "Recent"),
                                   sessions: s.recent, model: model) { session in
                        s.active == nil ? { model.recordOnPhone(for: session) } : nil
                    }
                }
            }
            .padding(20)
        }
        .background(AppBackground())
        .overlay(alignment: .bottom) {
            // Dictating into another chat (mic on a row). Answering the running conversation
            // records inside its card instead, like on the Mac.
            if model.recorder.active && (model.recordingFor != nil || model.snapshot?.active == nil) {
                RecordingPanel(model: model).padding(16)
            }
        }
    }

    @ViewBuilder private func header(_ snap: LinkSnapshot?) -> some View {
        HStack(spacing: 10) {
            Circle()
                .fill(model.status == .connected ? Color.green : .orange)
                .frame(width: 8, height: 8)
            Text(model.status == .connected ? (snap?.mac ?? model.macName ?? "Mac") : String(localized: "Reconnecting…"))
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer()
            if let s = snap {
                Button {
                    model.send(.setMuted(!s.muted))
                } label: {
                    Image(systemName: s.muted ? "speaker.slash.fill" : "speaker.wave.2")
                        .font(.title3)
                        .foregroundStyle(s.muted ? .orange : .primary)
                        .frame(width: 44, height: 44)
                        .glassCircle()
                }
                .buttonStyle(.plain)
                .accessibilityLabel(s.muted ? String(localized: "Unmute") : String(localized: "Mute"))
            }
            Menu {
                // iOS has a per-app language switch in Settings; open it.
                Toggle(String(localized: "Read summaries aloud"), isOn: Binding(
                    get: { model.speaker.enabled }, set: { model.speaker.enabled = $0 }))
                Picker(String(localized: "Speech speed"), selection: Binding(
                    get: { model.speaker.speed }, set: { model.speaker.speed = $0 })) {
                    ForEach(Speaker.speeds, id: \.self) { Text("\($0.formatted())×").tag($0) }
                }
                .pickerStyle(.menu)
                Toggle(String(localized: "Listen after reading"), isOn: Binding(
                    get: { model.speaker.listenAfter }, set: { model.speaker.listenAfter = $0 }))
                Picker(String(localized: "Appearance"), selection: $appearance) {
                    ForEach(Appearance.allCases) { Text($0.label).tag($0.rawValue) }
                }
                Button(String(localized: "Language")) {
                    if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                }
                Button(String(localized: "Unpair Mac"), role: .destructive) { model.unpair() }
            } label: {
                Image(systemName: "gearshape").font(.title3).foregroundStyle(.primary)
                    .frame(width: 44, height: 44)
                    .glassCircle()
                    .contentShape(Circle())
            }
            .tint(.primary)
        }
    }
}

struct ConversationCard: View {
    let state: LinkVoiceState
    let send: (LinkCommand) -> Void
    var replyByPhone: () -> Void = {}
    var close: () -> Void = {}
    var cancel: () -> Void = {}
    var speaker: Speaker? = nil
    /// Set while the phone records the answer to this conversation: the card shows it inline.
    var recorder: Recorder? = nil
    @State private var typed = ""
    @State private var showDetails = false
    @State private var editing = false
    @State private var cancelled = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Group { if recording { Image(systemName: "mic.fill").foregroundStyle(.red) } else { icon } }
                    .font(.title2).frame(width: 30)
                VStack(alignment: .leading, spacing: 2) {
                    Text(recording ? (recorder?.speaking == true ? String(localized: "Listening…") : String(localized: "Speak"))
                         : title).font(.title3.weight(.semibold))
                    if let p = state.project {
                        Text(p).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Spacer()
                if recording, let left = recorder?.secondsLeft {
                    Text(String(localized: "\(Int(left.rounded(.up))) s")).font(.title3.monospacedDigit()).foregroundStyle(.secondary)
                } else if !recording, state.state == "listening", let left = state.left {
                    Text(String(localized: "\(Int(left.rounded(.up))) s")).font(.title3.monospacedDigit()).foregroundStyle(.secondary)
                }
                if ["sent", "released", "error"].contains(state.state) {
                    Button(action: close) { Image(systemName: "xmark.circle.fill").font(.title2) }
                        .foregroundStyle(.secondary)
                        .accessibilityLabel(String(localized: "Close"))
                }
                if let sid = state.session_id, ["speaking", "listening", "phone", "reading"].contains(state.state) {
                    Button { send(.open(session: sid)) } label: {
                        Image(systemName: "arrow.up.forward.app").font(.title2)
                    }
                    .accessibilityLabel(String(localized: "Open the chat on the Mac"))
                }
            }

            if !compact {
                let level = recording ? (recorder?.level ?? 0) : (state.level ?? 0)
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(.quaternary)
                        Capsule().fill(.red.gradient)
                            .frame(width: max(6, geo.size.width * level))
                            .animation(.linear(duration: 0.12), value: level)
                    }
                }
                .frame(height: 6)
                .opacity(recording || state.state == "listening" ? 1 : 0)
            }

            // Fixed height for every live step so the buttons below never move between states;
            // a finished step (sent / cancelled / error) shrinks to its text.
            Text((recording ? state.summary : bodyText) ?? "")
                .font(.title3)
                .foregroundStyle(state.state == "speaking" || recording ? .secondary : .primary)
                .lineLimit(6)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, minHeight: compact ? 0 : 150, maxHeight: compact ? nil : 150,
                       alignment: .topLeading)
                .fixedSize(horizontal: false, vertical: compact)

            let field = !recording && (editing || ["speaking", "listening", "reading", "phone"].contains(state.state))
            if !compact {
                HStack {
                    // Single line so Return sends; editing a recognised text keeps multi-line.
                    Group {
                        if editing {
                            TextField(String(localized: "Edit the text"), text: $typed, axis: .vertical)
                                .lineLimit(1...5)
                        } else {
                            TextField(String(localized: "Type a reply"), text: $typed)
                                .submitLabel(.send)
                        }
                    }
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(submit)
                    Button(action: submit) { Image(systemName: "arrow.up.circle.fill").font(.title) }
                        .disabled(typed.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                .opacity(field ? 1 : 0)
                .disabled(!field)
            }

            if state.state == "reading", let speaker {
                if !speaker.enabled {
                    Label(String(localized: "Reading aloud is off (settings)"), systemImage: "speaker.slash")
                        .font(.footnote).foregroundStyle(.secondary)
                } else if AVAudioSession.sharedInstance().outputVolume < 0.05 {
                    Label(String(localized: "The phone volume is off"), systemImage: "speaker.slash")
                        .font(.footnote).foregroundStyle(.orange)
                }
            }

            if !compact {
                buttons
                    .frame(maxWidth: .infinity, minHeight: 104, alignment: .top)  // same size in every live step
            } else if canUndo {
                buttons
            }
        }
        .padding(18)
        .glassCard(26)
        .sheet(isPresented: $showDetails) {
            NavigationStack {
                ScrollView {
                    Text(state.details ?? "").font(.body).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading).padding()
                }
                .navigationTitle(state.project ?? "")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { Button(String(localized: "Close")) { showDetails = false } }
            }
        }
    }

    private var recording: Bool { recorder?.active == true }
    private var compact: Bool { !recording && ["sent", "released", "error"].contains(state.state) }
    private var canUndo: Bool {
        state.state == "sent" && state.cancellable == true && state.delivery != "clipboard" && !cancelled
    }

    private func submit() {
        let t = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        send(.reply(t))
        typed = ""
    }

    /// Icon above a one-line caption: three of these fit side by side on any iPhone.
    private func smallAction(_ title: String, _ icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Image(systemName: icon).font(.system(size: 16, weight: .medium))
                Text(title).font(.caption).lineLimit(1).minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity)
        }
        .glassButton()
        .controlSize(.regular)
    }

    @ViewBuilder private var buttons: some View {
        HStack(spacing: 12) {
            switch state.state {
            case _ where recording:
                VStack(alignment: .leading, spacing: 12) {
                    Text(String(localized: "A 2-second pause sends it. Transcribed on the Mac."))
                        .font(.footnote).foregroundStyle(.secondary)
                    HStack(spacing: 10) {
                        Button(role: .destructive, action: cancel) {
                            Text(String(localized: "Cancel")).frame(maxWidth: .infinity)
                        }
                        .glassButton()
                        .tint(.red)
                        Button { recorder?.finish(send: true) } label: {
                            Text(String(localized: "Send")).frame(maxWidth: .infinity)
                        }
                        .glassButton(prominent: true)
                        .disabled(recorder?.speaking != true)
                    }
                    .lineLimit(1)
                }
            case "speaking":
                Button(String(localized: "Cancel"), action: cancel).glassButton()
                Button { send(.control("quiet")) } label: {
                    Label(String(localized: "Stop voice"), systemImage: "speaker.slash")
                }
                .glassButton()
                Spacer()
                Button(String(localized: "Skip")) { send(.control("skip")) }.glassButton(prominent: true)
            case "reading":
                // Two rows: small actions on top, one big «Reply by voice» below (thumb-friendly).
                VStack(spacing: 12) {
                    HStack(spacing: 10) {
                        Button(String(localized: "Cancel"), action: cancel)
                        Spacer()
                        if speaker?.speaking == true {
                            Button { speaker?.stop() } label: { Image(systemName: "speaker.slash") }
                                .accessibilityLabel(String(localized: "Stop voice"))
                        } else if let summary = state.summary, speaker != nil {
                            Button { speaker?.speak(summary) } label: {
                                Image(systemName: "speaker.wave.2")
                            }
                            .accessibilityLabel(String(localized: "Read aloud"))
                        }
                        if !(state.details ?? "").isEmpty {
                            Button(String(localized: "More")) { showDetails = true }
                        }
                    }
                    .glassButton()
                    .controlSize(.regular)
                    .lineLimit(1)
                    Button { replyByPhone() } label: {
                        Label(String(localized: "Reply by voice"), systemImage: "mic.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .glassButton(prominent: true)
                    .lineLimit(1)
                }
            case "listening":
                VStack(spacing: 12) {
                    HStack(spacing: 10) {
                        Button(String(localized: "Cancel"), action: cancel)
                        Spacer()
                        Button(String(localized: "Repeat")) { send(.control("repeat")) }
                    }
                    .glassButton()
                    .controlSize(.regular)
                    .lineLimit(1)
                    Button { replyByPhone() } label: {
                        Label(String(localized: "Reply from the phone"), systemImage: "mic.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .glassButton(prominent: true)
                    .lineLimit(1)
                }
            case "confirming" where !editing:
                // Two rows: three small «fix the text» actions with icons, then Cancel / Send now.
                VStack(spacing: 12) {
                    HStack(spacing: 8) {
                        smallAction(String(localized: "Edit"), "pencil") {
                            typed = state.text ?? ""
                            editing = true
                            send(.control("hold"))
                        }
                        smallAction(String(localized: "Add more"), "plus.bubble") { send(.control("append")) }
                        smallAction(String(localized: "Again"), "arrow.counterclockwise") { send(.control("again")) }
                    }
                    HStack(spacing: 10) {
                        Button(role: .destructive, action: cancel) {
                            Text(String(localized: "Cancel")).frame(maxWidth: .infinity)
                        }
                        .glassButton()
                        .tint(.red)
                        Button { send(.control("send")) } label: {
                            Text(String(localized: "Send now")).frame(maxWidth: .infinity)
                        }
                        .glassButton(prominent: true)
                    }
                    .lineLimit(1)
                }
            case "confirming":
                Button(String(localized: "Cancel"), action: cancel).glassButton()
                Spacer()
            case "sent" where state.cancellable == true && state.delivery != "clipboard" && !cancelled:
                Spacer()
                Button(String(localized: "Undo")) {
                    if let sid = state.session_id { send(.cancelSent(session: sid)) }
                    cancelled = true
                }
                .glassButton()
                .tint(.red)
            default:
                EmptyView()
            }
        }
        .controlSize(.large)
    }

    private var bodyText: String? {
        switch state.state {
        case "speaking", "reading": state.summary
        case "confirming": editing ? nil : state.text
        case "sent" where cancelled: String(localized: "Cancelled, Claude will stop")
        case "sent" where state.delivery == "clipboard":
            String(localized: "Copied on the Mac. Paste into “\(state.project ?? "")”: ⌘V and ↩\n\n\(state.text ?? "")")
        case "error":
            state.code == "no_mic"
                ? String(localized: "No microphone access on the Mac. Allow it for hey2agent in System Settings → Privacy & Security → Microphone.")
                : String(localized: "Something went wrong: \(state.text ?? "")")
        case "listening", "transcribing", "sent": state.text
        default: nil
        }
    }

    private var title: String {
        switch state.state {
        case "speaking": String(localized: "Speaking")
        case "reading": String(localized: "Summary")
        case "listening": String(localized: "Listening")
        case "transcribing": String(localized: "Transcribing…")
        case "phone": String(localized: "Listening to the phone")
        case "confirming": editing ? String(localized: "Edit the text")
            : state.left.map { String(localized: "Sending in \(Int($0.rounded(.up))) s") } ?? String(localized: "Sending")
        case "sent": state.delivery == "clipboard" ? String(localized: "In the clipboard") : String(localized: "Sent")
        case "released": String(localized: "Session released")
        case "error": String(localized: "Didn’t work")
        default: ""
        }
    }

    @ViewBuilder private var icon: some View {
        switch state.state {
        case "speaking": Image(systemName: "speaker.wave.2.fill").foregroundStyle(.blue)
        case "reading": Image(systemName: "text.bubble").foregroundStyle(.blue)
        case "listening": Image(systemName: "mic.fill").foregroundStyle(.red)
        case "transcribing": ProgressView()
        case "phone": Image(systemName: "iphone.radiowaves.left.and.right").foregroundStyle(.red)
        case "confirming": Image(systemName: "paperplane").foregroundStyle(.blue)
        case "sent": Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case "error": Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        default: Image(systemName: "moon.zzz").foregroundStyle(.secondary)
        }
    }
}

struct SessionSection: View {
    let title: String
    let sessions: [LinkSession]
    let model: RemoteModel
    var centeredTitle = false
    /// Mic action (record on the phone for this chat), or nil if dictation isn't possible now.
    let action: (LinkSession) -> (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.footnote).foregroundStyle(.secondary).padding(.bottom, 4).padding(.leading, 6)
                .frame(maxWidth: .infinity, alignment: centeredTitle ? .center : .leading)
                .multilineTextAlignment(centeredTitle ? .center : .leading)
            TimelineView(.periodic(from: .now, by: 1)) { ctx in
                VStack(spacing: 0) {
                    ForEach(sessions) { s in
                        let mic = action(s)
                        HStack(spacing: 8) {
                            // Tap the row: open this chat on the Mac.
                            Button {
                                OpenChatTip().invalidate(reason: .actionPerformed)
                                model.send(.open(session: s.id))
                            } label: { row(s, now: ctx.date) }
                                .buttonStyle(.plain)
                            if let mic {
                                // Tap the mic: dictate a message into this chat from the phone.
                                Button(action: mic) {
                                    Image(systemName: "mic").font(.title3).frame(width: 44, height: 44)
                                }
                                .buttonStyle(.plain)
                                .foregroundStyle(.secondary)
                                .accessibilityLabel(String(localized: "Dictate a message to this chat"))
                            }
                        }
                        .contextMenu {
                            Button { model.send(.open(session: s.id)) } label: {
                                Label(String(localized: "Open on Mac"), systemImage: "macbook")
                            }
                            if mic != nil {
                                Button { model.send(.dictate(session: s.id)) } label: {
                                    Label(String(localized: "Dictate with the Mac mic"), systemImage: "mic")
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 4)
                .glassCard(22)
            }
        }
    }

    private func row(_ s: LinkSession, now: Date) -> some View {
        HStack(spacing: 12) {
            Image(systemName: s.status == "finished" ? "checkmark.circle.fill" : "circle.fill")
                .font(.system(size: s.status == "finished" ? 13 : 10))
                .foregroundStyle(color(s.status))
                .symbolEffect(.pulse, options: .repeating, isActive: s.status == "working" || s.status == "waiting")
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 2) {
                Text(s.title).font(.body).lineLimit(1)
                Text(label(s)).font(.caption).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.tail)
            }
            Spacer()
            Text(time(s, now: now)).font(.caption.monospacedDigit()).foregroundStyle(.tertiary)
        }
        .padding(.vertical, 10)
        .contentShape(Rectangle())
    }

    private func color(_ status: String) -> Color {
        switch status {
        case "waiting": .blue
        case "finished", "idle": .green
        case "stopping": .gray
        default: .orange
        }
    }

    private func label(_ s: LinkSession) -> String {
        switch s.status {
        case "waiting": String(localized: "waiting for you · \(s.project)")
        case "finished": String(localized: "done · \(s.project)")
        case "stopping": String(localized: "stopping…")
        case "working": "\(s.project) • \(sessionStatus(note: s.note, kind: s.activity, target: s.activity_target, at: s.activity_t))"
        default: s.project
        }
    }

    private func time(_ s: LinkSession, now: Date) -> String {
        let idle = s.status == "idle" || s.status == "finished"
        let sec = max(0, Int(now.timeIntervalSince1970 - (idle ? (s.ended ?? s.since) : s.since)))
        let m = sec / 60
        if idle {
            if m < 1 { return String(localized: "just now") }
            if m < 60 { return String(localized: "\(m) min ago") }
            return m < 1440 ? String(localized: "\(m / 60) h ago") : String(localized: "\(m / 1440) d ago")
        }
        return sec < 60 ? String(localized: "\(sec) s") : String(localized: "\(m) min")
    }
}


struct RecordingPanel: View {
    @Bindable var model: RemoteModel

    var body: some View {
        let r = model.recorder
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Image(systemName: "mic.fill").foregroundStyle(.red).font(.title2)
                VStack(alignment: .leading) {
                    Text(r.speaking ? String(localized: "Listening…") : String(localized: "Speak")).font(.title3.weight(.semibold))
                    if !model.recordingTitle.isEmpty {
                        Text(model.recordingTitle).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Spacer()
                if let left = r.secondsLeft {
                    Text(String(localized: "\(Int(left.rounded(.up))) s")).font(.title3.monospacedDigit()).foregroundStyle(.secondary)
                }
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(.quaternary)
                    Capsule().fill(.red.gradient).frame(width: max(6, geo.size.width * r.level))
                        .animation(.linear(duration: 0.1), value: r.level)
                }
            }
            .frame(height: 8)
            Text(String(localized: "A 2-second pause sends it. Transcribed on the Mac."))
                .font(.footnote).foregroundStyle(.secondary)
            HStack {
                Button(String(localized: "Cancel"), role: .cancel) { r.finish(send: false) }.glassButton()
                Spacer()
                Button(String(localized: "Send")) { r.finish(send: true) }.glassButton(prominent: true)
                    .disabled(!r.speaking)
            }
            .controlSize(.large)
        }
        .padding(18)
        .glassCard(26)
    }
}
