#!/usr/bin/env python3
"""voice-loop: when a Claude Code turn ends, speak a short summary, listen, and feed
the dictated text back as the next instruction (Stop hook, decision=block).

Stdlib only. External tools: ffmpeg (mic), whisper-cli (local STT), say/afplay (macOS).
Nothing leaves the machine.

  voice_loop.py on | off | status     toggle via flag file
  voice_loop.py install | uninstall   add/remove the Stop hook in ~/.claude/settings.json
  voice_loop.py say "text"            test TTS
  voice_loop.py listen                test mic + transcription
  voice_loop.py hook                  called by Claude Code (reads hook JSON on stdin)
"""

import array
import fcntl
import hashlib
import json
import math
import os
import re
import shutil
import subprocess
import sys
import queue
import tempfile
import threading
import time
import wave
from pathlib import Path

HOME = Path.home()
STATE_DIR = HOME / ".voice-loop"
FLAG = STATE_DIR / "enabled"
LOCK = STATE_DIR / "lock"
LOG = STATE_DIR / "log.txt"
STATE = STATE_DIR / "state.json"      # read by the HUD
CONTROL = STATE_DIR / "control"       # written by the HUD: send | cancel
LAST = STATE_DIR / "last.json"  # dedupe: the Stop hook can fire twice for one turn
CONFIG = STATE_DIR / "config.json"
CLAUDE_SETTINGS = HOME / ".claude" / "settings.json"
SCRIPT = Path(__file__).resolve()
HOOK_TIMEOUT = 180  # seconds; Claude Code kills the hook after this

DEFAULTS = {
    "tts": "say",                # say (macOS voices) | piper (local neural, garbles English words)
    "voice": "Milena",           # say voice; «Milena (Enhanced)» once downloaded in System Settings
    "piper_voice": "ru_RU-irina-medium",
    "rate": 200,
    "mic": "default",            # avfoundation audio device name or index
    "speech_margin_db": 12,      # speech = this much louder than the room noise floor
    "min_floor_db": -60,         # floor never assumed quieter than this
    "silence_sec": 2.0,          # pause that ends a phrase
    "wait_sec": 5.0,             # give up if no speech starts within this after the cue
    "hold_sec": 30.0,            # after «подожди»: how long to wait for the continuation
    "max_sec": 90.0,             # hard cap on one utterance
    "language": "ru",            # whisper language: ru | en | auto (auto is slower, misfires on short phrases)
    "whisper": "/opt/homebrew/bin/whisper-cli",
    "model": str(HOME / ".cache/huggingface/hub/models--ggerganov--whisper.cpp/snapshots/"
                 "5359861c739e955e79d9a303bcbc70fb988958b1/ggml-large-v3-turbo-q8_0.bin"),
    # Vocabulary hint for whisper: dev jargon in mixed Russian/English.
    "prompt": "Закоммить, запушь, коммит, пул-реквест, ветка, тесты, билд, деплой, рефакторинг, "
              "Claude, Codex, hook, pipeline, SwiftUI, MCP, Screenpipe.",
    "summary_chars": 220,
    "lock_wait_sec": 120,        # wait for another session to finish talking
    "projects": [],              # only speak in these project folders (empty = everywhere)
}

STOP_WORDS = {"стоп", "хватит", "всё", "все", "ничего", "пока", "не надо", "отбой",
              "stop", "nothing", "that's it", "no"}

# Said at the end of a phrase.
SEND_WORDS = ["отправляй", "отправить", "отправь", "отправка", "send it", "send"]
HOLD_WORDS = ["надо подумать", "дай подумать", "подожди", "подождите", "секунду", "секундочку",
              "wait"]
REPEAT_WORDS = {"повтори", "повтори пожалуйста", "повтори ещё раз", "повтори еще раз", "ещё раз",
                "еще раз", "не расслышал", "что", "repeat"}
CANCEL_WORDS = ["отмена", "отменить", "отмени", "cancel"]

# Classic whisper hallucinations on silence / noise.
HALLUCINATIONS = ["субтитры", "продолжение следует", "спасибо за просмотр", "dimatorzok",
                  "редактор субтитров", "подписывайтесь", "thank you for watching",
                  "thanks for watching", "amara.org"]


def cfg():
    c = dict(DEFAULTS)
    if CONFIG.exists():
        try:
            c.update(json.loads(CONFIG.read_text()))
        except Exception as e:
            log(f"bad config: {e}")
    return c


def log(msg):
    STATE_DIR.mkdir(exist_ok=True)
    with LOG.open("a") as f:
        f.write(f"{time.strftime('%Y-%m-%d %H:%M:%S')} {msg}\n")


# ---------- summary ----------

def last_assistant_text(hook):
    if hook.get("last_assistant_message"):
        return hook["last_assistant_message"]
    path = hook.get("transcript_path")
    if not path or not os.path.exists(path):
        return ""
    # The transcript may lag the Stop event slightly.
    for _ in range(3):
        text = ""
        with open(path) as f:
            for line in f:
                try:
                    e = json.loads(line)
                except Exception:
                    continue
                if e.get("type") != "assistant":
                    continue
                content = (e.get("message") or {}).get("content")
                if isinstance(content, list):
                    parts = [b.get("text", "") for b in content if b.get("type") == "text"]
                    if any(p.strip() for p in parts):
                        text = "\n".join(parts)
        if text:
            return text
        time.sleep(0.3)
    return ""


SUMMARY_LINE = re.compile(r"^\W*(?:кратко|summary|tl;?dr)\W*[:—-]\W*(.+)$", re.I | re.M)


def trailing_question(md):
    """The question in the last paragraph, if the answer ends by asking the user something."""
    paras = [p.strip() for p in re.split(r"\n\s*\n", md.strip()) if p.strip()]
    if not paras or "?" not in paras[-1]:
        return None
    qs = re.findall(r"[^.!?\n]*\?", clean_md(paras[-1]))
    return qs[-1].strip() if qs else None


def summarize(md, limit):
    m = SUMMARY_LINE.search(md)
    q = trailing_question(md)
    if m:
        md = m.group(1)
    out = shorten(clean_md(md), limit)
    if q and q not in out:
        out = f"{out} Вопрос: {q}"
    return out


def clean_md(md):
    t = re.sub(r"```.*?```", " ", md, flags=re.S)          # code blocks
    t = re.sub(r"^\s*\|.*\|\s*$", " ", t, flags=re.M)       # table rows
    t = re.sub(r"\[([^\]]+)\]\([^)]*\)", r"\1", t)          # links -> text
    t = re.sub(r"`([^`]*)`", r"\1", t)
    t = re.sub(r"^\s*#+\s*(.*?)[.:!?]?\s*$", r"\1.", t, flags=re.M)  # headings -> sentences
    t = re.sub(r"^\s*[-*>\d.]+\s+", "", t, flags=re.M)      # bullets / quotes
    t = re.sub(r"[*_~]", "", t)
    t = re.sub(r"https?://\S+", "", t)
    return re.sub(r"\s+", " ", t).strip()


def shorten(t, limit):
    sentences = re.split(r"(?<=[.!?…])\s+", t)
    out = ""
    for s in sentences:
        if len(out) + len(s) > limit and out:
            break
        out = f"{out} {s}".strip()
        if len(out) >= limit * 0.6:
            break
    return out[:limit]


# ---------- audio ----------

def say(text, c):
    tts_process(text, c).wait()


def beep(name="Tink"):
    subprocess.run(["afplay", f"/System/Library/Sounds/{name}.aiff"], check=False)


def write_state(state, **kw):
    kw.update(state=state, t=time.time())
    tmp = STATE.with_suffix(".tmp")
    tmp.write_text(json.dumps(kw, ensure_ascii=False))
    os.replace(tmp, STATE)


def take_control():
    """HUD command: 'send' | 'cancel' | 'skip' | 'repeat' | 'text\n<typed reply>'."""
    try:
        raw = CONTROL.read_text()
        CONTROL.unlink()
    except OSError:
        return None, None
    cmd, _, payload = raw.partition("\n")
    return cmd.strip(), payload.strip()


class Listener:
    """Keeps the mic open across phrases (ffmpeg takes ~1 s to open the device).

    Energy VAD on 100 ms frames: the first 0.5 s calibrate the room noise floor;
    speech = 3+ consecutive frames louder than floor + speech_margin_db."""

    RATE, FRAME = 16000, 1600  # 100 ms

    def __init__(self, c, ui):
        self.c, self.ui = c, ui
        cmd = ["ffmpeg", "-hide_banner", "-nostdin", "-loglevel", "error",
               "-f", "avfoundation", "-i", f":{c['mic']}",
               "-ac", "1", "-ar", str(self.RATE), "-f", "s16le", "-"]
        self.p = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
        # Drain ffmpeg continuously: if the pipe fills up (e.g. while whisper runs),
        # ffmpeg blocks and then hangs on shutdown.
        self.q = queue.Queue()
        threading.Thread(target=self._pump, daemon=True).start()
        calib = [self._frame()[1] for _ in range(5)]
        self.floor = max(sorted(calib)[2], c["min_floor_db"])

    def _pump(self):
        size = self.FRAME * 2
        while True:
            chunk = self.p.stdout.read(size)
            if len(chunk) < size:
                self.q.put(None)
                return
            self.q.put(chunk)

    def _frame(self):
        chunk = self.q.get(timeout=5)
        if chunk is None:
            raise EOFError
        samples = array.array("h", chunk)
        rms = math.sqrt(sum(s * s for s in samples) / len(samples)) or 1
        return chunk, 20 * math.log10(rms / 32768)

    def phrase(self, wait_sec, cue=None, deadline=None):
        """Record one phrase. Returns (pcm, how, payload):
        how = pause | send | cancel | timeout | repeat | text."""
        if cue:
            subprocess.Popen(["afplay", f"/System/Library/Sounds/{cue}.aiff"])
        pcm, frames, loud_run, quiet, speaking = bytearray(), 0, 0, 0, False
        skip = 4 if cue else 0  # don't hear our own cue
        while True:
            chunk, db = self._frame()
            frames += 1
            t = frames / 10
            cmd, payload = take_control()
            if cmd in ("cancel", "repeat", "text"):
                return None, cmd, payload
            if cmd == "send" or (deadline and time.time() > deadline):
                return (pcm if speaking else None), "send", None
            if frames <= skip:
                continue
            loud = db > self.floor + self.c["speech_margin_db"]
            if frames % 2 == 0:
                self.ui(level=max(0.0, min(1.0, (db - self.floor) / 30)),
                        left=None if speaking else max(0.0, wait_sec - t))
            if not speaking:
                pcm += chunk
                del pcm[:-self.FRAME * 2 * 5]  # keep 0.5 s pre-roll
                loud_run = loud_run + 1 if loud else 0
                if loud_run >= 3:
                    speaking = True
                elif t > wait_sec:
                    return None, "timeout", None
            else:
                pcm += chunk
                quiet = 0 if loud else quiet + 1
                if quiet >= self.c["silence_sec"] * 10:
                    return pcm, "pause", None
                if len(pcm) > self.c["max_sec"] * self.RATE * 2:
                    return pcm, "pause", None

    def drop_backlog(self):
        while not self.q.empty():
            self.q.get_nowait()

    def close(self):
        self.p.kill()
        try:
            self.p.wait(timeout=2)
        except subprocess.TimeoutExpired:
            pass


def to_wav(pcm):
    wav = tempfile.mktemp(suffix=".wav", prefix="voice-loop-")
    with wave.open(wav, "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(Listener.RATE)
        w.writeframes(bytes(pcm))
    return wav


def strip_tail(text, words):
    """If text ends with one of words, return text without it; else None."""
    t = text.rstrip(" .,!?…")
    low = t.lower()
    for w in words:
        if low == w or re.search(rf"[\s,.!?—-]{re.escape(w)}$", low):
            return t[: len(t) - len(w)].rstrip(" .,!?—-")
    return None


def transcribe(wav, c):
    cmd = [c["whisper"], "-m", c["model"], "-f", wav, "-l", c["language"], "-nt", "-np"]
    if c.get("prompt"):
        cmd += ["--prompt", c["prompt"]]
    r = subprocess.run(cmd, capture_output=True, text=True)
    text = re.sub(r"\s+", " ", r.stdout).strip()
    text = re.sub(r"\[[^\]]*\]|\([^)]*\)", "", text).strip()  # [музыка], (шум)
    low = text.lower()
    if any(h in low for h in HALLUCINATIONS):
        log(f"dropped hallucination: {text!r}")
        return ""
    return text


def _rm(p):
    try:
        os.remove(p)
    except OSError:
        pass


def _norm(text):
    return re.sub(r"\s+", " ", re.sub(r"[^\w\s']", "", text.lower())).strip()


def is_stop(text):
    t = _norm(text)
    return not t or t in STOP_WORDS


def is_repeat(text):
    return _norm(text) in REPEAT_WORDS


# ---------- hook ----------

PIPER = SCRIPT.parent / ".venv" / "bin" / "piper"
VOICES_DIR = STATE_DIR / "voices"


def tts_process(text, c):
    """Start speaking text; returns the playing process."""
    if c["tts"] == "piper" and PIPER.exists():
        for old in Path(tempfile.gettempdir()).glob("voice-loop-tts-*.wav"):
            _rm(old)
        wav = tempfile.mktemp(suffix=".wav", prefix="voice-loop-tts-")
        model = VOICES_DIR / f"{c['piper_voice']}.onnx"
        r = subprocess.run([str(PIPER), "-m", str(model), "-f", wav, "--", text],
                           capture_output=True)
        if r.returncode == 0:
            return subprocess.Popen(["afplay", wav])
        log(f"piper failed, falling back to say: {r.stderr[-200:]!r}")
    return subprocess.Popen(["say", "-v", c["voice"], "-r", str(c["rate"]), text])


def speak(text, c):
    """Speak text; the HUD can skip or cancel. Returns None | 'skip' | 'cancel' | 'text'."""
    sp = tts_process(text, c)
    try:
        while sp.poll() is None:
            cmd, payload = take_control()
            if cmd in ("skip", "cancel", "send"):
                return "skip" if cmd == "send" else cmd
            if cmd == "text":
                speak.payload = payload
                return "text"
            time.sleep(0.1)
    finally:
        if sp.poll() is None:
            sp.terminate()
    return None


def converse(project, summary, c):
    """Speak the summary, then listen for the next instruction.
    Returns the instruction text, or None to let the agent stop."""
    deadline = time.time() + HOOK_TIMEOUT - 25  # leave time for the last transcription
    session = {"project": project, "summary": summary}

    def ui(state=None, **kw):
        if state:
            session["state"] = state
            session.pop("level", None)
            session.pop("left", None)
        session.update(kw)
        write_state(session["state"], **{k: v for k, v in session.items() if k != "state"})

    def finish(text):
        if not text or is_stop(text):
            ui("released")
            beep("Bottle")
            return None
        ui("sent", text=text)
        beep("Pop")
        return text

    take_control()  # drop stale clicks
    ui("speaking")
    r = speak(f"{project}: готово. {summary}", c)
    if r == "cancel":
        return finish(None)
    if r == "text":
        return finish(speak.payload)

    lis = Listener(c, ui)
    parts, wait, cue = [], c["wait_sec"], "Tink"
    try:
        while True:
            ui("listening", text=" ".join(parts))
            pcm, how, payload = lis.phrase(wait, cue, deadline)
            if how == "cancel":
                return finish(None)
            if how == "text":
                return finish(" ".join(parts + [payload]))
            if how == "repeat":
                ui("speaking")
                speak(summary, c)
                lis.drop_backlog()  # don't transcribe our own voice
                wait, cue = c["wait_sec"], "Tink"
                continue
            if pcm is None:  # timeout, or «send» with nothing new
                return finish(" ".join(parts))
            ui("transcribing", text=" ".join(parts))
            wav = to_wav(pcm)
            text = transcribe(wav, c)
            _rm(wav)
            log(f"phrase: {text!r} ({how})")
            if strip_tail(text, CANCEL_WORDS) is not None:
                return finish(None)
            if not parts and is_repeat(text):
                ui("speaking")
                speak(summary, c)
                lis.drop_backlog()
                wait, cue = c["wait_sec"], "Tink"
                continue
            if how == "send":
                parts.append(text)
                break
            sent = strip_tail(text, SEND_WORDS)
            if sent is not None:
                parts.append(sent)
                break
            held = strip_tail(text, HOLD_WORDS)
            if held is not None:
                parts.append(held)
                wait, cue = c["hold_sec"], "Morse"
                continue
            parts.append(text)
            break
    except Exception:
        ui("idle")
        raise
    finally:
        lis.close()
    return finish(" ".join(p for p in parts if p).strip())


def acquire_lock(c):
    STATE_DIR.mkdir(exist_ok=True)
    lock = open(LOCK, "w")
    deadline = time.time() + c["lock_wait_sec"]
    while True:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            return lock
        except BlockingIOError:
            if time.time() > deadline:
                return None
            time.sleep(0.5)


def project_allowed(project, c):
    return not c["projects"] or project in c["projects"]


def is_duplicate(session_id, text):
    key = f"{session_id}:{hashlib.sha1(text.encode()).hexdigest()}"
    try:
        last = json.loads(LAST.read_text())
    except Exception:
        last = {}
    if last.get("key") == key and time.time() - last.get("at", 0) < 300:
        return True
    LAST.write_text(json.dumps({"key": key, "at": time.time()}))
    return False


def hook():
    """Claude Code Stop hook."""
    try:
        data = json.load(sys.stdin)
    except Exception:
        data = {}
    if not FLAG.exists() or os.environ.get("VOICE_LOOP_OFF"):
        return
    c = cfg()
    project = Path(data.get("cwd") or os.getcwd()).name
    if not project_allowed(project, c):
        return
    log(f"stop: project={project} session={data.get('session_id')} "
        f"entry={os.environ.get('CLAUDE_CODE_ENTRYPOINT')} active={data.get('stop_hook_active')}")
    lock = acquire_lock(c)
    if not lock:
        log("lock timeout, skipping")
        return
    text = last_assistant_text(data)
    if is_duplicate(data.get("session_id"), text):
        log("duplicate stop for the same turn, skipping")
        return
    reply = converse(project, summarize(text, c["summary_chars"]), c)
    log(f"heard: {reply!r}")
    if reply:
        print(json.dumps({
            "decision": "block",
            "reason": f"Пользователь ответил голосом или с плашки voice-loop (голос распознан "
                      f"локально, возможны ошибки распознавания): {reply}\n\n{VOICE_CONTEXT}",
        }, ensure_ascii=False))


# ---------- install ----------

VOICE_CONTEXT = (
    "Голосовой режим voice-loop включён: итог твоего ответа будет озвучен вслух. "
    "Начинай каждый финальный ответ отдельной строкой «**Кратко:** …» — 1–2 короткие "
    "разговорные фразы: что сделано и нужно ли что-то от пользователя. Без путей, кода, "
    "ссылок и markdown внутри этой строки; английские термины пиши кириллицей, как их "
    "произносят (кодекс, хук, пул-реквест). Если ждёшь ответа — задай вопрос в этой же "
    "строке. Подробности — ниже, как обычно."
)

# event -> (subcommand, timeout)
HOOKS = {"Stop": ("hook", HOOK_TIMEOUT), "UserPromptSubmit": ("prompt", 10)}


def hook_command(sub):
    return f"{shutil.which('python3') or sys.executable} '{SCRIPT}' {sub}"


def _ours(group):
    return any("voice_loop.py" in h.get("command", "") for h in group.get("hooks", []))


def install():
    settings = json.loads(CLAUDE_SETTINGS.read_text()) if CLAUDE_SETTINGS.exists() else {}
    backup = CLAUDE_SETTINGS.with_suffix(".json.voice-loop-backup")
    if CLAUDE_SETTINGS.exists() and not backup.exists():
        shutil.copy(CLAUDE_SETTINGS, backup)
    hooks = settings.setdefault("hooks", {})
    for event, (sub, timeout) in HOOKS.items():
        groups = [g for g in hooks.get(event, []) if not _ours(g)]
        groups.append({"hooks": [{"type": "command", "command": hook_command(sub),
                                  "timeout": timeout}]})
        hooks[event] = groups
    CLAUDE_SETTINGS.write_text(json.dumps(settings, indent=2, ensure_ascii=False) + "\n")
    print(f"installed {', '.join(HOOKS)} hooks into {CLAUDE_SETTINGS} (backup: {backup.name})")
    print("ON" if FLAG.exists() else "voice is OFF — run: voice_loop.py on")


def uninstall():
    if not CLAUDE_SETTINGS.exists():
        return
    settings = json.loads(CLAUDE_SETTINGS.read_text())
    hooks = settings.get("hooks", {})
    for event in HOOKS:
        groups = [g for g in hooks.get(event, []) if not _ours(g)]
        if groups:
            hooks[event] = groups
        else:
            hooks.pop(event, None)
    if not hooks:
        settings.pop("hooks", None)
    CLAUDE_SETTINGS.write_text(json.dumps(settings, indent=2, ensure_ascii=False) + "\n")
    print("uninstalled")


def main():
    cmd = sys.argv[1] if len(sys.argv) > 1 else "status"
    STATE_DIR.mkdir(exist_ok=True)
    if cmd == "hook":
        try:
            hook()
        except Exception as e:  # never break the Claude session
            log(f"error: {e!r}")
    elif cmd == "prompt":  # UserPromptSubmit: remind Claude to lead with a spoken summary
        if FLAG.exists():
            print(VOICE_CONTEXT)
    elif cmd == "on":
        FLAG.touch()
        print("voice-loop ON")
    elif cmd == "off":
        FLAG.unlink(missing_ok=True)
        print("voice-loop OFF")
    elif cmd == "status":
        print("ON" if FLAG.exists() else "OFF")
    elif cmd == "install":
        install()
    elif cmd == "uninstall":
        uninstall()
    elif cmd == "say":
        say(" ".join(sys.argv[2:]) or "Проверка голоса", cfg())
    elif cmd == "listen":
        print(repr(converse("тест", "Проверка микрофона.", cfg())))
    else:
        print(__doc__)


if __name__ == "__main__":
    main()
