#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
python3 - "$ROOT" <<'PY'
from pathlib import Path
import re
import sys
from urllib.parse import unquote

root = Path(sys.argv[1]).resolve()
files = [
    root / "README.md",
    root / "CONTRIBUTING.md",
    root / "SECURITY.md",
    root / "CHANGELOG.md",
    *sorted((root / "docs").glob("*.md")),
    *sorted((root / ".github").glob("*.md")),
]
pattern = re.compile(r"!?\[[^\]]*\]\(([^)]+)\)")
errors = []
checked = 0

for document in files:
    if not document.is_file():
        continue
    text = document.read_text(encoding="utf-8")
    for raw_target in pattern.findall(text):
        target = raw_target.strip().split(maxsplit=1)[0].strip("<>")
        if not target or target.startswith(("http://", "https://", "mailto:", "#")):
            continue
        relative = unquote(target.split("#", 1)[0])
        if not relative:
            continue
        checked += 1
        resolved = (document.parent / relative).resolve()
        try:
            resolved.relative_to(root)
        except ValueError:
            errors.append(f"{document.relative_to(root)}: link escapes repository: {target}")
            continue
        if not resolved.exists():
            errors.append(f"{document.relative_to(root)}: missing link target: {target}")

if errors:
    print("Markdown link check failed:", file=sys.stderr)
    for error in errors:
        print(f"- {error}", file=sys.stderr)
    raise SystemExit(1)

print(f"PASS: {checked} relative Markdown links resolve")
PY
