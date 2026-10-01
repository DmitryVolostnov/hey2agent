"""Collect String(localized: "...") keys from Swift sources, converting interpolations to
format specifiers the way Swift does (%lld for integers, %@ for strings)."""
import json, re
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SOURCES = list((ROOT / "HUD/Sources").rglob("*.swift")) + list((ROOT / "iOS/Sources").rglob("*.swift"))
STRINGISH = ("String(", '?? ""', "project", "text", "base", ".title")

def literal_at(s, i):
    """Swift string literal starting at s[i] == '"' (handles \\( ... ) with nested quotes)."""
    j, out, parts = i + 1, "", []
    while True:
        c = s[j]
        if c == "\\" and s[j + 1] == "(":
            depth, k = 1, j + 2
            while depth:
                if s[k] == "(": depth += 1
                elif s[k] == ")": depth -= 1
                elif s[k] == '"':
                    k = s.index('"', k + 1)
                k += 1
            expr = s[j + 2:k - 1]
            out += "%@" if any(t in expr for t in STRINGISH) else "%lld"
            j = k
        elif c == "\\":
            out += s[j:j + 2]; j += 2
        elif c == '"':
            return out
        else:
            out += c; j += 1

keys = []
for f in SOURCES:
    s = f.read_text()
    for m in re.finditer(r'String\(localized: "', s):
        k = literal_at(s, m.end() - 1)
        if k not in keys:
            keys.append(k)
(ROOT / "Localization/keys.json").write_text(json.dumps(keys, ensure_ascii=False, indent=1))
print(len(keys), "keys")
