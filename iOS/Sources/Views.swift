import Network
import SwiftUI
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
                            Text("Ищу Mac с voice-loop в этой сети…").foregroundStyle(.secondary)
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
                    Text("Плашка voice-loop должна быть запущена, телефон и Mac в одной Wi-Fi сети.")
                }

                Section {
                    TextField("6 цифр", text: $code)
                        .keyboardType(.numberPad)
                        .font(.title2.monospacedDigit())
                        .onChange(of: code) { _, new in
                            let clean = String(new.filter(\.isNumber).prefix(6))
                            if clean != new { code = clean }
                        }
                } header: {
                    Text("Код привязки")
                } footer: {
                    Text("На Mac: наведите на плашку → шестерёнка → «Код привязки». "
                         + "Код шифрует соединение, данные не уходят в интернет.")
                }

                if model.status == .badCode {
                    Text("Код не подошёл. Проверьте цифры на Mac.").foregroundStyle(.red)
                }

                Button("Подключить") {
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

    var body: some View {
        let snap = model.snapshot
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header(snap)
                if let a = snap?.active {
                    ConversationCard(state: a, send: model.send,
                                     replyByPhone: { model.recordOnPhone(for: nil) })
                        .id("\(a.project ?? "")|\(a.state)")
                } else {
                    IdleCard(snap: snap)
                }
                if let s = snap, !s.sessions.isEmpty {
                    SessionSection(title: "В работе", sessions: s.sessions, model: model) { session in
                        session.status == "finished" && s.active == nil
                            ? { model.recordOnPhone(for: session) } : nil
                    }
                }
                if let s = snap, !s.recent.isEmpty {
                    SessionSection(title: "Недавние: нажмите и говорите. Долгое нажатие: открыть на Mac",
                                   sessions: s.recent, model: model) { session in
                        s.active == nil ? { model.recordOnPhone(for: session) } : nil
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
            Text(model.status == .connected ? (snap?.mac ?? model.macName ?? "Mac") : "Переподключаюсь…")
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
                .accessibilityLabel(s.muted ? "Включить звук" : "Без звука")
            }
            Menu {
                Button("Отвязать Mac", role: .destructive) { model.unpair() }
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
        guard let s = snap else { return "Подключаюсь к Mac…" }
        if !s.enabled { return "Голосовой режим выключен" }
        let working = s.sessions.filter { $0.status == "working" || $0.status == "waiting" }.count
        let base = working > 0 ? "В работе: \(working)" : "Голос включён"
        return s.muted ? "\(base) · без звука" : base
    }
}

struct ConversationCard: View {
    let state: LinkVoiceState
    let send: (LinkCommand) -> Void
    var replyByPhone: () -> Void = {}
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
                    Text("\(Int(left.rounded(.up))) с").font(.title3.monospacedDigit()).foregroundStyle(.secondary)
                }
                if let sid = state.session_id, ["speaking", "listening", "phone"].contains(state.state) {
                    Button { send(.open(session: sid)) } label: {
                        Image(systemName: "arrow.up.forward.app").font(.title2)
                    }
                    .accessibilityLabel("Открыть чат на Mac")
                }
            }

            if state.state == "listening" {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(.quaternary)
                        Capsule().fill(.red.gradient)
                            .frame(width: max(6, geo.size.width * (state.level ?? 0)))
                            .animation(.linear(duration: 0.15), value: state.level)
                    }
                }
                .frame(height: 6)
            }

            if let text = bodyText, !text.isEmpty {
                Text(text)
                    .font(.title3)
                    .foregroundStyle(state.state == "speaking" ? .secondary : .primary)
                    .textSelection(.enabled)
            }

            if editing || state.state == "speaking" || state.state == "listening" {
                HStack {
                    TextField(editing ? "Исправьте текст" : "Ответить текстом", text: $typed, axis: .vertical)
                        .textFieldStyle(.roundedBorder)
                        .lineLimit(1...5)
                        .onSubmit(submit)
                    Button(action: submit) { Image(systemName: "arrow.up.circle.fill").font(.title) }
                        .disabled(typed.trimmingCharacters(in: .whitespaces).isEmpty)
                }
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
                Button("Отмена") { send(.control("cancel")) }.buttonStyle(.bordered)
                Spacer()
                Button("Пропустить") { send(.control("skip")) }.buttonStyle(.borderedProminent)
            case "listening":
                Button { replyByPhone() } label: { Label("Ответить с телефона", systemImage: "mic.fill") }
                    .buttonStyle(.borderedProminent)
                Spacer()
                Button("Повторить") { send(.control("repeat")) }.buttonStyle(.bordered)
                Button("Отмена") { send(.control("cancel")) }.buttonStyle(.bordered)
            case "confirming" where !editing:
                Button("Изменить") {
                    typed = state.text ?? ""
                    editing = true
                    send(.control("hold"))
                }
                .buttonStyle(.bordered)
                Button("Заново") { send(.control("again")) }.buttonStyle(.bordered)
                Spacer()
                Button("Отмена") { send(.control("cancel")) }.buttonStyle(.borderedProminent).tint(.red)
            case "confirming":
                Button("Отмена") { send(.control("cancel")) }.buttonStyle(.bordered)
                Spacer()
            case "sent" where state.cancellable == true && state.delivery != "clipboard" && !cancelled:
                Spacer()
                Button("Отменить") {
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
        case "speaking": state.summary
        case "confirming": editing ? nil : state.text
        case "sent" where cancelled: "Отменено, Claude остановится"
        case "sent" where state.delivery == "clipboard":
            "Скопировано на Mac. Вставьте в чат «\(state.project ?? "")»: ⌘V и ↩\n\n\(state.text ?? "")"
        case "listening", "transcribing", "sent", "error": state.text
        default: nil
        }
    }

    private var title: String {
        switch state.state {
        case "speaking": "Говорю"
        case "listening": "Слушаю"
        case "transcribing": "Распознаю…"
        case "phone": "Слушаю телефон"
        case "confirming": editing ? "Исправьте текст"
            : state.left.map { "Отправлю через \(Int($0.rounded(.up))) с" } ?? "Отправлю"
        case "sent": state.delivery == "clipboard" ? "В буфере обмена" : "Отправлено"
        case "released": "Сессия отпущена"
        case "error": "Не получилось"
        default: ""
        }
    }

    @ViewBuilder private var icon: some View {
        switch state.state {
        case "speaking": Image(systemName: "speaker.wave.2.fill").foregroundStyle(.blue)
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
                                    Label("Открыть на Mac", systemImage: "macbook")
                                }
                                if tap != nil {
                                    Button { model.send(.dictate(session: s.id)) } label: {
                                        Label("Надиктовать микрофоном Mac", systemImage: "mic")
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
        case "waiting": "ждёт ответа · \(s.project)"
        case "finished": "готово · \(s.project)"
        case "stopping": "останавливается…"
        default: s.project
        }
    }

    private func time(_ s: LinkSession, now: Date) -> String {
        let idle = s.status == "idle" || s.status == "finished"
        let sec = max(0, Int(now.timeIntervalSince1970 - (idle ? (s.ended ?? s.since) : s.since)))
        let m = sec / 60
        if idle {
            if m < 1 { return "только что" }
            if m < 60 { return "\(m) мин назад" }
            return m < 1440 ? "\(m / 60) ч назад" : "\(m / 1440) д назад"
        }
        return sec < 60 ? "\(sec) с" : "\(m) мин"
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
                    Text(r.speaking ? "Слушаю…" : "Говорите").font(.title3.weight(.semibold))
                    if !model.recordingTitle.isEmpty {
                        Text(model.recordingTitle).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Spacer()
                if let left = r.secondsLeft {
                    Text("\(Int(left.rounded(.up))) с").font(.title3.monospacedDigit()).foregroundStyle(.secondary)
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
            Text("Пауза 2 секунды — отправлю. Распознавание на Mac.")
                .font(.footnote).foregroundStyle(.secondary)
            HStack {
                Button("Отмена", role: .cancel) { r.finish(send: false) }.buttonStyle(.bordered)
                Spacer()
                Button("Отправить") { r.finish(send: true) }.buttonStyle(.borderedProminent)
                    .disabled(!r.speaking)
            }
            .controlSize(.large)
        }
        .padding(18)
        .background(RoundedRectangle(cornerRadius: 22).fill(.regularMaterial))
    }
}
