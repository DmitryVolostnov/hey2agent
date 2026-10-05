#!/usr/bin/env python3
"""hey2agent (voice_loop.py): when a Claude Code turn ends, speak a short summary, listen, and feed
the dictated text back as the next instruction (Stop hook, decision=block).

Stdlib only. External tools: ffmpeg (mic), whisper-cli (local STT), say/afplay (macOS).
Nothing leaves the machine.

  voice_loop.py on | off | status     toggle via flag file
  voice_loop.py mute | unmute         meetings: stay silent, HUD still shows finished sessions
  voice_loop.py models                list speech models (✓ = downloaded)
  voice_loop.py download-model <id>   turbo | turbo-q5 | small | base | tiny
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
import select
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
MUTED = STATE_DIR / "muted"           # meetings: no speech, no mic; HUD still lists sessions
LOCK = STATE_DIR / "lock"
LOG = STATE_DIR / "log.txt"
STATE = STATE_DIR / "state.json"      # read by the HUD
SESSIONS = STATE_DIR / "sessions.json"  # sessions in progress, read by the HUD
CONTROL = STATE_DIR / "control"       # written by the HUD: send | cancel
LAST = STATE_DIR / "last.json"  # dedupe: the Stop hook can fire twice for one turn
CONFIG = STATE_DIR / "config.json"
CLAUDE_SETTINGS = HOME / ".claude" / "settings.json"
SCRIPT = Path(__file__).resolve()
HOOK_TIMEOUT = 600  # seconds; Claude Code kills the hook after this (long enough to answer from the phone)
REMOTE = STATE_DIR / "remote"  # touched by the panel while an iPhone is connected

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
    "undo_sec": 3.0,             # recognized text waits this long before sending (0 = off)
    "hold_sec": 30.0,            # after «подожди»: how long to wait for the continuation
    "max_sec": 90.0,             # hard cap on one utterance
    "language": "ru",            # whisper language: ru | en | auto (auto is slower, misfires on short phrases)
    "whisper": "/opt/homebrew/bin/whisper-cli",
    "model": "",                 # whisper ggml model; empty = auto-detect (see find_model)
    # Vocabulary hint for whisper: dev jargon in mixed Russian/English.
    "prompt": "Закоммить, запушь, коммит, пул-реквест, ветка, тесты, билд, деплой, рефакторинг, "
              "Claude, Codex, hook, pipeline, SwiftUI, MCP, Screenpipe.",
    "summary_chars": 220,
    "lock_wait_sec": 120,        # wait for another session to finish talking
    "projects": [],              # only speak in these project folders (empty = everywhere)
}

STOP_WORDS = {"стоп", "хватит", "всё", "все", "ничего", "пока", "не надо", "отбой",
              "stop", "nothing", "that's it", "no"}
# «Got it» replies that just close the turn — in every interface language. A phrase made only of
# these (plus fillers like «большое») closes; «ок, теперь сделай …» still goes to the agent.
CLOSE_WORDS = {
    "ок", "окей", "оке", "окей-окей", "спасибо", "понял", "поняла", "понятно", "ладно", "отлично",
    "норм", "нормально", "супер", "класс", "молодец", "молодцы", "умница", "круто",
    "ok", "okay", "kay", "thanks", "thank", "thx", "got", "cool", "nice", "perfect", "great", "awesome",
    "дякую", "зрозумів", "зрозуміла", "гаразд", "добре",
    "danke", "alles", "klar", "passt", "gut",
    "gracias", "vale", "entendido", "perfecto",
    "merci", "d'accord", "compris", "parfait",
    "grazie", "capito", "perfetto", "bene",
    "obrigado", "obrigada", "entendi", "beleza",
    "ありがとう", "ありがとうございます", "了解", "了解です", "オッケー", "わかった", "わかりました",
    "谢谢", "好的", "明白了", "收到",
}
CLOSE_FILLERS = {"большое", "огромное", "хорошо", "ты", "вы", "очень", "you", "it", "a", "lot", "so", "much", "very",
                 "job", "good", "well", "done", "work", "bien", "mille",
                 "muchas", "vielen", "bene", "va", "beaucoup", "muito", "дуже", "тебе", "вам", "всё", "все"}

# Said at the end of a phrase.
SEND_WORDS = ["отправляй", "отправить", "отправь", "отправка", "send it", "send"]
HOLD_WORDS = ["надо подумать", "дай подумать", "подожди", "подождите", "секунду", "секундочку",
              "wait"]
REPEAT_WORDS = {"повтори", "повтори пожалуйста", "повтори ещё раз", "повтори еще раз", "ещё раз",
                "еще раз", "не расслышал", "что", "repeat", "wiederholen", "repite", "répète", "repete",
                "ripeti", "もう一度", "重复"}
CANCEL_WORDS = ["отмена", "отменить", "отмени", "cancel"]

# Classic whisper hallucinations on silence / noise.
HALLUCINATIONS = ["субтитры", "продолжение следует", "спасибо за просмотр", "dimatorzok",
                  "редактор субтитров", "подписывайтесь", "thank you for watching",
                  "thanks for watching", "amara.org"]


# Whisper models (whisper.cpp ggml builds on Hugging Face), best first.
MODELS = [
    # id, file, MB, note
    ("turbo", "ggml-large-v3-turbo-q8_0.bin", 874, "best for mixed Russian/English (default)"),
    ("turbo-q5", "ggml-large-v3-turbo-q5_0.bin", 574, "almost the same quality, 1/3 smaller"),
    ("small", "ggml-small-q5_1.bin", 190, "faster, mistakes with English terms"),
    ("base", "ggml-base.bin", 148, "fast, weak for Russian"),
    ("tiny", "ggml-tiny.bin", 78, "fastest, weakest"),
]
MODEL_NAME = MODELS[0][1]
MODEL_BASE_URL = "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/"
DOWNLOAD = STATE_DIR / "download.json"  # progress for the HUD


def list_models():
    """Downloaded whisper models (≥ 50 MB, so a half-finished download is never picked)."""
    found = sorted((STATE_DIR / "models").glob("ggml-*.bin"))
    found += sorted((HOME / ".cache/huggingface/hub").glob("models--ggerganov--whisper.cpp/snapshots/*/ggml-*.bin"))
    return [p for p in found if p.stat().st_size > 50_000_000]


def find_model():
    """Default: the best downloaded model in MODELS order, else any downloaded model."""
    models = list_models()
    rank = {f: i for i, (_, f, _, _) in enumerate(MODELS)}
    models.sort(key=lambda p: rank.get(p.name, len(rank)))
    return str(models[0]) if models else ""


def download_model(model_id):
    """Download a model into ~/.voice-loop/models with resume + retries; progress in download.json."""
    entry = next((m for m in MODELS if m[0] == model_id), None)
    if not entry:
        sys.exit(f"unknown model {model_id}; choose: {', '.join(m[0] for m in MODELS)}")
    _, name, mb, _ = entry
    dest = STATE_DIR / "models" / name
    part = dest.with_suffix(".part")
    dest.parent.mkdir(parents=True, exist_ok=True)
    if dest.exists():
        print(f"{name} already downloaded")
        return
    p = subprocess.Popen(["curl", "-sL", "--fail", "-C", "-", "--retry", "20", "--retry-delay", "5",
                          "--retry-all-errors", "-o", str(part), MODEL_BASE_URL + name])
    total = mb * 1_000_000
    while p.poll() is None:
        done = part.stat().st_size if part.exists() else 0
        DOWNLOAD.write_text(json.dumps({"id": model_id, "done": done, "total": total, "t": time.time()}))
        if sys.stdout.isatty():
            print(f"\r{name}: {done * 100 // total}% of {mb} MB", end="", flush=True)
        time.sleep(1)
    _rm(DOWNLOAD)
    if p.returncode == 0 and part.exists():
        part.rename(dest)
        print(f"\ndownloaded {dest}")
    else:
        sys.exit(f"\ndownload failed (curl exit {p.returncode}); run again to resume")


def cfg():
    c = dict(DEFAULTS)
    if CONFIG.exists():
        try:
            c.update(json.loads(CONFIG.read_text()))
        except Exception as e:
            log(f"bad config: {e}")
    if not c["model"]:
        c["model"] = find_model()
    if c["whisper"] and not os.path.exists(c["whisper"]):
        c["whisper"] = shutil.which("whisper-cli") or c["whisper"]
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


SUMMARY_LINE = re.compile(
    r"^\W*(?:кратко|коротко|summary|tl;?dr|resumen|résumé|resume|zusammenfassung|kurz|riepilogo|"
    r"in breve|resumo|要約|概要|摘要|总结|總結)\W*[:：—-]\W*(.+)$", re.I | re.M)


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
    """Fire and forget: a hung audio device must never keep the hook (and the agent) waiting."""
    try:
        subprocess.Popen(["afplay", f"/System/Library/Sounds/{name}.aiff"],
                         stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True)
    except OSError:
        pass


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


class MicError(Exception):
    """ffmpeg could not open the mic — usually no microphone permission for the calling app."""


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
        try:
            calib = [self._frame()[1] for _ in range(5)]
        except (EOFError, queue.Empty):
            self.close()
            raise MicError("нет доступа к микрофону")
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
            if cmd == "phone":  # the user is recording on the iPhone: ignore the Mac mic
                self.phone = True
                self.ui(state="phone")
                continue
            if cmd == "audio":  # recording from the iPhone
                return read_wav(payload), "pause", None
            if cmd == "send" or (deadline and time.time() > deadline):
                return (pcm if speaking else None), "send", None
            if getattr(self, "phone", False):
                continue
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


def read_wav(path):
    """16 kHz mono PCM of a wav (phone recordings are converted if needed)."""
    out = tempfile.mktemp(suffix=".wav", prefix="voice-loop-phone-")
    subprocess.run(["ffmpeg", "-loglevel", "error", "-y", "-i", path, "-ac", "1", "-ar", "16000",
                    "-f", "s16le", out], check=False)
    try:
        return bytearray(Path(out).read_bytes())
    finally:
        _rm(out)
        _rm(path)


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
    t0 = time.time()
    r = subprocess.run(cmd, capture_output=True, text=True)
    log(f"transcribed in {time.time() - t0:.1f}s with {Path(c['model']).name}")
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
    if not t or t in STOP_WORDS:
        return True
    words = t.replace("-", " ").split()
    return any(w in CLOSE_WORDS for w in words) and all(w in CLOSE_WORDS or w in CLOSE_FILLERS for w in words)


def is_repeat(text):
    return _norm(text) in REPEAT_WORDS


# ---------- sessions registry (for the HUD list) ----------

CODEX_STATE = HOME / ".codex" / "state_5.sqlite"


def codex_title(transcript_path):
    """The chat name in the Codex sidebar (its own threads table, opened read-only)."""
    m = re.search(r"([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})\.jsonl$", transcript_path or "")
    db = max(CODEX_STATE.parent.glob("state_*.sqlite"), default=None, key=lambda p: p.stat().st_mtime)
    if not m or not db:
        return None
    try:
        import sqlite3
        con = sqlite3.connect(f"file:{db}?mode=ro", uri=True, timeout=1)
        row = con.execute("select coalesce(nullif(name, ''), nullif(title, '')) from threads where id = ?",
                          (m.group(1),)).fetchone()
        con.close()
    except Exception:
        return None
    title = (row or [None])[0]
    return shorten(" ".join(title.split()), 60) if title else None


def session_title(transcript_path, fallback):
    """Latest custom-title from a Claude Code transcript (the name shown in the sidebar)."""
    if "/.codex/" in (transcript_path or ""):
        return codex_title(transcript_path) or fallback
    try:
        with open(transcript_path, "rb") as f:
            f.seek(0, 2)
            f.seek(max(0, f.tell() - 400_000))
            tail = f.read().decode("utf-8", "ignore")
        titles = re.findall(r'"customTitle"\s*:\s*"((?:[^"\\]|\\.)*)"', tail)
        if titles:
            return json.loads(f'"{titles[-1]}"')
    except (OSError, TypeError, ValueError):
        pass
    return fallback


def agent_of(data):
    t = data.get("transcript_path") or ""
    if "/.codex/" in t:
        return "codex"
    return "claude-desktop" if os.environ.get("CLAUDE_CODE_ENTRYPOINT") == "claude-desktop" else "claude-cli"


def load_sessions():
    try:
        return json.loads(SESSIONS.read_text())
    except Exception:
        return {}


def update_session(data, status, prompt=None):
    """status: working | waiting | finished (done while muted) | done → kept as «idle»
    (recent chats in the HUD, pruned after 3 days)."""
    sid = data.get("session_id")
    if not sid:
        return
    STATE_DIR.mkdir(exist_ok=True)
    with open(STATE_DIR / "sessions.lock", "w") as lk:
        fcntl.flock(lk, fcntl.LOCK_EX)
        reg = load_sessions()
        now = time.time()
        cur = reg.get(sid, {})
        project = Path(data.get("cwd") or cur.get("cwd") or ".").name
        fallback = cur.get("title") or (prompt or "").strip().split("\n")[0][:60] or project
        if status == "done":
            status = "idle"
        if status == "working" and cur.get("status") != "working":
            cur["since"] = now
        if prompt is not None:
            cur.pop("note", None)
        cur.setdefault("since", now)
        cur.update(project=project, status=status, updated=now,
                   cwd=data.get("cwd") or cur.get("cwd"),
                   transcript=data.get("transcript_path") or cur.get("transcript"),
                   agent=cur.get("agent") or agent_of(data),
                   title=session_title(data.get("transcript_path") or cur.get("transcript"), fallback))
        if status in ("idle", "finished"):
            cur["ended"] = now
        reg[sid] = cur
        reg = {k: v for k, v in reg.items() if now - v.get("updated", 0) < 3 * 86400}
        tmp = SESSIONS.with_suffix(".tmp")
        tmp.write_text(json.dumps(reg, ensure_ascii=False))
        os.replace(tmp, SESSIONS)


# ---------- cancelling a message that was already sent ----------

CANCEL_DIR = STATE_DIR / "cancel"
CANCEL_REASON = ("The user cancelled their last message (the «Undo» button in hey2agent). Do not "
                 "continue this task and take no further actions. In one sentence, in the language "
                 "of the conversation, confirm you stopped and list what you already changed, if anything.")


def cancel_marker(sid):
    return CANCEL_DIR / re.sub(r"[^\w-]", "", sid or "")


def is_cancelled(sid, max_age=15 * 60):
    try:
        return bool(sid) and time.time() - cancel_marker(sid).stat().st_mtime < max_age
    except OSError:
        return False


TOOL_KINDS = {  # tool → activity kind shown next to the project (worded by the apps)
    "Read": "read", "NotebookRead": "read",
    "Edit": "edit", "MultiEdit": "edit", "Write": "edit", "NotebookEdit": "edit",
    "Bash": "run", "BashOutput": "run",
    "Grep": "search", "Glob": "search", "LS": "search",
    "WebFetch": "web", "WebSearch": "web",
    "Task": "agent", "Agent": "agent",
}


def activity_of(data):
    """(kind, target) for a PreToolUse payload, e.g. ('edit', 'Views.swift')."""
    tool = data.get("tool_name") or ""
    inp = data.get("tool_input") or {}
    kind = TOOL_KINDS.get(tool, "mcp" if tool.startswith("mcp__") else "tool")
    path = inp.get("file_path") or inp.get("notebook_path") or inp.get("path") or ""
    if path:
        target = Path(path).name
    elif tool == "Bash":
        target = (inp.get("description") or (inp.get("command") or "").split("\n")[0])[:40]
    elif kind == "search":
        target = (inp.get("pattern") or "")[:30]
    elif kind == "web":
        target = re.sub(r"^https?://(www\.)?", "", inp.get("url") or inp.get("query") or "")[:30]
    elif kind == "agent":
        target = (inp.get("description") or "")[:30]
    elif kind == "mcp":
        target = tool.split("__")[-1][:30]
    else:
        target = tool[:30]
    return kind, target


def turn_note(transcript_path, limit=140):
    """The latest text Claude wrote in the current turn («Нашёл причину…»), from the transcript
    tail; None if it hasn't written anything since the user's last message."""
    try:
        with open(transcript_path, "rb") as f:
            f.seek(0, 2)
            f.seek(max(0, f.tell() - 300_000))
            lines = f.read().decode("utf-8", "ignore").splitlines()[1:]
    except (OSError, TypeError):
        return None
    note = None
    for line in lines:
        try:
            e = json.loads(line)
        except ValueError:
            continue
        content = (e.get("message") or {}).get("content")
        if e.get("type") == "user":
            is_prompt = isinstance(content, str) or (
                isinstance(content, list) and not any(b.get("type") == "tool_result" for b in content))
            if is_prompt:
                note = None  # a new turn starts here
        elif e.get("type") == "assistant" and isinstance(content, list):
            texts = [b.get("text", "") for b in content if b.get("type") == "text" and b.get("text", "").strip()]
            if texts:
                note = texts[-1]
    if not note:
        return None
    first = clean_md(note.strip().split("\n")[0])
    return first[:limit]


def set_activity(sid, kind, target, note=None):
    """Cheap registry update on every tool call: what the agent is doing right now."""
    if not sid:
        return
    with open(STATE_DIR / "sessions.lock", "w") as lk:
        fcntl.flock(lk, fcntl.LOCK_EX)
        reg = load_sessions()
        cur = reg.get(sid)
        if not cur or cur.get("status") != "working":
            return
        cur.update(activity=kind, activity_target=target, activity_t=time.time(), note=note)
        tmp = SESSIONS.with_suffix(".tmp")
        tmp.write_text(json.dumps(reg, ensure_ascii=False))
        os.replace(tmp, SESSIONS)


def pretool_hook():
    """Claude Code PreToolUse: record the current activity; after «Отменить», deny every
    tool call so Claude stops."""
    try:
        data = json.load(sys.stdin)
    except Exception:
        return
    try:
        set_activity(data.get("session_id"), *activity_of(data), note=turn_note(data.get("transcript_path")))
    except Exception as e:
        log(f"activity error: {e!r}")
    if is_cancelled(data.get("session_id")):
        print(json.dumps({"hookSpecificOutput": {
            "hookEventName": "PreToolUse",
            "permissionDecision": "deny",
            "permissionDecisionReason": CANCEL_REASON,
        }}, ensure_ascii=False))


# ---------- sending to a chat that is not waiting (HUD: click a recent chat) ----------

CODEX_BIN = ["/Applications/ChatGPT.app/Contents/Resources/codex-cli/bin/codex",
             "/Applications/ChatGPT.app/Contents/Resources/codex",
             "/Applications/Codex.app/Contents/Resources/codex"]


CLAUDE_APP_SESSIONS = HOME / "Library/Application Support/Claude/claude-code-sessions"


def desktop_session_id(cli_sid):
    """Claude app keeps local_<id>.json per chat with the Claude Code session id inside."""
    for f in CLAUDE_APP_SESSIONS.glob("*/*/local_*.json"):
        try:
            if cli_sid in f.read_text() and json.loads(f.read_text()).get("cliSessionId") == cli_sid:
                return json.loads(f.read_text()).get("sessionId")
        except (OSError, ValueError):
            continue
    return None


def open_chat(sid, entry):
    """Bring the chat to the front: Claude app via its own deep link, Codex app, or nothing."""
    agent = (entry or {}).get("agent")
    if (entry or {}).get("status") == "finished":
        update_session({"session_id": sid}, "done")  # seen → moves to «Недавние»
    if agent == "claude-desktop":
        local = desktop_session_id(sid)
        if local:
            subprocess.run(["open", f"claude://code/continue?session={local}"])
            return True
        subprocess.run(["open", "-a", "Claude"])
    elif agent == "codex":
        subprocess.run(["open", f"codex://threads/{sid}"])  # the Codex app's own deep link
        return True
    return False


def deliver(sid, entry, text):
    """Returns a short human status. Claude app chats cannot be driven from outside,
    so the text goes to the clipboard and Claude is brought to the front."""
    agent = entry.get("agent")
    if agent == "codex":
        codex = codex_bin()
        if codex:
            r = subprocess.run([codex, "queue", "--thread", sid, "--message", text],
                               capture_output=True, text=True, timeout=30)
            if r.returncode == 0:
                return "queued"
            log(f"codex queue failed: {r.stderr[-300:]!r}")
    elif agent == "claude-cli" and shutil.which("claude"):
        # Headless continuation of the same session; its Stop hook speaks the answer.
        subprocess.Popen(["claude", "-p", "--resume", sid, text], cwd=entry.get("cwd") or None,
                         stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True)
        return "resumed"
    subprocess.run(["pbcopy"], input=text, text=True)
    open_chat(sid, entry)  # the right chat is already open: just ⌘V ↩
    return "clipboard"


def dictate_to(sid, wav=None):
    """HUD / iPhone: dictate a message for a chat that is not currently waiting in a hook.
    wav: a recording made on the iPhone (then the Mac mic isn't used)."""
    c = cfg()
    entry = load_sessions().get(sid)
    if not entry:
        return
    lock = acquire_lock(c)
    if not lock:
        return
    title = entry.get("title") or entry.get("project")
    session = {"project": title, "summary": "", "session_id": sid,
               "cancellable": entry.get("agent") != "codex"}

    def ui(state=None, **kw):
        if state:
            session["state"] = state
            session.pop("level", None)
            session.pop("left", None)
        session.update(kw)
        write_state(session["state"], **{k: v for k, v in session.items() if k != "state"})

    take_control()
    deadline = time.time() + 170
    if wav:
        ui("transcribing")
        pcm = read_wav(wav)
        tmp = to_wav(pcm)
        text = transcribe(tmp, c)
        _rm(tmp)
        log(f"phone phrase: {text!r}")
        if not text or is_stop(text) or strip_tail(text, CANCEL_WORDS) is not None:
            ui("released")
            return
        verdict, text = confirm(text, c, ui, deadline)
        if verdict != "send":  # «again» from a phone recording = record again on the phone
            ui("released")
            return
        return _deliver_and_report(sid, entry, text, ui)
    lis = Listener(c, ui)
    try:
        prefix = None
        while True:
            text, typed = listen(lis, c, ui, "", deadline, prefix)
            if not text or (not typed and is_stop(text)):
                ui("released")
                beep("Bottle")
                return
            verdict, text = confirm(text, c, ui, deadline) if not typed else ("send", text)
            if verdict in ("again", "append"):
                prefix = text if verdict == "append" else None
                lis.drop_backlog()
                continue
            if verdict == "cancel":
                ui("released")
                beep("Bottle")
                return
            break
    finally:
        lis.close()
    _deliver_and_report(sid, entry, text, ui)


def _deliver_and_report(sid, entry, text, ui):
    how = deliver(sid, entry, text)
    log(f"dictate_to {sid} ({entry.get('agent')}): {how} {text!r}")
    ui("sent", text=text, delivery=how)
    beep("Pop")
    if how in ("queued", "resumed"):
        update_session({"session_id": sid}, "working")


def prompt_hook():
    """Claude Code UserPromptSubmit: mark the session busy; remind about the spoken summary."""
    try:
        data = json.load(sys.stdin)
    except Exception:
        data = {}
    _rm(cancel_marker(data.get("session_id")))  # a new instruction supersedes «Отменить»
    update_session(data, "working", data.get("prompt"))
    if FLAG.exists():
        print(VOICE_CONTEXT)


# ---------- hook ----------

PIPER = SCRIPT.parent / ".venv" / "bin" / "piper"
VOICES_DIR = STATE_DIR / "voices"


def speech_text(text):
    """Characters TTS reads out loud: Milena says «backslash» for «ёлочки»."""
    return re.sub(r"[«»“”„‟\"]", "", text)


# Voices worth hearing when the configured one doesn't speak the summary's language.
GOOD_VOICES = {
    "ru": ["Milena"], "en": ["Samantha", "Ava", "Zoe", "Daniel", "Karen", "Moira", "Tessa"],
    "uk": ["Lesya"], "de": ["Anna", "Petra"], "fr": ["Thomas", "Amélie", "Audrey"],
    "es": ["Mónica", "Paulina", "Marisol"], "it": ["Alice", "Federica"], "pt": ["Luciana", "Joana"],
    "ja": ["Kyoko", "Otoya"], "zh": ["Tingting", "Lilian"],
}
NOVELTY_VOICES = {"Albert", "Bad News", "Bahh", "Bells", "Boing", "Bubbles", "Cellos", "Good News",
                  "Jester", "Organ", "Superstar", "Trinoids", "Whisper", "Wobble", "Zarvox", "Junior",
                  "Ralph", "Fred", "Kathy", "Eddy", "Flo", "Grandma", "Grandpa", "Reed", "Rocko",
                  "Sandy", "Shelley"}


def text_language(text):
    """Language for the voice: Cyrillic wins if there is any; plain Latin is en."""
    letters = [ch for ch in text.lower() if ch.isalpha()]
    if not letters:
        return None
    n = len(letters)
    if sum("\u3040" <= ch <= "\u30ff" for ch in letters) >= 2:
        return "ja"
    if sum("\u4e00" <= ch <= "\u9fff" for ch in letters) > n * 0.3:
        return "zh"
    # Any Russian word → the Russian voice: an English voice can't read Russian at all, while
    # Milena copes with English terms (and «translate this to English» answers are mixed).
    cyr = sum("а" <= ch <= "я" or ch in "ёіїєґ" for ch in letters)
    if cyr >= 2:
        uk = sum(ch in "іїєґ" for ch in letters)
        ru = sum(ch in "ыэъё" for ch in letters)
        return "uk" if uk > ru else "ru"
    hints = {"de": "äöüß", "es": "ñ¿¡", "pt": "ãõ", "fr": "çèêëœâîôûù", "it": "ìò"}
    counts = {lang: sum(ch in chars for ch in letters) for lang, chars in hints.items()}
    lang, hits = max(counts.items(), key=lambda kv: kv[1])
    return lang if hits >= 2 else "en"


def installed_voices():
    """[(name, language)] from `say -v ?`, cached per process."""
    if not hasattr(installed_voices, "cache"):
        out = subprocess.run(["say", "-v", "?"], capture_output=True, text=True).stdout
        found = []
        for line in out.splitlines():
            m = re.match(r"^(.+?)\s+([a-z]{2,3})_[A-Za-z0-9]+\s+#", line)
            if m:
                found.append((m.group(1).strip(), m.group(2)))
        installed_voices.cache = found
    return installed_voices.cache


def voice_for(text, c):
    """The configured voice if it speaks the summary's language, else the best installed one
    (an English answer is no longer read by Milena with a Russian accent)."""
    voices = installed_voices()
    lang = text_language(text)
    langs = {name: l for name, l in voices}
    main = c["voice"]
    if not lang or not voices or langs.get(main, lang) == lang:
        return main
    override = (c.get("voices") or {}).get(lang)
    if override in langs:
        return override
    mine = [name for name, l in voices if l == lang and name.split(" (")[0] not in NOVELTY_VOICES]
    if not mine:
        return main

    def rank(name):
        base = name.split(" (")[0]
        good = GOOD_VOICES.get(lang, [])
        quality = 0 if "(Premium)" in name else 1 if "(Enhanced)" in name else 2
        return (quality, good.index(base) if base in good else len(good))
    return min(mine, key=rank)


def tts_process(text, c):
    """Start speaking text; returns the playing process."""
    text = speech_text(text)
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
    return subprocess.Popen(["say", "-v", voice_for(text, c), "-r", str(c["rate"]), text])


def speak(text, c):
    """Speak text; the HUD can skip, cancel or silence it.
    Returns None | 'skip' | 'cancel' | 'text' | 'quiet'."""
    sp = tts_process(text, c)
    try:
        while sp.poll() is None:
            cmd, payload = take_control()
            if cmd in ("skip", "cancel", "send", "quiet"):
                return "skip" if cmd == "send" else cmd
            if cmd == "text":
                speak.payload = payload
                return "text"
            time.sleep(0.1)
    finally:
        if sp.poll() is None:
            sp.terminate()
    return None


def spoken_name(title, max_words=6):
    words = title.split()
    return " ".join(words[:max_words]) + ("…" if len(words) > max_words else "")


def converse(project, summary, c, title=None, announce=True, sid=None, cancellable=True, details=""):
    """Speak the summary, then listen for the next instruction.
    Returns the instruction text, or None to let the agent stop."""
    deadline = time.time() + HOOK_TIMEOUT - 25  # leave time for the last transcription
    title = title or project
    session = {"project": title, "summary": summary, "session_id": sid,
               "cancellable": bool(sid) and cancellable, "details": details}

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
    if is_remote():
        # The user carries the iPhone: no Mac voice or Mac mic; the phone reads it out and
        # sends a typed or recorded reply.
        reply = remote_reply(c, ui, deadline)
        if reply != "LISTEN":
            return finish(reply)
    else:
        ui("speaking")
        r = None
    # The chat name only when another session spoke last; no «готово» every time.
    r = None if is_remote() else speak(f"{spoken_name(title)}. {summary}" if announce else summary, c)
    if r == "cancel":
        return finish(None)
    if r == "text":
        return finish(speak.payload)
    if r == "quiet":
        # «Замолчать»: the user reads the summary; no mic until they ask for it.
        verdict, payload = wait_while_reading(ui, deadline)
        if verdict in ("cancel", "timeout"):
            return finish(None)
        if verdict == "text":
            return finish(payload)

    lis = Listener(c, ui)
    try:
        prefix = None
        while True:
            text, typed = listen(lis, c, ui, summary, deadline, prefix)
            if typed or not text or is_stop(text):
                return finish(text)
            verdict, edited = confirm(text, c, ui, deadline)
            if verdict in ("again", "append"):
                prefix = edited if verdict == "append" else None
                lis.drop_backlog()
                continue
            return finish(None if verdict == "cancel" else edited)
    except Exception:
        ui("idle")
        raise
    finally:
        lis.close()


def is_remote():
    """An iPhone is connected (the panel refreshes this flag every few seconds)."""
    try:
        return time.time() - REMOTE.stat().st_mtime < 15
    except OSError:
        return False


def wait_while_reading(ui, deadline, prefix=None, remote=False):
    """Silent step: the user reads (on the Mac after «Stop voice», or on the iPhone).
    Returns (verdict, payload): listen | text | audio (path) | cancel | timeout | local
    (remote=True and the phone went away: hand the turn back to the Mac)."""
    ui("reading", text=prefix or "")
    while time.time() < deadline:
        if remote and not is_remote():
            log("phone went away — back to the Mac")
            return "local", None
        cmd, payload = take_control()
        if cmd:
            log(f"reading: control {cmd!r}")
        if cmd in ("listen", "skip", "send"):
            return "listen", None
        if cmd == "text":
            return "text", " ".join(x for x in (prefix, payload) if x)
        if cmd in ("cancel", "audio"):
            return cmd, payload
        if cmd == "phone":
            ui("phone", text=prefix or "")
        if cmd == "reading":  # the phone recording was cancelled
            ui("reading", text=prefix or "")
        time.sleep(0.1)
    return "timeout", None


def remote_reply(c, ui, deadline):
    """Away from the Mac: wait for a typed or recorded reply from the iPhone.
    Returns text | None (release) | 'LISTEN' (use the Mac mic after all)."""
    prefix = None
    while True:
        verdict, payload = wait_while_reading(ui, deadline, prefix, remote=True)
        if verdict in ("cancel", "timeout"):
            return None
        if verdict in ("text", "listen", "local"):
            return payload if verdict == "text" else "LISTEN"
        ui("transcribing", text=prefix or "")
        wav = to_wav(read_wav(payload))
        heard = transcribe(wav, c)
        _rm(wav)
        log(f"phone phrase: {heard!r}")
        text = " ".join(x for x in (prefix, heard) if x)
        if not heard:
            continue
        if not prefix and is_stop(heard):  # «ок», «спасибо», «стоп»: close right away, as on the Mac
            return None
        v, edited = confirm(text, c, ui, deadline)
        if v == "send":
            return edited
        if v == "cancel":
            return None
        prefix = edited if v == "append" else prefix


def listen(lis, c, ui, summary, deadline, prefix=None):
    """One dictated instruction. Returns (text | None, typed).
    prefix: text already dictated («Дополнить») — new phrases are appended to it."""
    parts, wait, cue = ([prefix] if prefix else []), c["wait_sec"], "Tink"
    while True:
        ui("listening", text=" ".join(parts))
        pcm, how, payload = lis.phrase(wait, cue, deadline)
        if how == "cancel":
            return None, False
        if how == "text":
            return " ".join(parts + [payload]), True
        if how == "repeat":
            ui("speaking")
            speak(summary, c)
            lis.drop_backlog()  # don't transcribe our own voice
            wait, cue = c["wait_sec"], "Tink"
            continue
        if pcm is None:  # timeout, or «send» with nothing new
            return " ".join(parts) or None, False
        ui("transcribing", text=" ".join(parts))
        wav = to_wav(pcm)
        text = transcribe(wav, c)
        _rm(wav)
        log(f"phrase: {text!r} ({how})")
        if strip_tail(text, CANCEL_WORDS) is not None:
            return None, False
        if not prefix and not parts and is_repeat(text):
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
    return " ".join(p for p in parts if p).strip() or None, False


def confirm(text, c, ui, deadline):
    """Grace period before sending: the HUD can cancel, re-dictate, edit or send now.
    Returns (verdict, text): send | cancel | again | append."""
    left = c["undo_sec"]
    if left <= 0:
        return "send", text
    held = False
    while held or left > 0:
        ui("confirming", text=text, left=None if held else left)
        cmd, payload = take_control()
        if cmd in ("cancel", "again", "append"):
            return cmd, text
        if cmd == "send":
            return "send", text
        if cmd == "text":
            return "send", payload or text
        if cmd == "hold":  # user is editing the text in the HUD
            held = True
        if time.time() > deadline:
            return "send", text
        time.sleep(0.1)
        left = round(left - 0.1, 1)
    return "send", text


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


def switched_session(session_id):
    """True if a different session spoke last (or it was long ago): then say the chat name."""
    path = STATE_DIR / "last_spoken.json"
    try:
        last = json.loads(path.read_text())
    except Exception:
        last = {}
    path.write_text(json.dumps({"session": session_id, "at": time.time()}))
    return last.get("session") != session_id or time.time() - last.get("at", 0) > 15 * 60


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
    if is_cancelled(data.get("session_id")):
        _rm(cancel_marker(data.get("session_id")))
        update_session(data, "done")
        log(f"stop after cancel: {data.get('session_id')}")
        return
    if not FLAG.exists() or os.environ.get("VOICE_LOOP_OFF"):
        update_session(data, "done")
        return
    c = cfg()
    project = Path(data.get("cwd") or os.getcwd()).name
    if not project_allowed(project, c):
        update_session(data, "done")
        return
    if MUTED.exists():
        update_session(data, "finished")
        return
    log(f"stop: project={project} session={data.get('session_id')} "
        f"entry={os.environ.get('CLAUDE_CODE_ENTRYPOINT')} active={data.get('stop_hook_active')}")
    update_session(data, "waiting")
    lock = acquire_lock(c)
    if not lock:
        log("lock timeout, skipping")
        update_session(data, "done")
        return
    text = last_assistant_text(data)
    if is_duplicate(data.get("session_id"), text):
        log("duplicate stop for the same turn, skipping")
        return
    update_session(data, "waiting")
    try:
        title = session_title(data.get("transcript_path"), project)
        reply = converse(project, summarize(text, c["summary_chars"]), c, title,
                         details=clean_md(text)[:3000],
                         announce=switched_session(data.get("session_id")),
                         sid=data.get("session_id"), cancellable=agent_of(data) != "codex")
    except Exception:
        update_session(data, "done")
        raise
    log(f"heard: {reply!r}")
    update_session(data, "working" if reply else "done")
    if reply:
        # Codex shows the reason as the user's own message, so there it is just the reply (the
        # voice-mode instruction already came with UserPromptSubmit). Claude shows it as hook
        # feedback; a short reminder keeps the «Summary» line coming in long sessions.
        reason = reply if agent_of(data) == "codex" else (
            f"Voice reply (recognized locally, may contain errors): {reply}\n\n"
            f"(hey2agent: keep starting the answer with the «Summary» line.)")
        print(json.dumps({"decision": "block", "reason": reason}, ensure_ascii=False))


# ---------- install ----------

VOICE_CONTEXT = (
    "hey2agent voice mode is on: the summary of your answer will be read aloud. Start every final "
    "answer with a separate line «**Summary:** …» in the language of the conversation, using that "
    "language's word for “Summary” (e.g. «**Кратко:** …» in Russian): 1–2 short conversational "
    "sentences — what was done and whether anything is needed from the user. No paths, code, links "
    "or markdown in that line; write foreign technical terms the way they are pronounced in the "
    "conversation's language. If you are waiting for an answer, ask the question in that same line. "
    "Details below as usual."
)

# event -> (subcommand, timeout)
HOOKS = {"Stop": ("hook", HOOK_TIMEOUT), "UserPromptSubmit": ("prompt", 10),
         "PreToolUse": ("pretool", 5)}


def hook_command(sub):
    return f"{shutil.which('python3') or sys.executable} '{SCRIPT}' {sub}"


def _ours(group):
    return any("voice_loop.py" in h.get("command", "") for h in group.get("hooks", []))


def ensure_model():
    """No model yet: let the user pick one (interactive) or take the default."""
    if find_model():
        return
    choice = MODELS[0][0]
    if sys.stdin.isatty():
        print("Choose a speech recognition model to download:")
        for i, (mid, _, mb, note) in enumerate(MODELS, 1):
            print(f"  {i}. {mid:9} {mb:4} MB  {note}")
        ans = input("Number [1]: ").strip()
        if ans.isdigit() and 1 <= int(ans) <= len(MODELS):
            choice = MODELS[int(ans) - 1][0]
    download_model(choice)


def install():
    (STATE_DIR / "script_path").write_text(f"{shutil.which('python3') or sys.executable}\n{SCRIPT}\n")
    ensure_model()
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


CODEX_CONFIG = HOME / ".codex" / "config.toml"
CODEX_MARK = "# voice-loop (managed by voice_loop.py install-codex)"


def codex_bin():
    return shutil.which("codex") or next((p for p in CODEX_BIN if os.path.exists(p)), None)


def codex_rpc(*requests, wait=4.0):
    """Ask a short-lived `codex app-server` (JSON-RPC over stdio); returns {id: result}."""
    codex = codex_bin()
    if not codex:
        return {}
    msgs = [{"id": 0, "method": "initialize", "params": {"clientInfo": {"name": "hey2agent", "version": "1"}}},
            {"method": "initialized"}]
    msgs += [{"id": i, "method": m, "params": p} for i, (m, p) in enumerate(requests, 1)]
    p = subprocess.Popen([codex, "app-server"], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                         stderr=subprocess.DEVNULL, text=True, cwd=str(HOME))
    p.stdin.write("".join(json.dumps(m) + "\n" for m in msgs))
    p.stdin.flush()
    results, deadline = {}, time.time() + wait
    while time.time() < deadline and len(results) < len(requests) + 1:
        r, _, _ = select.select([p.stdout], [], [], 0.2)
        if r:
            line = p.stdout.readline()
            if not line:
                break
            try:
                m = json.loads(line)
            except ValueError:
                continue
            if "id" in m and "result" in m:
                results[m["id"]] = m["result"]
    p.kill()
    return results


def codex_trust_ours():
    """Codex runs a new hook only once it is trusted (normally via /hooks in the terminal Codex,
    which the Codex app doesn't have). The user asked for the integration, so record trust
    for our own hooks — with the hash Codex itself reports."""
    listing = codex_rpc(("hooks/list", {})).get(1) or {}
    lines = []
    for group in listing.get("data", []):
        for h in group.get("hooks", []):
            if str(SCRIPT) in h.get("command", "") and h.get("source") == "user" and h.get("currentHash"):
                lines.append(f'[hooks.state.{json.dumps(h["key"])}]\nenabled = true\n'
                             f'trusted_hash = {json.dumps(h["currentHash"])}\n')
    if lines:
        text = CODEX_CONFIG.read_text()
        CODEX_CONFIG.write_text(text.replace(f"{CODEX_MARK} end\n", "".join(lines) + f"{CODEX_MARK} end\n"))
    return len(lines)


# Same contract as Claude Code: Stop (decision=block → continue), UserPromptSubmit (context +
# «in progress»), PreToolUse (live activity).
CODEX_HOOKS = {"Stop": ("hook", HOOK_TIMEOUT + 20), "UserPromptSubmit": ("prompt", 10),
               "PreToolUse": ("pretool", 5)}


def install_codex():
    if not CODEX_CONFIG.parent.exists():
        print("Codex not found (~/.codex is missing)")
        return
    backup = CODEX_CONFIG.with_suffix(".toml.voice-loop-backup")
    if CODEX_CONFIG.exists() and not backup.exists():
        shutil.copy(CODEX_CONFIG, backup)
    uninstall_codex(quiet=True)
    text = CODEX_CONFIG.read_text() if CODEX_CONFIG.exists() else ""
    block = f"\n{CODEX_MARK}\n"
    for event, (sub, timeout) in CODEX_HOOKS.items():
        block += (f"[[hooks.{event}]]\n[[hooks.{event}.hooks]]\n"
                  f"type = \"command\"\ncommand = {json.dumps(hook_command(sub))}\n"
                  f"timeout = {timeout}\n" + ('statusMessage = "hey2agent"\n' if event == "Stop" else ""))
    block += f"{CODEX_MARK} end\n"
    CODEX_CONFIG.write_text(text.rstrip("\n") + "\n" + block)
    print(f"installed {', '.join(CODEX_HOOKS)} hooks into {CODEX_CONFIG} (backup: {backup.name})")
    n = codex_trust_ours()
    print(f"marked {n} hooks as trusted in Codex" if n else
          "could not mark the hooks trusted: approve them in the terminal Codex via /hooks")
    print("Restart the Codex app so it reloads its settings.")


def uninstall_codex(quiet=False):
    if not CODEX_CONFIG.exists():
        return
    text = CODEX_CONFIG.read_text()
    text = re.sub(rf"\n?{re.escape(CODEX_MARK)}\n.*?{re.escape(CODEX_MARK)} end\n", "", text,
                  flags=re.S)
    CODEX_CONFIG.write_text(text)
    if not quiet:
        print("uninstalled from Codex")


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
    elif cmd == "prompt":
        try:
            prompt_hook()
        except Exception as e:
            log(f"prompt hook error: {e!r}")
    elif cmd == "on":
        FLAG.touch()
        print("voice-loop ON")
    elif cmd == "off":
        FLAG.unlink(missing_ok=True)
        print("voice-loop OFF")
    elif cmd == "status":
        print(("ON" if FLAG.exists() else "OFF") + (" (muted)" if MUTED.exists() else ""))
    elif cmd == "pretool":
        try:
            pretool_hook()
        except Exception as e:
            log(f"pretool error: {e!r}")
    elif cmd == "cancel" and len(sys.argv) > 2:
        CANCEL_DIR.mkdir(parents=True, exist_ok=True)
        cancel_marker(sys.argv[2]).touch()
    elif cmd == "open" and len(sys.argv) > 2:
        open_chat(sys.argv[2], load_sessions().get(sys.argv[2]))
    elif cmd == "dictate" and len(sys.argv) > 2:
        try:
            dictate_to(sys.argv[2], sys.argv[3] if len(sys.argv) > 3 else None)
        except MicError:
            log("dictate: no mic access for the HUD")
            write_state("error", code="no_mic", text="No microphone access for VoiceLoopHUD")
        except Exception as e:
            log(f"dictate error: {e!r}")
            write_state("error", code="failed", text=str(e))
    elif cmd == "mute":
        MUTED.touch()
        print("muted")
    elif cmd == "unmute":
        MUTED.unlink(missing_ok=True)
        print("unmuted")
    elif cmd == "install":
        install()
    elif cmd == "uninstall":
        uninstall()
    elif cmd == "download-model" and len(sys.argv) > 2:
        download_model(sys.argv[2])
    elif cmd == "models":
        for mid, name, mb, note in MODELS:
            have = (STATE_DIR / "models" / name).exists() or any(p.name == name for p in list_models())
            print(f"{'✓' if have else ' '} {mid:9} {mb:4} MB  {note}")
    elif cmd == "setup":  # plugin installs: hooks come from the plugin, only local setup here
        (STATE_DIR / "script_path").write_text(f"{shutil.which('python3') or sys.executable}\n{SCRIPT}\n")
        print(f"recorded {SCRIPT} for the panel; model: {find_model() or 'none — run download-model'}")
    elif cmd == "install-codex":
        install_codex()
    elif cmd == "uninstall-codex":
        uninstall_codex()
    elif cmd == "say":
        say(" ".join(sys.argv[2:]) or "Проверка голоса", cfg())
    elif cmd == "listen":
        print(repr(converse("тест", "Проверка микрофона.", cfg())))
    else:
        print(__doc__)


if __name__ == "__main__":
    main()
