<p align="center"><img src="docs/logo.png" width="128" alt="hey2agent"></p>

<h1 align="center">hey2agent</h1>

<p align="center"><b>Разговаривайте с Claude Code и Codex голосом.</b> Агент закончил — плашка коротко
рассказывает, что сделано, вы отвечаете голосом, и ответ уходит <b>в ту же сессию</b>.<br>
Распознавание локально · русский и английский · плашка для macOS</p>

<p align="center"><a href="README.md">English</a> · <b>Русский</b></p>

<p align="center">
  <a href="#быстрый-старт"><img src="https://img.shields.io/badge/%D0%A3%D1%81%D1%82%D0%B0%D0%BD%D0%BE%D0%B2%D0%B8%D1%82%D1%8C-2_%D0%BC%D0%B8%D0%BD%D1%83%D1%82%D1%8B-D97757?style=for-the-badge" alt="Установить 2 минуты"></a>
  <a href="#iphone-отойти-от-компьютера"><img src="https://img.shields.io/badge/iPhone-%D0%BF%D1%80%D0%B8%D0%BB%D0%BE%D0%B6%D0%B5%D0%BD%D0%B8%D0%B5-555555?style=for-the-badge" alt="iPhone приложение"></a>
  <a href="#лицензия"><img src="https://img.shields.io/badge/%D0%91%D0%B5%D1%81%D0%BF%D0%BB%D0%B0%D1%82%D0%BD%D0%BE-MIT-555555?style=for-the-badge" alt="Бесплатно MIT"></a>
</p>

https://github.com/user-attachments/assets/83b9c3ef-3cdf-47e6-b128-8a782efac8f4

## Быстрый старт
Нужны macOS 15+ на Apple Silicon, [Homebrew](https://brew.sh) и Claude Code. Вставьте в Claude Code по очереди
три строки:
```
/plugin marketplace add DmitryVolostnov/hey2agent
/plugin install hey2agent@hey2agent
/hey2agent:setup
```
Настройка проверит Mac, спросит перед установкой (`whisper-cpp`, `ffmpeg`, модель распознавания), соберёт
плашку и включит голос. Дальше просто дождитесь, пока Claude закончит задачу: прозвучит сводка и *дзынь*.
Пользуетесь Codex? Настройка предложит подключить и его. Без плагинов — [установка вручную](#установка-вручную).

**Только Codex, без Claude Code?** Вставьте это в Codex — он сам выполнит те же шаги:
```
Установи hey2agent для Codex на этот Mac. Склонируй https://github.com/DmitryVolostnov/hey2agent в ~/hey2agent и в этой папке выполни: brew install whisper-cpp ffmpeg; python3 voice_loop.py setup; python3 voice_loop.py download-model turbo; python3 voice_loop.py install-codex; python3 voice_loop.py on; HUD/build.sh; open ~/Applications/VoiceLoopHUD.app. Спрашивай меня перед установкой, а в конце скажи перезапустить приложение Codex.
```

## Зачем я это сделал
Сейчас кто угодно может собрать с Claude нужную ему утилиту. Сложно сделать так, чтобы ей было приятно
пользоваться. Я продуктовый дизайнер, 10 лет занимаюсь интерфейсами, и постарался вложить этот опыт в
маленькую лёгкую программу, которая просто не мешает. Пользуюсь ей каждый день — поэтому и делюсь. Работы
ещё много, так что буду рад обратной связи в [Issues](https://github.com/DmitryVolostnov/hey2agent/issues).

## Что умеет
- **Ответ в ту же сессию** через Stop hook самого агента — без MCP и без ввода в терминал.
- **Всё локально:** голос macOS, распознавание [whisper.cpp](https://github.com/ggml-org/whisper.cpp). Звук не покидает Mac.
- **Понимает смесь русского и английских терминов** («закоммить», «пул-реквест»).
- **Плашка не мешает:** в покое — квадрат с логотипом, в работе — задачи и сколько они идут,
  при наведении — недавние чаты (клик открывает чат, 🎙 — надиктовать в него).
- **Страховки:** 3 секунды отменить или поправить распознанное; «Отменить» даже после отправки
  (Claude останавливается); «Замолчать» — прочитать саммари самому; «Без звука» для встреч.
- **10 языков интерфейса** (как в системе или выбор в настройках).

## iPhone: отойти от компьютера
Открыли приложение на телефоне — Mac замолкает: телефон показывает задачи в работе, читает саммари вслух,
по «Подробнее» показывает полный ответ агента, а ответить можно голосом или текстом (сессия ждёт до 10 минут).
Связь напрямую по Wi-Fi с шифрованием по 6-значному коду из настроек плашки, без сервера.
Ставится через Xcode на свой iPhone (подойдёт бесплатный Apple ID, но тогда подпись живёт 7 дней):
`brew install xcodegen`, затем `cd iOS && xcodegen generate && open VoiceLoopRemote.xcodeproj` → выбрать команду → Run.

## Голосовые команды
| В конце фразы | Что произойдёт |
|---|---|
| *(пауза 2 с)* или «отправь» | отправить |
| «подожди», «надо подумать» | слушать дальше (до 30 с) |
| «прочитай всё» | прочитать вслух весь ответ |
| «повтори» | повторить саммари |
| «отмена» | сбросить |
| «стоп», «хватит», тишина | отпустить сессию |
| «ок», «спасибо» (вся фраза) | закрыть ход, ничего не отправляется |

## Установка вручную
macOS 15+ на Apple Silicon, Python 3, [Homebrew](https://brew.sh).

```bash
brew install whisper-cpp ffmpeg
git clone https://github.com/DmitryVolostnov/hey2agent && cd hey2agent
python3 voice_loop.py install        # hooks Claude Code; спросит, какую модель распознавания скачать
python3 voice_loop.py install-codex  # по желанию: хуки для Codex (сразу помечаются доверенными), перезапустить Codex
python3 voice_loop.py on
HUD/build.sh && open ~/Applications/VoiceLoopHUD.app
```

## Модели распознавания
| id | размер | какая |
|---|---|---|
| `turbo` | 874 МБ | лучшая для смеси русского и английского (по умолчанию) |
| `turbo-q5` | 574 МБ | почти то же качество, на треть меньше |
| `small` | 190 МБ | быстрее, ошибается в английских терминах |
| `base` | 148 МБ | быстрая, слабая для русского |
| `tiny` | 78 МБ | самая быстрая, самая слабая |

Скачать ещё и переключить — в настройках плашки.

## Лицензия
MIT
