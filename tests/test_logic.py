"""Fast tests: no audio. Run: python3 -m unittest discover tests"""
import json
import os
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
import voice_loop as v  # noqa: E402


class Summary(unittest.TestCase):
    def test_prefers_summary_line(self):
        md = "**Кратко:** Сделал плашку, всё работает.\n\n## Детали\nДлинный текст про реализацию."
        self.assertEqual(v.summarize(md, 220), "Сделал плашку, всё работает.")

    def test_falls_back_to_first_sentences(self):
        md = "## Готово\n\nДобавил hook. Теперь всё звучит.\n\n```bash\necho hi\n```"
        self.assertEqual(v.summarize(md, 220), "Готово. Добавил hook. Теперь всё звучит.")

    def test_appends_trailing_question(self):
        md = "**Кратко:** Сделал этап один.\n\nДетали...\n\nДелаем Codex сейчас или позже?"
        self.assertEqual(v.summarize(md, 220),
                         "Сделал этап один. Вопрос: Делаем Codex сейчас или позже?")

    def test_question_already_in_summary_not_repeated(self):
        md = "**Кратко:** Готово. Ставим Piper?\n\nДетали.\n\nСтавим Piper?"
        self.assertEqual(v.summarize(md, 220), "Готово. Ставим Piper?")

    def test_strips_links_and_code(self):
        md = "Смотри [файл](a/b.py:10) и `код`: https://x.y/z готово."
        self.assertEqual(v.summarize(md, 220), "Смотри файл и код: готово.")


class Speech(unittest.TestCase):
    def test_quotes_removed_for_tts(self):
        self.assertEqual(v.speech_text('нажмите «Разрешить» и “ОК” или "да"'),
                         "нажмите Разрешить и ОК или да")


class Commands(unittest.TestCase):
    def test_send(self):
        self.assertEqual(v.strip_tail("Сделай тесты. Отправить.", v.SEND_WORDS), "Сделай тесты")
        self.assertEqual(v.strip_tail("отправь", v.SEND_WORDS), "")
        self.assertIsNone(v.strip_tail("Запусти билд", v.SEND_WORDS))

    def test_hold_only_at_end(self):
        self.assertEqual(v.strip_tail("Сделай тесты, подожди", v.HOLD_WORDS), "Сделай тесты")
        self.assertIsNone(v.strip_tail("Надо подумать над этапами, что дальше", v.HOLD_WORDS))

    def test_repeat_and_cancel(self):
        self.assertTrue(v.is_repeat("Повтори, пожалуйста."))
        self.assertFalse(v.is_repeat("Повтори тесты для пайплайна"))
        self.assertEqual(v.strip_tail("Отмена", v.CANCEL_WORDS), "")

    def test_stop_words(self):
        self.assertTrue(v.is_stop("Стоп."))
        self.assertTrue(v.is_stop(""))
        self.assertFalse(v.is_stop("Стоп, сначала поправь тесты"))


class Transcript(unittest.TestCase):
    def test_last_assistant_text(self):
        lines = [
            {"type": "user", "message": {"content": "сделай"}},
            {"type": "assistant", "message": {"content": [{"type": "text", "text": "Первый"}]}},
            {"type": "assistant", "message": {"content": [{"type": "tool_use", "name": "Bash"}]}},
            {"type": "assistant", "message": {"content": [{"type": "text", "text": "Итог"}]}},
        ]
        with tempfile.NamedTemporaryFile("w", suffix=".jsonl", delete=False) as f:
            f.write("\n".join(json.dumps(l, ensure_ascii=False) for l in lines))
        try:
            self.assertEqual(v.last_assistant_text({"transcript_path": f.name}), "Итог")
        finally:
            os.remove(f.name)

    def test_hook_field_wins(self):
        self.assertEqual(v.last_assistant_text({"last_assistant_message": "X"}), "X")


class Gates(unittest.TestCase):
    def test_projects(self):
        self.assertTrue(v.project_allowed("any", {"projects": []}))
        self.assertTrue(v.project_allowed("stark treck", {"projects": ["stark treck"]}))
        self.assertFalse(v.project_allowed("rafeeq code", {"projects": ["stark treck"]}))

    def test_duplicate(self):
        with tempfile.TemporaryDirectory() as d:
            v.LAST = Path(d) / "last.json"
            self.assertFalse(v.is_duplicate("s1", "ответ"))
            self.assertTrue(v.is_duplicate("s1", "ответ"))
            self.assertFalse(v.is_duplicate("s1", "другой ответ"))


if __name__ == "__main__":
    unittest.main()


class Confirm(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.TemporaryDirectory()
        v.CONTROL = Path(self.dir.name) / "control"
        self.c = {"undo_sec": 0.3}
        self.ui = lambda *a, **k: None
        self.far = __import__("time").time() + 60

    def tearDown(self):
        self.dir.cleanup()

    def test_sends_after_grace(self):
        self.assertEqual(v.confirm("текст", self.c, self.ui, self.far), ("send", "текст"))

    def test_disabled(self):
        self.assertEqual(v.confirm("текст", {"undo_sec": 0}, self.ui, self.far), ("send", "текст"))

    def test_cancel_again_append(self):
        for cmd in ("cancel", "again", "append"):
            v.CONTROL.write_text(cmd)
            self.assertEqual(v.confirm("текст", self.c, self.ui, self.far)[0], cmd)

    def test_edit_holds_then_sends_edited(self):
        import threading
        import time
        v.CONTROL.write_text("hold")

        def later():
            time.sleep(0.6)  # longer than undo_sec: must not have auto-sent
            v.CONTROL.write_text("text\nисправленный текст")

        threading.Thread(target=later).start()
        self.assertEqual(v.confirm("текст", self.c, self.ui, self.far), ("send", "исправленный текст"))


class Mute(unittest.TestCase):
    def test_muted_hook_marks_finished_without_speaking(self):
        import io
        with tempfile.TemporaryDirectory() as d:
            d = Path(d)
            saved = (v.STATE_DIR, v.FLAG, v.MUTED, v.SESSIONS)
            v.STATE_DIR, v.FLAG, v.MUTED, v.SESSIONS = d, d / "enabled", d / "muted", d / "sessions.json"
            try:
                v.FLAG.touch()
                v.MUTED.touch()
                sys.stdin = io.StringIO(json.dumps({"session_id": "s1", "cwd": "/tmp/proj"}))
                v.hook()
                reg = json.loads(v.SESSIONS.read_text())
                self.assertEqual(reg["s1"]["status"], "finished")
            finally:
                v.STATE_DIR, v.FLAG, v.MUTED, v.SESSIONS = saved
                sys.stdin = sys.__stdin__


class Deliver(unittest.TestCase):
    def run_with(self, entry, which=None):
        from unittest import mock
        calls = []

        def fake_run(cmd, **kw):
            calls.append(cmd)
            return mock.Mock(returncode=0, stderr="")

        with mock.patch.object(v.subprocess, "run", fake_run), \
             mock.patch.object(v.subprocess, "Popen", lambda cmd, **kw: calls.append(cmd)), \
             mock.patch.object(v.shutil, "which", lambda name: which and f"/bin/{name}"), \
             mock.patch.object(v.os.path, "exists", lambda p: True):
            how = v.deliver("sid-1", entry, "сделай тесты")
        return how, calls

    def test_codex_queue(self):
        how, calls = self.run_with({"agent": "codex"}, which=True)
        self.assertEqual(how, "queued")
        self.assertEqual(calls[0][1:], ["queue", "--thread", "sid-1", "--message", "сделай тесты"])

    def test_claude_cli_resumes(self):
        how, calls = self.run_with({"agent": "claude-cli", "cwd": "/tmp"}, which=True)
        self.assertEqual(how, "resumed")
        self.assertEqual(calls[0], ["claude", "-p", "--resume", "sid-1", "сделай тесты"])

    def test_claude_app_uses_clipboard_and_opens_the_chat(self):
        from unittest import mock
        with mock.patch.object(v, "desktop_session_id", lambda sid: "local_abc"):
            how, calls = self.run_with({"agent": "claude-desktop"})
        self.assertEqual(how, "clipboard")
        self.assertEqual(calls, [["pbcopy"], ["open", "claude://code/continue?session=local_abc"]])

    def test_desktop_session_lookup(self):
        with tempfile.TemporaryDirectory() as d:
            saved = v.CLAUDE_APP_SESSIONS
            v.CLAUDE_APP_SESSIONS = Path(d)
            try:
                f = Path(d) / "a" / "b" / "local_xyz.json"
                f.parent.mkdir(parents=True)
                f.write_text(json.dumps({"sessionId": "local_xyz", "cliSessionId": "cli-1"}))
                self.assertEqual(v.desktop_session_id("cli-1"), "local_xyz")
                self.assertIsNone(v.desktop_session_id("cli-2"))
            finally:
                v.CLAUDE_APP_SESSIONS = saved


class CancelAfterSend(unittest.TestCase):
    def setUp(self):
        import io
        self.io = io
        self.dir = tempfile.TemporaryDirectory()
        d = Path(self.dir.name)
        self.saved = (v.STATE_DIR, v.CANCEL_DIR, v.SESSIONS, v.FLAG)
        v.STATE_DIR, v.CANCEL_DIR, v.SESSIONS, v.FLAG = d, d / "cancel", d / "sessions.json", d / "on"
        v.CANCEL_DIR.mkdir()

    def tearDown(self):
        v.STATE_DIR, v.CANCEL_DIR, v.SESSIONS, v.FLAG = self.saved
        sys.stdin = sys.__stdin__
        self.dir.cleanup()

    def call(self, fn, payload):
        from contextlib import redirect_stdout
        sys.stdin = self.io.StringIO(json.dumps(payload))
        out = self.io.StringIO()
        with redirect_stdout(out):
            fn()
        return out.getvalue()

    def test_deny_only_after_cancel(self):
        self.assertEqual(self.call(v.pretool_hook, {"session_id": "s1"}), "")
        v.cancel_marker("s1").touch()
        out = json.loads(self.call(v.pretool_hook, {"session_id": "s1"}))
        self.assertEqual(out["hookSpecificOutput"]["permissionDecision"], "deny")
        self.assertEqual(self.call(v.pretool_hook, {"session_id": "other"}), "")

    def test_stop_after_cancel_is_silent_and_clears(self):
        v.FLAG.touch()
        v.cancel_marker("s1").touch()
        self.assertEqual(self.call(v.hook, {"session_id": "s1", "cwd": "/tmp/p"}), "")
        self.assertFalse(v.cancel_marker("s1").exists())

    def test_new_prompt_clears_cancel(self):
        v.cancel_marker("s1").touch()
        self.call(v.prompt_hook, {"session_id": "s1", "cwd": "/tmp/p", "prompt": "новое"})
        self.assertFalse(v.is_cancelled("s1"))
