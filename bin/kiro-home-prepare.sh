#!/usr/bin/env bash
# kiro-home-prepare.sh — populate $HARNESS_DIR/.harness/kiro/ for Kiro CLI native launch.
#
# Usage: kiro-home-prepare.sh <harness-dir>
#
# Idempotent: re-runs only rewrite files when content would change.

set -euo pipefail

HARNESS_DIR="${1:?HARNESS_DIR required (positional arg 1)}"
[[ -d "$HARNESS_DIR" ]] || { echo "harness dir not found: $HARNESS_DIR" >&2; exit 1; }

KIRO_HOME="$HARNESS_DIR/.harness/kiro"
# Parse and render MCP configuration outside the harness first. A validation
# failure must not create `.harness/kiro` or leave temporary runtime files.
STAGING_DIR="$(mktemp -d "${TMPDIR:-/tmp}/harness-launcher-kiro.XXXXXX")"
cleanup_staging() {
  rm -rf "$STAGING_DIR"
}
trap cleanup_staging EXIT

LAUNCHER_BIN_DIR="$(cd "$(dirname "$0")" && pwd)"

# Atomic swap helper: only overwrite if content differs
atomic_write() {
  local dest="$1" tmp_file="$2"
  if [[ -f "$dest" ]] && cmp -s "$tmp_file" "$dest"; then
    rm -f "$tmp_file"
  else
    mv "$tmp_file" "$dest"
  fi
}

# ─── 1. settings/mcp.json ───────────────────────────────────────────────────
# Merge committed and local MCP sources into kiro-cli format. Local files extend
# the committed configuration; duplicate server names fail rather than override.

mcp_out="$KIRO_HOME/settings/mcp.json"
tmp_mcp="$STAGING_DIR/mcp.json"

python3 - "$HARNESS_DIR" > "$tmp_mcp" <<'PY'
import json, os, sys

harness = sys.argv[1]
merged = {}
seen = {}

for name in (".mcp.json", ".mcp.local.json", "mcp.local.json"):
    path = os.path.join(harness, name)
    if not os.path.isfile(path):
        continue
    with open(path, encoding="utf-8") as f:
        data = json.load(f)
    for srv_name, spec in (data.get("mcpServers") or {}).items():
        if srv_name in seen:
            print(
                f"ERROR: duplicate MCP server '{srv_name}' in {seen[srv_name]} and {path}; "
                "rename the local server instead of overriding committed .mcp.json",
                file=sys.stderr,
            )
            raise SystemExit(1)
        seen[srv_name] = path
        merged[srv_name] = spec

# Convert to kiro-cli format: ensure "type" field
output = {}
for name, spec in sorted(merged.items()):
    entry = dict(spec)
    if "type" not in entry:
        if "url" in entry:
            entry["type"] = "http"
        elif "command" in entry:
            entry["type"] = "stdio"
    output[name] = entry

json.dump({"mcpServers": output}, sys.stdout, indent=2)
sys.stdout.write("\n")
PY

# MCP parsing and duplicate validation succeeded. It is now safe to materialize
# the per-harness runtime home and atomically install generated files.
mkdir -p "$KIRO_HOME/settings" "$KIRO_HOME/agents" "$KIRO_HOME/steering" "$KIRO_HOME/skills"
atomic_write "$mcp_out" "$tmp_mcp"

# ─── 2. settings/cli.json ───────────────────────────────────────────────────
# Generate only after MCP validation succeeds, so a rejected local duplicate
# leaves every pre-existing generated file untouched.

cli_json="$KIRO_HOME/settings/cli.json"
tmp_cli="$(mktemp "$KIRO_HOME/.cli.json.XXXXXX")"
cat > "$tmp_cli" <<'JSON'
{
  "chat.enableThinking": true,
  "chat.enableTodoList": true,
  "chat.enableContextUsageIndicator": true,
  "chat.enableDelegate": true,
  "chat.enableKnowledge": true
}
JSON
atomic_write "$cli_json" "$tmp_cli"

# ─── 3. agents/harness.json ──────────────────────────────────────────────────
# Per-harness agent with hooks, resources, allowedTools

agents_out="$KIRO_HOME/agents/harness.json"
tmp_agents="$(mktemp "$KIRO_HOME/.harness.json.XXXXXX")"
hooks_dir="$HARNESS_DIR/core/hooks"

python3 - "$HARNESS_DIR" "$hooks_dir" "$mcp_out" > "$tmp_agents" <<'PY'
import json, os, sys

harness = sys.argv[1]
hooks_dir = sys.argv[2]
mcp_out = sys.argv[3]

def has_hook(name):
    return os.path.isfile(os.path.join(hooks_dir, name))

# Inline the merged MCP servers (from section 2) so the agent sees them.
# useLegacyMcpJson stays False: legacy mode would also merge default/global
# mcp.json, leaking servers across scopes. Inline keeps this agent hermetic.
mcp_servers = {}
if os.path.isfile(mcp_out):
    with open(mcp_out) as f:
        mcp_servers = json.load(f).get("mcpServers") or {}

# Build hooks — only 2 events supported by kiro-cli
hooks = {"agentSpawn": [], "userPromptSubmit": []}

if has_hook("session-start.sh"):
    hooks["agentSpawn"].append({"command": f'bash "{hooks_dir}/session-start.sh"'})

prompt_hooks = []
if has_hook("prompt-keyword-routing.sh"):
    prompt_hooks.append({"command": f'bash "{hooks_dir}/prompt-keyword-routing.sh"'})
if has_hook("user-prompt-session-end-detect.sh"):
    prompt_hooks.append({"command": f'bash "{hooks_dir}/user-prompt-session-end-detect.sh"'})
hooks["userPromptSubmit"] = prompt_hooks

# Resources: load CLAUDE.md + steering + rules
resources = [
    "file://CLAUDE.md",
    "file://.claude/rules/**/*.md",
    "file://.kiro/steering/**/*.md",
]

# AllowedTools: read-only tools auto-approved
allowed_tools = ["fs_read", "web_search"]

agent = {
    "name": "harness",
    "description": f"Harness-managed Kiro CLI agent for {os.path.basename(harness)}",
    "prompt": None,
    "mcpServers": mcp_servers,
    "tools": ["*"],
    "toolAliases": {},
    "allowedTools": allowed_tools,
    "resources": resources,
    "hooks": hooks,
    "toolsSettings": {},
    "useLegacyMcpJson": False,
}

json.dump(agent, sys.stdout, indent=2)
sys.stdout.write("\n")
PY

atomic_write "$agents_out" "$tmp_agents"

# ─── 4. steering/AGENTS.md ───────────────────────────────────────────────────
# Compiler-first (same as codex), fallback to rules concatenation, then CLAUDE.md

steering_md="$KIRO_HOME/steering/AGENTS.md"
compiler="$HARNESS_DIR/core/scripts/harness_compile.py"
compiled=0

if [[ -f "$compiler" && -f "$HARNESS_DIR/.claude/source/runtime-contract.yaml" ]]; then
  tmp_steering="$(mktemp "$KIRO_HOME/.AGENTS.md.XXXXXX")"
  if python3 "$compiler" --write-codex "$HARNESS_DIR" >/dev/null 2>&1; then
    # Compiler writes to .harness/codex/AGENTS.md — copy content for kiro
    codex_agents="$HARNESS_DIR/.harness/codex/AGENTS.md"
    if [[ -f "$codex_agents" ]]; then
      cp "$codex_agents" "$tmp_steering"
      atomic_write "$steering_md" "$tmp_steering"
      compiled=1
    else
      rm -f "$tmp_steering"
    fi
  else
    rm -f "$tmp_steering"
  fi
fi

if [[ "$compiled" -eq 0 ]]; then
  rules_dir="$HARNESS_DIR/.claude/rules"
  rule_files=()
  if [[ -d "$rules_dir" ]]; then
    for f in "$rules_dir"/*.md; do
      [[ -e "$f" ]] || continue
      [[ "$(basename "$f")" == "_index.md" ]] && continue
      rule_files+=("$f")
    done
  fi

  if [[ ${#rule_files[@]} -gt 0 ]]; then
    tmp_steering="$(mktemp "$KIRO_HOME/.AGENTS.md.XXXXXX")"
    {
      echo "# Generated by kiro-home-prepare.sh — do not edit manually."
      echo "# Source-of-truth: $HARNESS_DIR/.claude/rules/*.md"
      echo
      for f in "${rule_files[@]}"; do
        echo "## $(basename "$f" .md)"
        echo
        cat "$f"
        echo
      done
    } > "$tmp_steering"
    atomic_write "$steering_md" "$tmp_steering"
  elif [[ -f "$HARNESS_DIR/CLAUDE.md" ]]; then
    ln -sfn "../../CLAUDE.md" "$steering_md"
  fi
fi

# ─── 5. Skills merge ─────────────────────────────────────────────────────────
# Symlink merge: global kiro skills + harness .claude/skills → $KIRO_HOME/skills/
# Kiro CLI reads skills from $KIRO_HOME/skills/ (same format as Claude skills)

SKILLS_DIR="$KIRO_HOME/skills"
MARKER="$SKILLS_DIR/.harness-managed"

# Clean previous managed entries
if [[ -f "$MARKER" ]]; then
  while IFS= read -r entry; do
    [[ -z "$entry" ]] && continue
    [[ -L "$SKILLS_DIR/$entry" ]] && rm "$SKILLS_DIR/$entry"
  done < "$MARKER"
fi
: > "$MARKER"

link_skill_dir() {
  local src_root="$1"
  [[ -d "$src_root" ]] || return 0
  local src name
  for src in "$src_root"/*/; do
    [[ -d "$src" ]] || continue
    [[ -f "$src/SKILL.md" ]] || continue
    name="$(basename "$src")"
    ln -sfn "${src%/}" "$SKILLS_DIR/$name"
    echo "$name" >> "$MARKER"
  done
}

# Global kiro skills (user-scope)
link_skill_dir "$HOME/.kiro/skills"
# Harness-local Claude skills (portable format)
link_skill_dir "$HARNESS_DIR/.claude/skills"
# User-scope Claude skills (if any)
link_skill_dir "$HOME/.claude/skills"
