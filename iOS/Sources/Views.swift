import Network
import SwiftUI
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
                            Text(String(localized: "Looking for a Mac running voice-loop on this network…")).foregroundStyle(.secondary)
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
                    Text(String(localized: "The voice-loop panel must be running and the phone and Mac on the same Wi-Fi."))
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
            .navigationTitle("voice-loop")
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
    @State private var showMore = false
    @State private var dismissed: Double?

    var body: some View {
        let snap = model.snapshot
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header(snap)
                if let a = snap?.active, a.t != dismissed {
                    ConversationCard(state: a, send: model.send,
                                     replyByPhone: { model.recordOnPhone(for: nil) },
                                     close: { dismissed = a.t })
                        .id("\(a.project ?? "")|\(a.state)")
                } else {
                    IdleCard(snap: snap)
                }
                if let s = snap, !s.sessions.isEmpty {
                    SessionSection(title: String(localized: "In progress"), sessions: s.sessions, model: model) { session in
                        session.status == "finished" && s.active == nil
                            ? { model.recordOnPhone(for: session) } : nil
                    }
                }
                if let s = snap, !s.recent.isEmpty {
                    SessionSection(title: String(localized: "Recent: tap and speak. Long press: open on Mac"),
                                   sessions: Array(s.recent.prefix(showMore ? 10 : 5)), model: model) { session in
                        s.active == nil ? { model.recordOnPhone(for: session) } : nil
                    }
                    if s.recent.count > 5 && !showMore {
                        Button(String(localized: "More \(s.recent.count - 5)")) { withAnimation { showMore = true } }
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(20)
        }
        .background(Color.black.ignoresSafeArea())
        .overlay(alignment: .bottom) {
            if model.recorder.active { RecordingPanel(model: model).padding(16) }
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
                        .foregroundStyle(s.muted ? .orange : .secondary)
                }
                .accessibilityLabel(s.muted ? String(localized: "Unmute") : String(localized: "Mute"))
            }
            Menu {
                // iOS has a per-app language switch in Settings; open it.
                Button(String(localized: "Language")) {
                    if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                }
                Button(String(localized: "Unpair Mac"), role: .destructive) { model.unpair() }
            } label: {
                Image(systemName: "ellipsis.circle").font(.title3).foregroundStyle(.secondary)
            }
        }
    }
}

struct IdleCard: View {
    let snap: LinkSnapshot?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            TimelineView(.periodic(from: .now, by: 1)) { ctx in
                Text(ctx.date, format: .dateTime.hour().minute())
                    .font(.system(size: 64, weight: .thin, design: .rounded).monospacedDigit())
            }
            Text(status).font(.headline).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var status: String {
        guard let s = snap else { return String(localized: "Connecting to the Mac…") }
        if !s.enabled { return String(localized: "Voice mode is off") }
        let working = s.sessions.filter { $0.status == "working" || $0.status == "waiting" }.count
        let base = working > 0 ? String(localized: "In progress: \(working)") : String(localized: "Voice on")
        return s.muted ? String(localized: "\(base) · muted") : base
    }
}

struct ConversationCard: View {
    let state: LinkVoiceState
    let send: (LinkCommand) -> Void
    var replyByPhone: () -> Void = {}
    var close: () -> Void = {}
    @State private var typed = ""
    @State private var editing = false
    @State private var cancelled = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                icon.font(.title2).frame(width: 30)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.title3.weight(.semibold))
                    if let p = state.project {
                        Text(p).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Spacer()
                if state.state == "listening", let left = state.left {
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

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(.quaternary)
                    Capsule().fill(.red.gradient)
                        .frame(width: max(6, geo.size.width * (state.level ?? 0)))
                        .animation(.linear(duration: 0.15), value: state.level)
                }
            }
            .frame(height: 6)
            .opacity(state.state == "listening" ? 1 : 0)

            // Fixed height for every step so the buttons below never move between states.
            Text(bodyText ?? "")
                .font(.title3)
                .foregroundStyle(state.state == "speaking" ? .secondary : .primary)
                .lineLimit(6)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, minHeight: 150, maxHeight: 150, alignment: .topLeading)

            let field = editing || ["speaking", "listening", "reading"].contains(state.state)
            do {
                HStack {
                    TextField(editing ? String(localized: "Edit the text") : String(localized: "Type a reply"), text: $typed, axis: .vertical)
                        .textFieldStyle(.roundedBorder)
                        .lineLimit(1...5)
                        .onSubmit(submit)
                    Button(action: submit) { Image(systemName: "arrow.up.circle.fill").font(.title) }
                        .disabled(typed.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                .opacity(field ? 1 : 0)
                .disabled(!field)
            }

            buttons
        }
        .padding(18)
        .background(RoundedRectangle(cornerRadius: 20).fill(Color.white.opacity(0.08)))
    }

    private func submit() {
        let t = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        send(.reply(t))
        typed = ""
    }

    @ViewBuilder private var buttons: some View {
        HStack(spacing: 12) {
            switch state.state {
            case "speaking":
                Button(String(localized: "Cancel")) { send(.control("cancel")) }.buttonStyle(.bordered)
                Button { send(.control("quiet")) } label: {
                    Label(String(localized: "Stop voice"), systemImage: "speaker.slash")
                }
                .buttonStyle(.bordered)
                Spacer()
                Button(String(localized: "Skip")) { send(.control("skip")) }.buttonStyle(.borderedProminent)
            case "reading":
                Button(String(localized: "Cancel")) { send(.control("cancel")) }.buttonStyle(.bordered)
                Spacer()
                Button { send(.control("listen")) } label: {
                    Label(String(localized: "Reply by voice"), systemImage: "mic.fill")
                }
                .buttonStyle(.borderedProminent)
            case "listening":
                Button { replyByPhone() } label: { Label(String(localized: "Reply from the phone"), systemImage: "mic.fill") }
                    .buttonStyle(.borderedProminent)
                Spacer()
                Button(String(localized: "Repeat")) { send(.control("repeat")) }.buttonStyle(.bordered)
                Button(String(localized: "Cancel")) { send(.control("cancel")) }.buttonStyle(.bordered)
            case "confirming" where !editing:
                Button(String(localized: "Edit")) {
                    typed = state.text ?? ""
                    editing = true
                    send(.control("hold"))
                }
                .buttonStyle(.bordered)
                Button(String(localized: "Add more")) { send(.control("append")) }.buttonStyle(.bordered)
                Button(String(localized: "Again")) { send(.control("again")) }.buttonStyle(.bordered)
                Spacer()
                Button(String(localized: "Cancel")) { send(.control("cancel")) }.buttonStyle(.borderedProminent).tint(.red)
            case "confirming":
                Button(String(localized: "Cancel")) { send(.control("cancel")) }.buttonStyle(.bordered)
                Spacer()
            case "sent" where state.cancellable == true && state.delivery != "clipboard" && !cancelled:
                Spacer()
                Button(String(localized: "Undo")) {
                    if let sid = state.session_id { send(.cancelSent(session: sid)) }
                    cancelled = true
                }
                .buttonStyle(.bordered)
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
                ? String(localized: "No microphone access on the Mac. Allow it for voice-loop in System Settings → Privacy & Security → Microphone.")
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
    let action: (LinkSession) -> (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.footnote).foregroundStyle(.secondary).padding(.bottom, 4)
            TimelineView(.periodic(from: .now, by: 1)) { ctx in
                VStack(spacing: 0) {
                    ForEach(sessions) { s in
                        let tap = action(s)
                        Button { tap?() } label: { row(s, now: ctx.date, tappable: tap != nil) }
                            .buttonStyle(.plain)
                            .contextMenu {
                                Button { model.send(.open(session: s.id)) } label: {
                                    Label(String(localized: "Open on Mac"), systemImage: "macbook")
                                }
                                if tap != nil {
                                    Button { model.send(.dictate(session: s.id)) } label: {
                                        Label(String(localized: "Dictate with the Mac mic"), systemImage: "mic")
                                    }
                                }
                            }
                    }
                }
            }
        }
    }

    private func row(_ s: LinkSession, now: Date, tappable: Bool) -> some View {
        HStack(spacing: 12) {
            Image(systemName: s.status == "finished" ? "checkmark.circle.fill" : "circle.fill")
                .font(.system(size: s.status == "finished" ? 13 : 10))
                .foregroundStyle(color(s.status))
                .symbolEffect(.pulse, options: .repeating, isActive: s.status == "working" || s.status == "waiting")
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 2) {
                Text(s.title).font(.body).lineLimit(1)
                Text(label(s)).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Text(time(s, now: now)).font(.caption.monospacedDigit()).foregroundStyle(.tertiary)
            if tappable { Image(systemName: "mic").foregroundStyle(.secondary) }
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
                Button(String(localized: "Cancel"), role: .cancel) { r.finish(send: false) }.buttonStyle(.bordered)
                Spacer()
                Button(String(localized: "Send")) { r.finish(send: true) }.buttonStyle(.borderedProminent)
                    .disabled(!r.speaking)
            }
            .controlSize(.large)
        }
        .padding(18)
        .background(RoundedRectangle(cornerRadius: 22).fill(.regularMaterial))
    }
}
