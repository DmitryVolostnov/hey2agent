"""Slow tests: synthesize phrases with `say`, transcribe with whisper (no mic).
Run: VOICE_LOOP_SLOW=1 python3 -m unittest tests.test_speech"""
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
import voice_loop as v  # noqa: E402

PHRASES = {
    "Хорошо, закоммить изменения": ["закоммит"],
    "Теперь запушь ветку и открой пул-реквест": ["запушь", "пул-реквест"],
    "Сделай тесты, подожди": ["подожди"],
    "Повтори": ["повтори"],
}


@unittest.skipUnless(os.environ.get("VOICE_LOOP_SLOW"), "set VOICE_LOOP_SLOW=1")
class Speech(unittest.TestCase):
    def test_phrases(self):
        c = v.cfg()
        for phrase, must in PHRASES.items():
            with self.subTest(phrase=phrase), tempfile.TemporaryDirectory() as d:
                aiff, wav = f"{d}/p.aiff", f"{d}/p.wav"
                subprocess.run(["say", "-v", c["voice"], "-o", aiff, phrase], check=True)
                subprocess.run(["ffmpeg", "-loglevel", "error", "-y", "-i", aiff,
                                "-ar", "16000", "-ac", "1", wav], check=True)
                text = v.transcribe(wav, c).lower()
                for word in must:
                    self.assertIn(word, text)


if __name__ == "__main__":
    unittest.main()
