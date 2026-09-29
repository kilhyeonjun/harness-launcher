#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# The Orca guide is shipped documentation: it must exist, cover the v0.33.0
# contracts, and be linked from the README.
for term in HARNESS_ORCA_AGENT_HOOKS 'projects/<repo-name>/.worktrees' 'CODEX_HOME sanitization' 'relaunch' '--resume <id>' '/clear'; do
  grep -qF -- "$term" "$ROOT/docs/orca-integration.md" || { echo "FAIL: docs/orca-integration.md must cover: $term" >&2; exit 1; }
done
grep -qF 'docs/orca-integration.md' "$ROOT/README.md" || { echo 'FAIL: README must link docs/orca-integration.md' >&2; exit 1; }
# The terminal runtime guide is shipped documentation: it must exist, cover the
# runtime-parity contracts, and be linked from the README.
for term in 'herdr > orca > cmux > plain' HERDR_ENV HARNESS_TERMINAL_RUNTIME 'OSC 7' HARNESS_HERDR_AGENT_HOOKS HARNESS_ORCA_AGENT_HOOKS harness-session-provider-record provider-sessions PROCESS_LAUNCHED_BY_Q reminder; do
  grep -qF -- "$term" "$ROOT/docs/terminal-runtimes.md" || { echo "FAIL: docs/terminal-runtimes.md must cover: $term" >&2; exit 1; }
done
grep -qF 'docs/terminal-runtimes.md' "$ROOT/README.md" || { echo 'FAIL: README must link docs/terminal-runtimes.md' >&2; exit 1; }
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
