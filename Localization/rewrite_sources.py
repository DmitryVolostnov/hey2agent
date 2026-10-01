"""One-off: replace Russian UI literals in Swift sources with String(localized:) English keys.
Each entry: (exact Russian literal incl. quotes, English Swift literal incl. quotes)."""
import re, sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
L = lambda en: f'String(localized: {en})'

HUD = [
    ('"Недавние"', '"Recent"'),
    ('"Ещё \\(model.recent.count - 5)"', '"More \\(model.recent.count - 5)"'),
    ('"Включить звук"', '"Unmute"'),
    ('"Без звука (встреча): не говорить и не слушать"', '"Mute (meeting): don’t speak or listen"'),
    ('"в работе \\(working)"', '"in progress \\(working)"'),
    ('"готово \\(done)"', '"done \\(done)"'),
    ('"Голос включён"', '"Voice on"'),
    ('"Без звука"', '"Muted"'),
    ('"Открыть этот чат"', '"Open this chat"'),
    ('"\\(Int(left.rounded(.up))) с"', '"\\(Int(left.rounded(.up))) s"'),
    ('"Открыть этот чат и ответить там"', '"Open this chat and reply there"'),
    ('"Отмена"', '"Cancel"'),
    ('"Закрыть"', '"Close"'),
    ('"Отменить"', '"Undo"'),
    ('"Claude остановится: все его следующие действия будут запрещены"', '"Claude will stop: all its next actions will be blocked"'),
    ('"Исправьте и нажмите ↩"', '"Edit and press ↩"'),
    ('"Отправить"', '"Send"'),
    ('"Изменить"', '"Edit"'),
    ('"Дополнить"', '"Add more"'),
    ('"Оставить текст и договорить ещё"', '"Keep the text and dictate more"'),
    ('"Сказать заново"', '"Say again"'),
    ('"Отправить сейчас"', '"Send now"'),
    ('"Ответить текстом и нажать ↩"', '"Type a reply and press ↩"'),
    ('"Повторить"', '"Repeat"'),
    ('"Пропустить"', '"Skip"'),
    ('"Скопировано. Вставьте в чат «\\(s.project ?? "")» в Claude: ⌘V и ↩\\n\\n\\(s.text ?? "")"',
     '"Copied. Paste into “\\(s.project ?? "")” in Claude: ⌘V and ↩\\n\\n\\(s.text ?? "")"'),
    ('"Говорю"', '"Speaking"'),
    ('"Слушаю"', '"Listening"'),
    ('"Распознаю…"', '"Transcribing…"'),
    ('"Говорите в iPhone…"', '"Speak into the iPhone…"'),
    ('"Исправьте текст"', '"Edit the text"'),
    ('"Отправлю через \\(Int($0.rounded(.up))) с"', '"Sending in \\(Int($0.rounded(.up))) s"'),
    ('"Отправлю, когда нажмёте ↩"', '"Sending when you press ↩"'),
    ('"Отменено, Claude остановится"', '"Cancelled, Claude will stop"'),
    ('"В буфере обмена"', '"In the clipboard"'),
    ('"Добавлено в Codex"', '"Added to Codex"'),
    ('"Отправлено"', '"Sent"'),
    ('"Сессия отпущена"', '"Session released"'),
    ('"Не получилось"', '"Didn’t work"'),
    ('"\\(max(m, 1)) мин"', '"\\(max(m, 1)) min"'),
    ('"\\(m / 60) ч"', '"\\(m / 60) h"'),
    ('"\\(m / 1440) д"', '"\\(m / 1440) d"'),
    ('"только что"', '"just now"'),
    ('"\\(m) мин назад"', '"\\(m) min ago"'),
    ('"\\(m / 60) ч назад"', '"\\(m / 60) h ago"'),
    ('"\\(m / 1440) д назад"', '"\\(m / 1440) d ago"'),
    ('"ждёт ответа"', '"waiting for you"'),
    ('"готово"', '"done"'),
    ('"останавливается…"', '"stopping…"'),
    ('"\\(sec) с"', '"\\(sec) s"'),
    ('"\\(sec / 60) мин"', '"\\(sec / 60) min"'),
    ('"Надиктовать сообщение в этот чат"', '"Dictate a message to this chat"'),
    ('"Открыть чат"', '"Open chat"'),
    ('"Голосовой режим"', '"Voice mode"'),
    ('"Без звука (встреча)"', '"Mute (meeting)"'),
    ('"Голос"', '"Voice"'),
    ('"Прослушать голос"', '"Preview voice"'),
    ('"Пауза, после которой отправляю"', '"Pause before sending"'),
    ('"Можно отменить в течение"', '"Time to undo"'),
    ('"не ждать"', '"don’t wait"'),
    ('"\\(Int($0)) с"', '"\\(Int($0)) s"'),
    ('"Время, чтобы начать говорить"', '"Time to start speaking"'),
    ('"Проекты"', '"Projects"'),
    ('"✓ Все проекты"', '"✓ All projects"'),
    ('"Все проекты"', '"All projects"'),
    ('"Код привязки: \\(model.pairingCode.prefix(3)) \\(model.pairingCode.suffix(3))"',
     '"Pairing code: \\(String(model.pairingCode.prefix(3))) \\(String(model.pairingCode.suffix(3)))"'),
    ('"Подключено: \\(model.phones)"', '"Connected: \\(model.phones)"'),
    ('"Телефон не подключён"', '"No phone connected"'),
    ('"Новый код (отключит телефон)"', '"New code (disconnects the phone)"'),
    ('"Запускать при входе в систему"', '"Open at login"'),
    ('"Показывать плашку"', '"Show panel"'),
    ('"Прятать, когда подключён iPhone"', '"Hide when an iPhone is connected"'),
    ('"Открыть лог"', '"Open log"'),
    ('"Выйти"', '"Quit"'),
]
HUD_SPECIAL = [
    ('String(format: "%.1f с", $0)', 'String(format: String(localized: "%.1f s"), $0)'),
    ('Section("iPhone")', 'Section("iPhone")'),
]

IOS = [
    ('"Ищу Mac с voice-loop в этой сети…"', '"Looking for a Mac running voice-loop on this network…"'),
    ('"Плашка voice-loop должна быть запущена, телефон и Mac в одной Wi-Fi сети."',
     '"The voice-loop panel must be running and the phone and Mac on the same Wi-Fi."'),
    ('"6 цифр"', '"6 digits"'),
    ('"Код привязки"', '"Pairing code"'),
    ('"На Mac: наведите на плашку → шестерёнка → «Код привязки». "\n                         + "Код шифрует соединение, данные не уходят в интернет."',
     '"On the Mac: hover the panel → gear → “Pairing code”. The code encrypts the connection; nothing goes to the internet."'),
    ('"Код не подошёл. Проверьте цифры на Mac."', '"Wrong code. Check the digits on the Mac."'),
    ('"Подключить"', '"Connect"'),
    ('"В работе"', '"In progress"'),
    ('"Недавние: нажмите и говорите. Долгое нажатие: открыть на Mac"', '"Recent: tap and speak. Long press: open on Mac"'),
    ('"Ещё \\(s.recent.count - 5)"', '"More \\(s.recent.count - 5)"'),
    ('"Переподключаюсь…"', '"Reconnecting…"'),
    ('"Включить звук"', '"Unmute"'),
    ('"Без звука"', '"Mute"'),
    ('"Отвязать Mac"', '"Unpair Mac"'),
    ('"Подключаюсь к Mac…"', '"Connecting to the Mac…"'),
    ('"Голосовой режим выключен"', '"Voice mode is off"'),
    ('"В работе: \\(working)"', '"In progress: \\(working)"'),
    ('"Голос включён"', '"Voice on"'),
    ('"\\(base) · без звука"', '"\\(base) · muted"'),
    ('"\\(Int(left.rounded(.up))) с"', '"\\(Int(left.rounded(.up))) s"'),
    ('"Закрыть"', '"Close"'),
    ('"Открыть чат на Mac"', '"Open the chat on the Mac"'),
    ('"Исправьте текст"', '"Edit the text"'),
    ('"Ответить текстом"', '"Type a reply"'),
    ('"Отмена"', '"Cancel"'),
    ('"Пропустить"', '"Skip"'),
    ('"Ответить с телефона"', '"Reply from the phone"'),
    ('"Повторить"', '"Repeat"'),
    ('"Изменить"', '"Edit"'),
    ('"Дополнить"', '"Add more"'),
    ('"Заново"', '"Again"'),
    ('"Отменить"', '"Undo"'),
    ('"Отменено, Claude остановится"', '"Cancelled, Claude will stop"'),
    ('"Скопировано на Mac. Вставьте в чат «\\(state.project ?? "")»: ⌘V и ↩\\n\\n\\(state.text ?? "")"',
     '"Copied on the Mac. Paste into “\\(state.project ?? "")”: ⌘V and ↩\\n\\n\\(state.text ?? "")"'),
    ('"Говорю"', '"Speaking"'),
    ('"Слушаю"', '"Listening"'),
    ('"Распознаю…"', '"Transcribing…"'),
    ('"Слушаю телефон"', '"Listening to the phone"'),
    ('"Отправлю через \\(Int($0.rounded(.up))) с"', '"Sending in \\(Int($0.rounded(.up))) s"'),
    ('"Отправлю"', '"Sending"'),
    ('"В буфере обмена"', '"In the clipboard"'),
    ('"Отправлено"', '"Sent"'),
    ('"Сессия отпущена"', '"Session released"'),
    ('"Не получилось"', '"Didn’t work"'),
    ('"Открыть на Mac"', '"Open on Mac"'),
    ('"Надиктовать микрофоном Mac"', '"Dictate with the Mac mic"'),
    ('"ждёт ответа · \\(s.project)"', '"waiting for you · \\(s.project)"'),
    ('"готово · \\(s.project)"', '"done · \\(s.project)"'),
    ('"останавливается…"', '"stopping…"'),
    ('"только что"', '"just now"'),
    ('"\\(m) мин назад"', '"\\(m) min ago"'),
    ('"\\(m / 60) ч назад"', '"\\(m / 60) h ago"'),
    ('"\\(m / 1440) д назад"', '"\\(m / 1440) d ago"'),
    ('"\\(sec) с"', '"\\(sec) s"'),
    ('"\\(m) мин"', '"\\(m) min"'),
    ('"Слушаю…"', '"Listening…"'),
    ('"Говорите"', '"Speak"'),
    ('"Пауза 2 секунды — отправлю. Распознавание на Mac."', '"A 2-second pause sends it. Transcribed on the Mac."'),
    ('"Отправить"', '"Send"'),
]

def apply(path, table, special=()):
    p = ROOT / path
    s = p.read_text()
    for a, b in special:
        s = s.replace(a, b)
    # longest first so prefixes («Без звука» vs «Без звука (встреча)») don't clash
    for ru, en in sorted(table, key=lambda t: -len(t[0])):
        n = s.count(ru)
        if n == 0:
            print("MISSING", path, ru[:60]); continue
        s = s.replace(ru, L(en))
    left = [l for l in s.splitlines() if re.search('[А-Яа-яЁё]', l) and not l.strip().startswith('//')]
    p.write_text(s)
    print(path, "remaining cyrillic lines:", len(left))
    for l in left: print("   ", l.strip()[:120])

apply("HUD/Sources/VoiceLoopHUD/VoiceLoopHUD.swift", HUD, HUD_SPECIAL)
apply("iOS/Sources/Views.swift", IOS)
