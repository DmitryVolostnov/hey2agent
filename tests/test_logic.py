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

    def test_cancel_and_again(self):
        for cmd in ("cancel", "again"):
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
