# voice-loop

**English** · [Русский](README.ru.md)

**Talk to your coding agents without leaving the flow.** When Claude Code or Codex finishes a turn,
voice-loop says what was done, opens the mic, and sends your spoken reply back into **the same
session** as the next instruction. Fully local, Russian + English.

```
Agent finishes ─► "Voice notification chat. Done. Added the HUD and tests. Commit now?"
                     ▼  *tink*
You: "Yes, commit and open a pull request"   (2 s pause)
                     ▼
Same session continues with your instruction
```

## Why
- **Same session, no copy-paste.** Uses the agents' own Stop hooks (`decision: block`), so your reply
  lands in the running Claude Code / Codex conversation — no MCP tool the agent must remember to call,
  no typing into a terminal.
- **Local only.** macOS `say` or Piper for speech, `whisper.cpp` for recognition. Nothing leaves the Mac.
- **Built for mixed Russian/English dev speech.** Whisper prompt with dev jargon
  («закоммить», «пул-реквест», «деплой») and Cyrillic-friendly spoken summaries.
- **A HUD that shows what's going on.** Floating pill with every agent session in progress
  (pulsing dot = thinking, blue = waiting for you), live mic level, send / cancel / skip / repeat,
  and a text field when you'd rather type.

## Voice commands
| Say at the end of a phrase | Effect |
|---|---|
| *(pause 2 s)* or «отправь» / "send" | send |
| «подожди», «надо подумать» / "wait" | keep listening (up to 30 s) |
| «повтори» / "repeat" | replay the summary |
| «отмена» / "cancel" | discard |
| «стоп», «хватит» / silence | let the agent stop |

While voice mode is on, the agent is asked to start every answer with a one-line
**«Кратко:» / summary**, and only that line is spoken.

## Install
Requirements: macOS 15+ on Apple silicon, Python 3, `brew install whisper-cpp ffmpeg`.

```bash
git clone https://github.com/DmitryVolostnov/voice-loop && cd voice-loop
python3 voice_loop.py install        # Claude Code hooks (+ downloads the whisper model if missing)
python3 voice_loop.py install-codex  # optional: Codex Stop hook, then approve it in Codex via /hooks
python3 voice_loop.py on
HUD/build.sh && open HUD/VoiceLoopHUD.app
```
The process that runs your agent (Terminal, iTerm, Claude app) needs microphone permission.

Optional neural voice: `python3 -m venv .venv && .venv/bin/pip install piper-tts`, then pick a Piper
voice in the HUD settings (it sounds nicer in Russian but mispronounces English words).

## How it works
`voice_loop.py hook` runs on the agent's Stop event: summary → TTS → energy VAD over `ffmpeg` mic
input → `whisper-cli` → `{"decision":"block","reason":"<your reply>"}`. A `UserPromptSubmit` hook keeps
a registry of sessions in progress for the HUD. The HUD and the script talk through small files in
`~/.voice-loop/` (`state.json`, `sessions.json`, `control`), so the script works without the HUD.

```bash
python3 -m unittest discover tests                       # logic
VOICE_LOOP_SLOW=1 python3 -m unittest tests.test_speech  # say → whisper round trip
```

## Similar projects
[Heard](https://github.com/heardlabs/heard) (closest; multi-agent voices, paid cloud tiers),
[VoiceMode](https://github.com/mbailey/voicemode) (MCP `converse` tool),
[spanderok/jarvis](https://github.com/spanderok/jarvis) (wake-word, Russian),
and many speak-only Stop-hook scripts. voice-loop focuses on replying into the same session via hooks,
a multi-session HUD across Claude Code and Codex, and local Russian/English.

## Status
Personal tool, early. Known limits: the hook blocks the session while listening (≤180 s);
Codex sessions show the folder name instead of the chat title.

## License
MIT
