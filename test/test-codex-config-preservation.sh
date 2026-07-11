#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BASH_BIN="${BASH_BIN:-$(command -v bash)}"
PREPARE="$ROOT/bin/codex-home-prepare.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

FAKE_HOME="$TMP/home"
HARNESS="$TMP/harness"
CODEX_HOME="$HARNESS/.harness/codex"
NO_MARKETPLACE="$TMP/no-marketplace"
CONFIG="$CODEX_HOME/config.toml"
BEFORE="$TMP/config.before.toml"
FIRST="$TMP/config.first.toml"
mkdir -p "$FAKE_HOME" "$CODEX_HOME"
printf '# fixture harness\n' > "$HARNESS/CLAUDE.md"

cat > "$CONFIG" <<'TOML'
model = "arbitrary-user-model"
model_provider = "arbitrary-provider"

[mcp_servers.arbitrary]
command = "/tmp/arbitrary-mcp"

[hooks.state]
# exact hook state root comment

[hooks.state."hooks.json:SessionStart:0:0"]
trusted_hash = "sha256:fixture"
enabled = false # exact hook decision

[[skills.config]]
path = "/tmp/alpha/SKILL.md"
enabled = false # exact alpha override

[[skills.config]]
path = "/tmp/beta/SKILL.md"
enabled = true # exact beta override

[marketplaces.community]
source_type = "git"
source = "https://example.invalid/community.git" # exact custom marketplace

[plugins."custom@community"]
enabled = false # exact custom plugin decision
settings = { channel = "preview" }

[skills.unrelated]
enabled = false

[marketplaces.openai-bundled]
source_type = "git"
source = "https://example.invalid/launcher-override.git"

[plugins."computer-use@openai-bundled"]
enabled = false

[plugins."chrome@openai-bundled"]
enabled = false

[plugins."browser@openai-bundled"]
enabled = true
TOML
cp -p "$CONFIG" "$BEFORE"

HOME="$FAKE_HOME" HARNESS_CODEX_BUNDLED_MARKETPLACE_SOURCE="$NO_MARKETPLACE" \
  "$BASH_BIN" "$PREPARE" "$HARNESS"

python3 - "$BEFORE" "$CONFIG" <<'PY'
import re
import sys

before_path, after_path = sys.argv[1:]
before = open(before_path, encoding="utf-8").read()
after = open(after_path, encoding="utf-8").read()
header = re.compile(r"^\[.*\]\s*$")

def sections(text):
    result = []
    current = []
    for line in text.splitlines(keepends=True):
        if header.match(line.rstrip("\n")):
            if current:
                result.append("".join(current))
            current = [line]
        elif current:
            current.append(line)
    if current:
        result.append("".join(current))
    return result

def allowed(block):
    first = block.splitlines()[0]
    return (
        first == "[hooks.state]"
        or first.startswith("[hooks.state.")
        or first == "[[skills.config]]"
        or first == "[marketplaces.community]"
        or first == '[plugins."custom@community"]'
    )

before_allowed = [block for block in sections(before) if allowed(block)]
after_allowed = [block for block in sections(after) if allowed(block)]
if after_allowed != before_allowed:
    raise SystemExit("FAIL: allowlisted config sections were not preserved byte-for-byte")

checks = {
    "arbitrary model": "arbitrary-user-model",
    "arbitrary provider": "arbitrary-provider",
    "arbitrary MCP": "mcp_servers.arbitrary",
    "unrelated skills table": "skills.unrelated",
    "bundled marketplace override": "launcher-override.git",
    "bundled Browser plugin override": 'plugins."browser@openai-bundled"',
}
for label, needle in checks.items():
    if needle in after:
        raise SystemExit(f"FAIL: {label} survived launcher regeneration")

for table in (
    "[marketplaces.openai-bundled]",
    '[plugins."computer-use@openai-bundled"]',
    '[plugins."chrome@openai-bundled"]',
):
    if after.count(table) != 1:
        raise SystemExit(f"FAIL: launcher-owned table must appear exactly once: {table}")

for plugin in ("computer-use", "chrome"):
    table = f'[plugins."{plugin}@openai-bundled"]'
    block = next(block for block in sections(after) if block.splitlines()[0] == table)
    if "enabled = true" not in block or "enabled = false" in block:
        raise SystemExit(f"FAIL: launcher-owned {plugin} enablement was overridden")
PY

cp -p "$CONFIG" "$FIRST"
HOME="$FAKE_HOME" HARNESS_CODEX_BUNDLED_MARKETPLACE_SOURCE="$NO_MARKETPLACE" \
  "$BASH_BIN" "$PREPARE" "$HARNESS"
cmp -s "$FIRST" "$CONFIG" || {
  echo "FAIL: second prepare changed deterministic preserved config output" >&2
  exit 1
}
echo "PASS: config regeneration preserves only exact allowlisted runtime state"
