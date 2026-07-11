#!/usr/bin/env bash
# codex-home-prepare.sh — populate $HARNESS_DIR/.harness/codex/ for Codex CLI native launch.
#
# Usage: codex-home-prepare.sh <harness-dir>
#
# Idempotent: re-runs only rewrite config.toml when content would change, so
# launchers can call this on every invocation without touching mtimes unnecessarily.

set -euo pipefail

HARNESS_DIR="${1:?HARNESS_DIR required (positional arg 1)}"
[[ -d "$HARNESS_DIR" ]] || { echo "harness dir not found: $HARNESS_DIR" >&2; exit 1; }

CODEX_HOME="$HARNESS_DIR/.harness/codex"
PROJECT_CODEX_DIR="$HARNESS_DIR/.codex"

# Serialize the complete mutation of one generated Codex home. The lock file
# itself requires the generated directory to exist, but no launcher-managed
# surface is changed until the kernel advisory lock has been acquired. Keeping
# the descriptor open in this shell makes process exit and signals release the
# lock without PID files, stale-owner heuristics, or cleanup traps.
acquire_codex_home_lock() {
  local lock_file="$CODEX_HOME/.codex-home-prepare.lock"
  [[ -x /usr/bin/lockf ]] || {
    echo "ERROR: /usr/bin/lockf is required for safe Codex home preparation" >&2
    return 1
  }
  mkdir -p "$CODEX_HOME"
  exec 8>"$lock_file"
  if ! /usr/bin/lockf -s -t 20 8; then
    echo "ERROR: timed out waiting for Codex home preparation lock: $lock_file" >&2
    return 1
  fi
}

quarantine_project_codex_dir() {
  [[ -e "$PROJECT_CODEX_DIR" || -L "$PROJECT_CODEX_DIR" ]] || return 0

  local stamp backup i
  stamp="$(date +%Y%m%d%H%M%S 2>/dev/null || printf 'unknown')"
  backup="$HARNESS_DIR/.codex.legacy-$stamp-$$"
  i=0
  while [[ -e "$backup" || -L "$backup" ]]; do
    i=$((i + 1))
    backup="$HARNESS_DIR/.codex.legacy-$stamp-$$-$i"
  done

  mv "$PROJECT_CODEX_DIR" "$backup"
  echo "WARN: quarantined legacy project .codex to $backup" >&2
}

acquire_codex_home_lock
quarantine_project_codex_dir
CODEX_BUNDLED_MARKETPLACE_SOURCE="${HARNESS_CODEX_BUNDLED_MARKETPLACE_SOURCE:-/Applications/Codex.app/Contents/Resources/plugins/openai-bundled}"

# A portable surface manifest makes runtime membership explicit. Resolve host
# tokens locally and use a source-content fingerprint to avoid recompiling or
# rescanning an already-converged generated home. Auth/session/hook runtime
# state is intentionally excluded; the auth link itself is repaired cheaply on
# the warm path.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SURFACE_RESOLVER="$SCRIPT_DIR/codex-surface.py"
SURFACE_MANIFEST="$HARNESS_DIR/config/codex-surface.json"
SURFACE_STAMP="$CODEX_HOME/.surface-success.json"
SURFACE_ENABLED=0
SURFACE_FINGERPRINT_JSON=""
SURFACE_SKILL_PROFILE="${HARNESS_CODEX_SKILL_PROFILE:-default}"
SURFACE_MCP_PROFILE="${HARNESS_CODEX_MCP_PROFILE:-}"

if [[ -f "$SURFACE_MANIFEST" ]]; then
  [[ -x "$SURFACE_RESOLVER" ]] || {
    echo "ERROR: Codex surface manifest requires executable resolver: $SURFACE_RESOLVER" >&2
    exit 1
  }
  SURFACE_ENABLED=1
  fingerprint_args=(
    warm-probe
    --manifest "$SURFACE_MANIFEST"
    --repo-root "$HARNESS_DIR"
    --codex-home "$CODEX_HOME"
    --home "$HOME"
    --skill-profile "$SURFACE_SKILL_PROFILE"
    --launcher-file "$SURFACE_RESOLVER"
    --launcher-file "$0"
    --launcher-file "$SCRIPT_DIR/codex-hook-adapter.sh"
    --bundled-marketplace "$CODEX_BUNDLED_MARKETPLACE_SOURCE"
    --stamp "$SURFACE_STAMP"
  )
  [[ -z "$SURFACE_MCP_PROFILE" ]] || fingerprint_args+=(--mcp-profile "$SURFACE_MCP_PROFILE")
  if SURFACE_FINGERPRINT_JSON="$(python3 "$SURFACE_RESOLVER" "${fingerprint_args[@]}")"; then
    if [[ -f "$HOME/.codex/auth.json" ]]; then
      ln -sfn "$HOME/.codex/auth.json" "$CODEX_HOME/auth.json"
    fi
    exit 0
  else
    surface_probe_status=$?
    if [[ "$surface_probe_status" -ne 3 ]]; then
      exit "$surface_probe_status"
    fi
  fi
  # A rebuild starts by invalidating the previous success record. A signal,
  # compiler error, or resolver failure can therefore never leave a stale warm
  # stamp behind.
  rm -f "$SURFACE_STAMP"
fi

warn_claude_global_mcp_drift() {
  [[ "${HARNESS_CODEX_WARN_CLAUDE_GLOBAL_MCP_DRIFT:-0}" == "1" ]] || return 0

  local claude_json="$HOME/.claude.json"
  local harness_mcp_files=()
  [[ -f "$HARNESS_DIR/.mcp.json" ]] && harness_mcp_files+=("$HARNESS_DIR/.mcp.json")
  [[ -f "$HARNESS_DIR/.mcp.local.json" ]] && harness_mcp_files+=("$HARNESS_DIR/.mcp.local.json")
  [[ -f "$HARNESS_DIR/mcp.local.json" ]] && harness_mcp_files+=("$HARNESS_DIR/mcp.local.json")
  [[ -f "$claude_json" && ${#harness_mcp_files[@]} -gt 0 ]] || return 0

  python3 - "$claude_json" "${harness_mcp_files[@]}" <<'PY'
import json
import sys

claude_path, harness_paths = sys.argv[1], sys.argv[2:]

try:
    with open(claude_path, encoding="utf-8") as f:
        claude = json.load(f)
except Exception:
    sys.exit(0)

global_servers = set((claude.get("mcpServers") or {}).keys())
harness_servers = set()
for harness_path in harness_paths:
    try:
        with open(harness_path, encoding="utf-8") as f:
            harness_servers.update((json.load(f).get("mcpServers") or {}).keys())
    except Exception:
        pass

for name in sorted(global_servers - harness_servers):
    print(f"WARN: Claude global MCP server not declared in harness .mcp.json: {name}", file=sys.stderr)
PY
}

warn_claude_global_mcp_drift

# 1. AGENTS.md: compiler-first when canonical .claude/source exists. The
# compiler emits Codex-native XML runtime contracts plus non-runtime rules. For
# older harnesses, keep the legacy rules concatenation fallback. Without rules,
# start from CLAUDE.md content. A Codex-only supplement below materializes the
# final file so Claude source surfaces stay untouched.
agents_md="$CODEX_HOME/AGENTS.md"
prev_agents_snapshot=""
if [[ -e "$agents_md" || -L "$agents_md" ]]; then
  prev_agents_snapshot="$(mktemp "$CODEX_HOME/.AGENTS.prev.XXXXXX")"
  if cat "$agents_md" > "$prev_agents_snapshot"; then
    touch -r "$agents_md" "$prev_agents_snapshot" 2>/dev/null || true
  else
    rm -f "$prev_agents_snapshot"
    prev_agents_snapshot=""
  fi
fi
compiler="$HARNESS_DIR/core/scripts/harness_compile.py"
compiled_agents=0
if [[ -f "$compiler" && -f "$HARNESS_DIR/.claude/source/runtime-contract.yaml" ]]; then
  if python3 "$compiler" --write-codex "$HARNESS_DIR" >/dev/null; then
    compiled_agents=1
  else
    echo "WARN: harness compiler failed for Codex AGENTS.md; falling back to rule concatenation" >&2
  fi
fi

if [[ "$compiled_agents" -eq 0 ]]; then
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
    tmp_agents="$(mktemp "$CODEX_HOME/.AGENTS.md.XXXXXX")"
    {
      echo "# Generated by codex-home-prepare.sh — do not edit manually."
      echo "# Source-of-truth: $HARNESS_DIR/.claude/rules/*.md"
      echo
      for f in "${rule_files[@]}"; do
        echo "## $(basename "$f" .md)"
        echo
        cat "$f"
        echo
      done
    } > "$tmp_agents"
    if [[ -e "$agents_md" ]] && [[ ! -L "$agents_md" ]] && cmp -s "$tmp_agents" "$agents_md"; then
      rm -f "$tmp_agents"
    else
      rm -f "$agents_md"
      mv "$tmp_agents" "$agents_md"
    fi
  elif [[ -f "$HARNESS_DIR/CLAUDE.md" ]]; then
    ln -sfn "../../CLAUDE.md" "$agents_md"
  fi
fi

append_codex_response_language_supplement() {
  [[ -e "$agents_md" || -L "$agents_md" ]] || return 0

  local tmp_agents tmp_stripped
  tmp_agents="$(mktemp "$CODEX_HOME/.AGENTS.md.XXXXXX")"
  tmp_stripped="$(mktemp "$CODEX_HOME/.AGENTS.md.XXXXXX")"
  cat "$agents_md" > "$tmp_agents"
  awk '
    /<!-- BEGIN HARNESS-CODEX-RESPONSE-LANGUAGE -->/ { skip = 1; next }
    /<!-- END HARNESS-CODEX-RESPONSE-LANGUAGE -->/ { skip = 0; next }
    !skip { print }
  ' "$tmp_agents" > "$tmp_stripped"
  mv "$tmp_stripped" "$tmp_agents"
  cat >> "$tmp_agents" <<'EOF'

<!-- BEGIN HARNESS-CODEX-RESPONSE-LANGUAGE -->
## Codex Response Language

- Default to Korean for conversational responses.
- Keep code, identifiers, commands, paths, logs, errors, and quoted source text in their original language unless the user asks to translate them.
- If the user explicitly asks for another response language, follow that request for the current task.
<!-- END HARNESS-CODEX-RESPONSE-LANGUAGE -->
EOF

  if [[ -e "$agents_md" ]] && [[ ! -L "$agents_md" ]] && cmp -s "$tmp_agents" "$agents_md"; then
    rm -f "$tmp_agents"
  else
    rm -f "$agents_md"
    mv "$tmp_agents" "$agents_md"
  fi
}

# Codex has no Claude-style `language: korean` setting. Add the preference only
# to the generated Codex home so Claude settings and source surfaces stay
# untouched.
append_codex_response_language_supplement

if [[ -n "$prev_agents_snapshot" ]]; then
  if [[ -f "$agents_md" ]] && cmp -s "$prev_agents_snapshot" "$agents_md"; then
    touch -r "$prev_agents_snapshot" "$agents_md" 2>/dev/null || true
  fi
  rm -f "$prev_agents_snapshot"
fi

if [[ -f "$HOME/.codex/auth.json" ]]; then
  ln -sfn "$HOME/.codex/auth.json" "$CODEX_HOME/auth.json"
fi

# Skills: merge global Codex skills (~/.codex/skills), global agent skills
# (~/.agents/skills), and per-harness Claude skills ($HARNESS_DIR/.claude/skills)
# into $CODEX_HOME/skills/. Each entry is a symlink so source-of-truth stays in
# one place. A managed-marker file lets re-runs drop stale entries when sources
# change.
SKILLS_DIR="$CODEX_HOME/skills"
if [[ "$SURFACE_ENABLED" -eq 1 ]]; then
  resolve_args=(
    resolve
    --manifest "$SURFACE_MANIFEST"
    --repo-root "$HARNESS_DIR"
    --codex-home "$CODEX_HOME"
    --home "$HOME"
    --skill-profile "$SURFACE_SKILL_PROFILE"
  )
  [[ -z "$SURFACE_MCP_PROFILE" ]] || resolve_args+=(--mcp-profile "$SURFACE_MCP_PROFILE")
  python3 "$SURFACE_RESOLVER" "${resolve_args[@]}"
else
# Migrate from old single-symlink layout
[[ -L "$SKILLS_DIR" ]] && rm "$SKILLS_DIR"
mkdir -p "$SKILLS_DIR"
MARKER="$SKILLS_DIR/.harness-managed"
if [[ -f "$MARKER" ]]; then
  while IFS= read -r entry; do
    [[ -z "$entry" ]] && continue
    [[ -L "$SKILLS_DIR/$entry" ]] && rm "$SKILLS_DIR/$entry"
  done < "$MARKER"
fi
: > "$MARKER"

managed_names=()

record_managed_skill() {
  local name="$1" existing
  # `${arr[@]:-}` guard: under `set -u`, bash 3.2 (macOS system /bin/bash) errors
  # on a bare "${managed_names[@]}" while the array is still empty (first call).
  for existing in "${managed_names[@]:-}"; do
    [[ "$existing" == "$name" ]] && return 0
  done
  managed_names+=("$name")
  echo "$name" >> "$MARKER"
}

link_skill_dir() {
  local src_root="$1"
  [[ -d "$src_root" ]] || return 0
  local src name
  for src in "$src_root"/*/; do
    [[ -d "$src" ]] || continue
    [[ -f "$src/SKILL.md" ]] || continue
    name="$(basename "$src")"
    ln -sfn "${src%/}" "$SKILLS_DIR/$name"
    record_managed_skill "$name"
  done
  # Preserve Codex system bundle if present (.system/ holds vendor skills)
  if [[ -d "$src_root/.system" ]]; then
    ln -sfn "$src_root/.system" "$SKILLS_DIR/.system"
    record_managed_skill ".system"
  fi
}

link_skill_dir "$HOME/.codex/skills"
link_skill_dir "$HOME/.agents/skills"

# Claude plugins install under ~/.claude/plugins/cache/<marketplace>/<plugin>/<version>/.
# Merge their skills into the Codex home, auto-resolving the newest version each run so
# a plugin update never leaves a dangling version-pinned link. Handles two layouts:
#   1. SKILL.md at the version root      -> link as <plugin-name>
#   2. skills/<name>/SKILL.md under it   -> link each as <skill-name>
link_claude_plugin_skills() {
  local cache_root="$HOME/.claude/plugins/cache"
  [[ -d "$cache_root" ]] || return 0
  local mp plug ver_root newest skill name vdir
  for mp in "$cache_root"/*/; do
    [[ -d "$mp" ]] || continue
    for plug in "$mp"*/; do
      [[ -d "$plug" ]] || continue
      # Pick newest immediate child dir by version sort, excluding 'latest'.
      newest=""
      while IFS= read -r ver_root; do
        [[ -n "$ver_root" ]] && newest="$ver_root"
      done < <(
        for ver_root in "$plug"*/; do
          [[ -d "$ver_root" ]] || continue
          name="$(basename "$ver_root")"
          [[ "$name" == "latest" ]] && continue
          printf '%s\n' "$name"
        done | sort -V
      )
      [[ -n "$newest" ]] || continue
      vdir="${plug}${newest}"
      # Layout 1: single-skill plugin (SKILL.md at version root).
      if [[ -f "$vdir/SKILL.md" ]]; then
        name="$(basename "$plug")"
        ln -sfn "$vdir" "$SKILLS_DIR/$name"
        record_managed_skill "$name"
      fi
      # Layout 2: multi-skill plugin (skills/<name>/SKILL.md).
      if [[ -d "$vdir/skills" ]]; then
        for skill in "$vdir"/skills/*/; do
          [[ -f "$skill/SKILL.md" ]] || continue
          name="$(basename "$skill")"
          ln -sfn "${skill%/}" "$SKILLS_DIR/$name"
          record_managed_skill "$name"
        done
      fi
    done
  done
}

link_claude_plugin_skills

# Superpowers uses Codex's namespace-style skill discovery: the official
# install links ~/.agents/skills/superpowers -> ~/.codex/superpowers/skills.
# Harness Codex homes are generator-owned, so link the clone directly here as
# well and do not depend on a mutable ~/.agents symlink staying present.
if [[ -d "$HOME/.codex/superpowers/skills" ]]; then
  ln -sfn "$HOME/.codex/superpowers/skills" "$SKILLS_DIR/superpowers"
  record_managed_skill "superpowers"
fi

link_skill_dir "$HARNESS_DIR/.claude/skills"

# Per-harness Codex-only skills. These are intentionally separate from
# $HARNESS_DIR/.claude/skills so Codex can receive design/runtime skills
# without exposing them to Claude Code or other harness surfaces.
link_skill_dir "$HARNESS_DIR/.codex-only/skills"
fi

# Commands → Codex skills: portable orchestration commands (those without
# Claude-state coupling) get materialised as explicit-invocation skills so
# Codex sessions can run the same workflows. A separate marker tracks them
# distinctly from the symlink-merged skills above.
CMD_MARKER="$SKILLS_DIR/.harness-managed-cmds"
cmd_src="$HARNESS_DIR/.claude/commands"
prev_cmds=()
if [[ -f "$CMD_MARKER" ]]; then
  while IFS= read -r line; do
    [[ -n "$line" ]] && prev_cmds+=("$line")
  done < "$CMD_MARKER"
fi

new_cmds=()
if [[ -d "$cmd_src" ]]; then
  while IFS= read -r name; do
    [[ -n "$name" ]] && new_cmds+=("$name")
  done < <(python3 - "$cmd_src" "$SKILLS_DIR" <<'PY'
import os, sys, re

src_dir, out_dir = sys.argv[1], sys.argv[2]

# Heuristics: a command is "Claude-coupled" if it references Claude-only
# state, paths, or invokes the Claude Skill tool. These would become dead
# config in Codex, so we skip them.
CLAUDE_COUPLED = re.compile(
    r"\$CLAUDE_PROJECT_DIR|~/\.claude/|/tmp/claude-|\.jsonl|Skill\(skill="
)

def parse_frontmatter(text):
    if not text.startswith("---"):
        return {}, text
    end = text.find("\n---", 3)
    if end < 0:
        return {}, text
    fm = text[3:end].lstrip("\n")
    body = text[end+4:].lstrip("\n")
    meta = {}
    for line in fm.split("\n"):
        if ":" in line:
            k, _, v = line.partition(":")
            meta[k.strip()] = v.strip()
    return meta, body

def command_body_to_skill_body(body):
    return (
        body
        .replace("<command_contract>", "<execution_policy>")
        .replace("</command_contract>", "</execution_policy>")
    )

for path in sorted(os.listdir(src_dir)):
    if not path.endswith(".md") or path == "_index.md":
        continue
    name = path[:-3]
    full = os.path.join(src_dir, path)
    with open(full, "r", encoding="utf-8") as f:
        text = f.read()
    if CLAUDE_COUPLED.search(text):
        continue

    meta, body = parse_frontmatter(text)
    desc = meta.get("description", "").strip().strip('"').strip("'")
    if not desc:
        # Fallback to first non-empty body line
        for line in body.split("\n"):
            if line.strip() and not line.strip().startswith("#"):
                desc = line.strip()
                break
    if not desc:
        desc = f"Codex equivalent of /{name} command (explicit invocation only)."

    skill_dir = os.path.join(out_dir, name)
    os.makedirs(os.path.join(skill_dir, "agents"), exist_ok=True)

    skill_body = command_body_to_skill_body(body)
    skill_md = (
        "---\n"
        f"name: {name}\n"
        f"description: {desc}\n"
        "---\n"
        "\n"
        f"> Generated by codex-home-prepare.sh from .claude/commands/{name}.md.\n"
        "> Source-of-truth: edit the Claude command, not this file.\n"
        "\n"
        f"{skill_body.rstrip()}\n"
    )
    yaml_doc = (
        "# Generated by codex-home-prepare.sh — do not edit manually.\n"
        "policy:\n"
        "  allow_implicit_invocation: false\n"
    )

    skill_path = os.path.join(skill_dir, "SKILL.md")
    yaml_path = os.path.join(skill_dir, "agents", "openai.yaml")
    for target, content in ((skill_path, skill_md), (yaml_path, yaml_doc)):
        if os.path.exists(target):
            with open(target, "r", encoding="utf-8") as f:
                if f.read() == content:
                    continue
        with open(target, "w", encoding="utf-8") as f:
            f.write(content)

    print(name)
PY
)
fi

# Reconcile: any command-skill we previously generated whose source command
# disappeared (or became Claude-coupled) gets removed here.
if [[ ${#prev_cmds[@]} -gt 0 ]]; then
  for prev in "${prev_cmds[@]}"; do
    match=0
    if [[ ${#new_cmds[@]} -gt 0 ]]; then
      for cur in "${new_cmds[@]}"; do
        [[ "$prev" == "$cur" ]] && { match=1; break; }
      done
    fi
    [[ "$match" -eq 0 ]] && rm -rf "$SKILLS_DIR/$prev"
  done
fi

# Persist marker
{
  if [[ ${#new_cmds[@]} -gt 0 ]]; then
    for n in "${new_cmds[@]}"; do echo "$n"; done
  fi
} > "$CMD_MARKER"

# Kernel-backed global mutex for all launcher-managed global Codex cache state.
# macOS lockf holds the advisory lock on fd 9 for the lifetime of the
# subshell. Process exit and signals release it in the kernel; there is no
# PID/mtime stale-reclaim or owner-publication race.
with_global_codex_lock() {
  local lock_file="$HOME/.codex/.codex-home-prepare-global.lock"
  mkdir -p "$HOME/.codex"
  [[ -x /usr/bin/lockf ]] || {
    echo "ERROR: /usr/bin/lockf is required for safe Codex global cache locking" >&2
    return 1
  }
  (
    if ! /usr/bin/lockf -s -t 20 9; then
      echo "ERROR: timed out waiting for Codex global cache lock: $lock_file" >&2
      return 1
    fi
    "$@"
  ) 9>"$lock_file"
}

sync_bundled_marketplace_from_app_bundle() {
  local app_marketplace="$CODEX_BUNDLED_MARKETPLACE_SOURCE"
  local dest="$HOME/.codex/.tmp/bundled-marketplaces/openai-bundled"
  local src_manifest="$app_marketplace/plugins/chrome/.codex-plugin/plugin.json"
  [[ -f "$src_manifest" ]] || return 0
  if [[ -d "$dest" ]] && diff -qr "$app_marketplace" "$dest" >/dev/null 2>&1; then
    return 0
  fi

  mkdir -p "$(dirname "$dest")"
  local tmp_marketplace backup_marketplace
  tmp_marketplace="$(mktemp -d "$HOME/.codex/.tmp/openai-bundled.XXXXXX")"
  cp -pR "$app_marketplace/." "$tmp_marketplace/"
  backup_marketplace="$dest.harness-old.$$"
  rm -rf "$backup_marketplace"
  [[ ! -e "$dest" ]] || mv "$dest" "$backup_marketplace"
  if mv "$tmp_marketplace" "$dest"; then
    rm -rf "$backup_marketplace"
  else
    [[ ! -e "$backup_marketplace" ]] || mv "$backup_marketplace" "$dest"
    return 1
  fi
}

# Browser trust/version must be derived from the marketplace synchronized in
# this same prepare run, never from a missing or stale previous-run cache.
# Global Codex cache is touched only when a valid bundled marketplace is present.
# Avoid taking a host-global lock for harness-only preparation that has no cache
# work to serialize; when cache synchronization is needed it remains fail-closed.
if [[ -f "$CODEX_BUNDLED_MARKETPLACE_SOURCE/plugins/chrome/.codex-plugin/plugin.json" ]]; then
  with_global_codex_lock sync_bundled_marketplace_from_app_bundle
fi

# 2. Generate config.toml content
config_file="$CODEX_HOME/config.toml"
mcp_json_files=()
[[ -f "$HARNESS_DIR/.mcp.json" ]] && mcp_json_files+=("$HARNESS_DIR/.mcp.json")
[[ -f "$HARNESS_DIR/.mcp.local.json" ]] && mcp_json_files+=("$HARNESS_DIR/.mcp.local.json")
[[ -f "$HARNESS_DIR/mcp.local.json" ]] && mcp_json_files+=("$HARNESS_DIR/mcp.local.json")
tmp_config="$(mktemp "$CODEX_HOME/.config.toml.XXXXXX")"
bundled_marketplace="$HOME/.codex/.tmp/bundled-marketplaces/openai-bundled"
browser_client_sha256s="$(
  for client in "$bundled_marketplace/plugins/chrome/scripts/browser-client.mjs"; do
    if [[ -f "$client" ]]; then
      shasum -a 256 "$client" | awk '{print $1}'
    fi
  done | sort -u | paste -sd' ' -
)"
browser_use_app_version="$(
  manifest="$bundled_marketplace/plugins/chrome/.codex-plugin/plugin.json"
  if [[ -f "$manifest" ]]; then
    python3 - "$manifest" <<'PY'
import json
import sys
with open(sys.argv[1], encoding="utf-8") as f:
    print(json.load(f).get("version", ""))
PY
  fi
)"

COMPUTER_USE_PLUGIN_ENABLED=true
CHROME_PLUGIN_ENABLED=true
if [[ "$SURFACE_ENABLED" -eq 1 ]]; then
  COMPUTER_USE_PLUGIN_ENABLED="$(python3 - "$CODEX_HOME/skill-catalog.json" <<'PY'
import json
import sys
with open(sys.argv[1], encoding="utf-8") as f:
    enabled = set((json.load(f).get("mcp") or {}).get("enabled") or [])
print("true" if "computer-use" in enabled else "false")
PY
)"
  # Chrome is not an MCP profile member in schema v1. Surface-managed homes
  # use browser-harness explicitly and keep the terminal plugin disabled.
  CHROME_PLUGIN_ENABLED=false
fi

cat > "$tmp_config" <<TOML
# Generated by codex-home-prepare.sh — do not edit manually.
# Top-level defaults, then per-harness MCP servers. Mode profiles live in
# separate <name>.config.toml files (Codex 0.134.0+ format), generated below.

model = "gpt-5.6-terra"
model_reasoning_effort = "medium"
# Context window/auto-compact intentionally unpinned: Codex resolves them from
# model metadata (372K for GPT-5.6 in Codex CLI as of 2026-07). Pinning
# 1M-style values here made auto-compact fire past the real backend limit.

[features]
# ChatGPT Apps/connectors disabled — harness sessions don't use them and user
# opts deny-by-default globally. Most-comprehensive disable: feature-flag level.
apps = false
goals = true
hooks = true
multi_agent = true

[marketplaces.openai-bundled]
source_type = "local"
source = "$HOME/.codex/.tmp/bundled-marketplaces/openai-bundled"

[plugins."computer-use@openai-bundled"]
enabled = $COMPUTER_USE_PLUGIN_ENABLED

[plugins."chrome@openai-bundled"]
enabled = $CHROME_PLUGIN_ENABLED

[tui]
status_line = ["model-with-reasoning", "current-dir", "git-branch", "run-state", "context-remaining", "context-used"]

TOML

surface_catalog=""
[[ "$SURFACE_ENABLED" -eq 0 ]] || surface_catalog="$CODEX_HOME/skill-catalog.json"
if [[ ${#mcp_json_files[@]} -gt 0 ]]; then
  python3 - "$browser_client_sha256s" "$browser_use_app_version" "$CODEX_HOME" "$surface_catalog" "${mcp_json_files[@]}" >> "$tmp_config" <<'PY'
import json, re, sys
browser_client_sha256s = re.findall(r"\b[a-fA-F0-9]{64}\b", sys.argv[1] if len(sys.argv) > 1 else "")
browser_use_app_version = sys.argv[2] if len(sys.argv) > 2 else ""
codex_home = sys.argv[3] if len(sys.argv) > 3 else ""
surface_catalog = sys.argv[4] if len(sys.argv) > 4 else ""
mcp_paths = sys.argv[5:]
surface_enabled = None
if surface_catalog:
    with open(surface_catalog, encoding="utf-8") as f:
        surface_enabled = set((json.load(f).get("mcp") or {}).get("enabled") or [])
servers = {}
owners = {}
for path in mcp_paths:
    with open(path, encoding="utf-8") as f:
        data = json.load(f)
    for name, spec in (data.get("mcpServers") or {}).items():
        if name in servers:
            print(
                f"ERROR: duplicate MCP server '{name}' in {owners[name]} and {path}; "
                "rename the local server instead of overriding committed .mcp.json",
                file=sys.stderr,
            )
            sys.exit(1)
        servers[name] = spec
        owners[name] = path
for name in sorted(servers):
    spec = servers[name]
    print(f"[mcp_servers.{name}]")
    if "url" in spec:
        print(f'url = {json.dumps(spec["url"])}')
        _auth = (spec.get("headers") or {}).get("Authorization", "")
        _m = re.match(r'^Bearer \$\{([A-Za-z_]\w*)(?::-[^}]*)?\}$', _auth)
        if _m:
            print(f'bearer_token_env_var = {json.dumps(_m.group(1))}')
    elif "command" in spec:
        print(f'command = {json.dumps(spec["command"])}')
        if "args" in spec and spec["args"]:
            args_repr = ", ".join(json.dumps(a) for a in spec["args"])
            print(f"args = [{args_repr}]")
    if surface_enabled is not None:
        print(f'enabled = {str(name in surface_enabled).lower()}')
    print()
    env = dict(spec.get("env") or {})
    if name == "node_repl" and browser_client_sha256s:
        trusted_key = "NODE_REPL_TRUSTED_BROWSER_CLIENT_SHA256S"
        trusted = []
        for value in [env.get(trusted_key, ""), *browser_client_sha256s]:
            for digest in re.findall(r"\b[a-fA-F0-9]{64}\b", value):
                digest = digest.lower()
                if digest not in trusted:
                    trusted.append(digest)
        if trusted:
            env[trusted_key] = " ".join(trusted)
            env.setdefault("NODE_REPL_BROWSER_CLIENT_MARKETPLACE_NAME", "openai-bundled")
    if name == "node_repl":
        env.setdefault("NODE_REPL_NATIVE_PIPE_CONNECT_TIMEOUT_MS", "5000")
        env.setdefault("NODE_REPL_NODE_MODULE_DIRS", "/Applications/Codex.app/Contents/Resources/cua_node/lib/node_modules")
        env.setdefault("NODE_REPL_NODE_PATH", "/Applications/Codex.app/Contents/Resources/cua_node/bin/node")
        env["BROWSER_USE_AVAILABLE_BACKENDS"] = "chrome"
        env["BROWSER_USE_CODEX_APP_BUILD_FLAVOR"] = "prod"
        if browser_use_app_version:
            env["BROWSER_USE_CODEX_APP_VERSION"] = browser_use_app_version
        browser_env_allowlist = [
            "BROWSER_USE_AVAILABLE_BACKENDS",
            "BROWSER_USE_CODEX_APP_BUILD_FLAVOR",
            "BROWSER_USE_CODEX_APP_VERSION",
            "BROWSER_USE_DISABLE_AMBIENT_NETWORK",
            "BROWSER_USE_DISABLE_BROWSER_CAPABILITIES",
            "BROWSER_USE_DISABLE_TAB_CAPABILITIES",
            "BROWSER_USE_SECURITY_MODE",
        ]
        existing_allowlist = [
            part.strip()
            for part in env.get("NODE_REPL_UNTRUSTED_ENV_ALLOWLIST", "").split(",")
            if part.strip()
        ]
        merged_allowlist = []
        for key in [*existing_allowlist, *browser_env_allowlist]:
            if key not in merged_allowlist:
                merged_allowlist.append(key)
        env["NODE_REPL_UNTRUSTED_ENV_ALLOWLIST"] = ",".join(merged_allowlist)
        if codex_home:
            env.setdefault("CODEX_HOME", codex_home)
        env["NODE_REPL_INSTRUCTIONS_USE_CASE_BROWSER"] = "Terminal kh/gd/gp Codex sessions do not receive Codex Desktop's in-app Browser/IAB backend. Do not use @Browser from terminal Codex."
        env["NODE_REPL_INSTRUCTIONS_USE_CASE_CHROME"] = "Chrome plugin cache and native host are prepared, but terminal codex exec/TUI currently may not receive the extension backend. Verify agent.browsers.list() before claiming @Chrome works; Codex Desktop @Chrome remains the supported path."
    if env:
        print(f"[mcp_servers.{name}.env]")
        for k in sorted(env):
            print(f"{k} = {json.dumps(env[k])}")
        print()
PY
fi

if [[ "$SURFACE_ENABLED" -eq 1 && -f "$CODEX_HOME/surface.config.toml" ]]; then
  printf '\n' >> "$tmp_config"
  cat "$CODEX_HOME/surface.config.toml" >> "$tmp_config"
fi

if [[ -f "$config_file" ]]; then
  python3 - "$config_file" "$surface_catalog" >> "$tmp_config" <<'PY'
import json
import re
import sys

path = sys.argv[1]
surface_catalog = sys.argv[2] if len(sys.argv) > 2 else ""
managed_disabled = set()
if surface_catalog:
    with open(surface_catalog, encoding="utf-8") as f:
        managed_disabled = set(json.load(f).get("disabled_skill_paths") or [])
section_header = re.compile(r"^\[.*\]\s*$")
hooks_state_header = re.compile(r"^\[hooks\.state(?:\.|\])")
preserved = []
current = []
in_preserved_section = False

def first_toml_key(raw):
    raw = raw.strip()
    if not raw:
        return ""
    if raw[0] in ('"', "'"):
        quote = raw[0]
        escaped = False
        for index in range(1, len(raw)):
            char = raw[index]
            if quote == '"' and char == "\\" and not escaped:
                escaped = True
                continue
            if char == quote and not escaped:
                return raw[1:index]
            escaped = False
    return raw.split(".", 1)[0]

def should_preserve(header):
    header = header.strip()
    if hooks_state_header.match(header):
        return True
    if header == "[[skills.config]]":
        return True
    if header.startswith("[marketplaces.") and header.endswith("]") and not header.startswith("[["):
        key = first_toml_key(header[len("[marketplaces."):-1])
        return key != "openai-bundled"
    if header.startswith("[plugins.") and header.endswith("]") and not header.startswith("[["):
        key = first_toml_key(header[len("[plugins."):-1])
        return not key.endswith("@openai-bundled")
    return False

def flush_current():
    if not in_preserved_section or not current:
        return
    if current[0].strip() == "[[skills.config]]" and any(
        "launcher-managed-surface" in line for line in current
    ):
        return
    if current[0].strip() == "[[skills.config]]" and managed_disabled:
        for line in current[1:]:
            match = re.match(r'^\s*path\s*=\s*("(?:[^"\\]|\\.)*")\s*$', line)
            if match and json.loads(match.group(1)) in managed_disabled:
                return
    preserved.extend(current)

with open(path, encoding="utf-8") as f:
    for line in f:
        if section_header.match(line):
            flush_current()
            current = []
            in_preserved_section = should_preserve(line)
        if in_preserved_section:
            current.append(line)

flush_current()

if preserved:
    print()
    print("# Preserved Codex runtime state (hooks, skill choices, external plugins).")
    for line in preserved:
        print(line, end="")
PY
fi

# 3. Atomic swap only if content differs (preserves mtime when unchanged)
if [[ -f "$config_file" ]] && cmp -s "$tmp_config" "$config_file"; then
  rm -f "$tmp_config"
else
  mv "$tmp_config" "$config_file"
fi

# 3b. Per-profile config overlays. Codex 0.134.0+ no longer accepts inline
# [profiles.<name>] tables (or a top-level `profile =` selector) in config.toml;
# passing `--profile <name>` against such a config is a hard error. Each profile
# must instead live in its own $CODEX_HOME/<name>.config.toml with TOML
# top-level keys (NOT nested under a table). These overlay config.toml's
# top-level defaults, so they only need to carry the keys that differ. The
# launcher selects one via `codex --profile <name>` (launcher.sh).
write_profile() {
  local name="$1"; shift
  local dest="$CODEX_HOME/$name.config.toml"
  local tmp
  tmp="$(mktemp "$CODEX_HOME/.$name.config.toml.XXXXXX")"
  {
    echo "# Generated by codex-home-prepare.sh — do not edit manually."
    echo "# Codex profile overlay selected via: codex --profile $name"
    printf '%s\n' "$@"
  } > "$tmp"
  if [[ -f "$dest" ]] && cmp -s "$tmp" "$dest"; then
    rm -f "$tmp"
  else
    mv "$tmp" "$dest"
  fi
}

write_profile fast \
  'model = "gpt-5.6-luna"' \
  'model_reasoning_effort = "low"'
write_profile base \
  'model = "gpt-5.6-terra"' \
  'model_reasoning_effort = "medium"'
write_profile plan \
  'model = "gpt-5.6-sol"' \
  'model_reasoning_effort = "high"' \
  'sandbox_mode = "read-only"' \
  'approval_policy = "on-request"'
write_profile rich \
  'model = "gpt-5.6-sol"' \
  'model_reasoning_effort = "high"'

# 4. Materialize harness-approved bundled Codex plugins. The config entries
# above make them enabled, but Codex reports a plugin as installed only when
# its versioned plugin root exists under $CODEX_HOME/plugins/cache.
prune_bundled_plugin_versions() {
  local cache_dir="$1"
  local keep_version="$2"
  local entry name
  [[ -d "$cache_dir" ]] || return 0
  for entry in "$cache_dir"/*; do
    [[ -e "$entry" || -L "$entry" ]] || continue
    name="$(basename "$entry")"
    [[ "$name" == "$keep_version" || "$name" == "latest" ]] && continue
    rm -rf "$entry"
  done
}

update_latest_symlink() {
  local cache_dir="$1"
  local version="$2"
  mkdir -p "$cache_dir"
  rm -f "$cache_dir/latest"
  ln -s "$version" "$cache_dir/latest"
}

materialize_bundled_plugin() {
  local plugin="$1"
  local marketplace="$HOME/.codex/.tmp/bundled-marketplaces/openai-bundled"
  local src="$marketplace/plugins/$plugin"
  local manifest="$src/.codex-plugin/plugin.json"
  [[ -f "$manifest" ]] || return 0

  local version
  version="$(python3 - "$manifest" <<'PY'
import json
import sys
with open(sys.argv[1], encoding="utf-8") as f:
    print(json.load(f)["version"])
PY
)"

  local cache_dir="$CODEX_HOME/plugins/cache/openai-bundled/$plugin"
  local dest="$cache_dir/$version"
  if [[ -d "$dest" ]] && diff -qr "$src" "$dest" >/dev/null 2>&1; then
    update_latest_symlink "$cache_dir" "$version"
    prune_bundled_plugin_versions "$cache_dir" "$version"
    return 0
  fi

  mkdir -p "$cache_dir"
  local tmp_plugin
  tmp_plugin="$(mktemp -d "$CODEX_HOME/.plugin-$plugin.XXXXXX")"
  cp -pR "$src/." "$tmp_plugin/"
  rm -rf "$dest"
  mv "$tmp_plugin" "$dest"
  update_latest_symlink "$cache_dir" "$version"
  prune_bundled_plugin_versions "$cache_dir" "$version"
}

ensure_global_bundled_plugin_latest() {
  local plugin="$1"
  local marketplace="$HOME/.codex/.tmp/bundled-marketplaces/openai-bundled"
  local src="$marketplace/plugins/$plugin"
  local manifest="$src/.codex-plugin/plugin.json"
  [[ -f "$manifest" ]] || return 0

  local version
  version="$(python3 - "$manifest" <<'PY'
import json
import sys
with open(sys.argv[1], encoding="utf-8") as f:
    print(json.load(f)["version"])
PY
)"

  local cache_dir="$HOME/.codex/plugins/cache/openai-bundled/$plugin"
  local dest="$cache_dir/$version"
  if [[ ! -d "$dest" ]] || ! diff -qr -x extension-host-config.json "$src" "$dest" >/dev/null 2>&1; then
    mkdir -p "$cache_dir"
    local tmp_plugin
    tmp_plugin="$(mktemp -d "$HOME/.codex/.plugin-$plugin.XXXXXX")"
    cp -pR "$src/." "$tmp_plugin/"
    rm -rf "$dest"
    mv "$tmp_plugin" "$dest"
  fi
  update_latest_symlink "$cache_dir" "$version"
}

write_global_chrome_extension_host_config() {
  local plugin_root="$HOME/.codex/plugins/cache/openai-bundled/chrome/latest"
  [[ -d "$plugin_root" ]] || return 0

  CHROME_EXTENSION_HOST_CONFIG_CHANGED=0
  CHROME_EXTENSION_HOST_PATH=""
  local host_dir=""
  local host_path=""
  local candidate
  local platform arch
  case "$(uname -s 2>/dev/null || true)" in
    Darwin) platform="macos" ;;
    Linux) platform="linux" ;;
    MINGW*|MSYS*|CYGWIN*) platform="windows" ;;
    *) platform="" ;;
  esac
  arch="$(uname -m 2>/dev/null || true)"
  case "$arch" in
    aarch64) arch="arm64" ;;
    amd64) arch="x86_64" ;;
  esac

  # Current macOS bundles use extension-host/macos/<arch>/Codex for Chrome;
  # older caches used ChatGPT for Chrome. Prefer the running platform and
  # architecture, then retain legacy generic host names and cross-layout
  # fallbacks for older bundles.
  for candidate in \
    "$plugin_root/extension-host/$platform/$arch/Codex for Chrome" \
    "$plugin_root/extension-host/$platform/$arch/ChatGPT for Chrome" \
    "$plugin_root/extension-host/$platform/$arch/extension-host" \
    "$plugin_root/extension-host/$platform/$arch/extension-host.exe" \
    "$plugin_root"/extension-host/*/*/"Codex for Chrome" \
    "$plugin_root"/extension-host/*/*/"ChatGPT for Chrome" \
    "$plugin_root"/extension-host/*/*/extension-host \
    "$plugin_root"/extension-host/*/*/extension-host.exe; do
    [[ -x "$candidate" ]] || continue
    host_path="$candidate"
    host_dir="$(dirname "$candidate")"
    CHROME_EXTENSION_HOST_PATH="$host_path"
    break
  done
  [[ -n "$host_dir" ]] || return 0

  local config="$host_dir/extension-host-config.json"
  local tmp_config
  tmp_config="$(mktemp "$host_dir/.extension-host-config.json.XXXXXX")"

  python3 - "$plugin_root" "$tmp_config" <<'PY'
import json
import os
import sys

plugin_root, tmp_config = sys.argv[1], sys.argv[2]
extension_id = "hehggadaopoacecdllhhajmbjkdcmajg"
extension_id_path = os.path.join(plugin_root, "scripts", "extension-id.json")
try:
    with open(extension_id_path, encoding="utf-8") as f:
        extension_id = json.load(f).get("extensionId") or extension_id
except FileNotFoundError:
    pass

config = {
    "schemaVersion": 1,
    "channel": "prod",
    "browserClientPath": os.path.join(plugin_root, "scripts", "browser-client.mjs"),
    "codexCliPath": "/Applications/Codex.app/Contents/Resources/codex",
    "extensionId": extension_id,
    "nodePath": "/Applications/Codex.app/Contents/Resources/cua_node/bin/node",
    "nodeReplPath": "/Applications/Codex.app/Contents/Resources/cua_node/bin/node_repl",
    "proxyHost": "127.0.0.1",
    "proxyPort": 0,
}
with open(tmp_config, "w", encoding="utf-8") as f:
    json.dump(config, f, indent=2)
    f.write("\n")
PY

  if [[ -f "$config" ]] && cmp -s "$tmp_config" "$config"; then
    rm -f "$tmp_config"
  else
    mv "$tmp_config" "$config"
    CHROME_EXTENSION_HOST_CONFIG_CHANGED=1
  fi
}

restart_global_chrome_extension_host_if_config_changed() {
  [[ "${CHROME_EXTENSION_HOST_CONFIG_CHANGED:-0}" == "1" ]] || return 0
  [[ -n "${CHROME_EXTENSION_HOST_PATH:-}" ]] || return 0
  local host_paths=()
  local host_path_variant
  while IFS= read -r host_path_variant; do
    [[ -n "$host_path_variant" ]] && host_paths+=("$host_path_variant")
  done < <(python3 - "$CHROME_EXTENSION_HOST_PATH" <<'PY'
import os
import sys

seen = set()
for path in (sys.argv[1], os.path.abspath(sys.argv[1]), os.path.realpath(sys.argv[1])):
    variants = [path]
    if path.startswith("/private/"):
        variants.append(path[len("/private"):])
    for variant in variants:
        if variant not in seen:
            seen.add(variant)
            print(variant)
PY
  )
  matching_pids_for_host_paths() {
    python3 - "${host_paths[@]}" <<'PY'
import subprocess
import sys

needles = sys.argv[1:]
current = str(__import__("os").getpid())
out = subprocess.run(["ps", "axww", "-o", "pid=,command="], check=True, text=True, capture_output=True).stdout
for line in out.splitlines():
    stripped = line.strip()
    if not stripped:
        continue
    pid, _, command = stripped.partition(" ")
    if pid == current:
        continue
    if any(needle in command for needle in needles):
        print(pid)
PY
  }

  local pids
  pids="$(matching_pids_for_host_paths)"
  [[ -n "$pids" ]] || return 0
  while IFS= read -r pid; do
    [[ -n "$pid" ]] && kill "$pid" 2>/dev/null || true
  done <<< "$pids"
  local i
  for i in {1..20}; do
    [[ -z "$(matching_pids_for_host_paths)" ]] && return 0
    sleep 0.1
  done
}

remove_bundled_plugin_cache() {
  local plugin="$1"
  rm -rf "$CODEX_HOME/plugins/cache/openai-bundled/$plugin"
}

prepare_bundled_plugins() {
  if [[ "$COMPUTER_USE_PLUGIN_ENABLED" == "true" ]]; then
    materialize_bundled_plugin "computer-use"
  else
    remove_bundled_plugin_cache "computer-use"
  fi
  if [[ "$CHROME_PLUGIN_ENABLED" == "true" ]]; then
    materialize_bundled_plugin "chrome"
  else
    remove_bundled_plugin_cache "chrome"
    return 0
  fi
  # Chrome's native messaging manifest is global and points at
  # ~/.codex/plugins/cache/openai-bundled/chrome/latest. Keep that link valid
  # even when kh/gd/gp run with a per-harness CODEX_HOME. This touches global
  # cache state, so callers may run it under with_global_codex_lock.
  ensure_global_bundled_plugin_latest "chrome"
  write_global_chrome_extension_host_config
  restart_global_chrome_extension_host_if_config_changed
}

if [[ -f "$bundled_marketplace/plugins/computer-use/.codex-plugin/plugin.json" \
   || -f "$bundled_marketplace/plugins/chrome/.codex-plugin/plugin.json" ]]; then
  with_global_codex_lock prepare_bundled_plugins
fi
remove_bundled_plugin_cache "browser"

# 5. Generate hooks.json — Claude harness owns hook scripts as single source
# of truth; Codex layer references them via absolute path so we never copy or
# symlink shell logic across runtime boundaries. SessionStart/UserPromptSubmit/
# Stop run through codex-hook-adapter.sh because Codex rejects Claude's
# top-level additionalContext schema for those events.
hooks_file="$CODEX_HOME/hooks.json"
tmp_hooks="$(mktemp "$CODEX_HOME/.hooks.json.XXXXXX")"
ADAPTER_PATH="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/codex-hook-adapter.sh"
python3 - "$HARNESS_DIR" "$ADAPTER_PATH" > "$tmp_hooks" <<'PY'
import json, os, re, sys
harness = sys.argv[1]
adapter = sys.argv[2]
hooks_dir = os.path.join(harness, "core", "hooks")
settings_path = os.path.join(harness, ".claude", "settings.json")
hooks_policy_path = os.path.join(harness, ".claude", "source", "hooks.yaml")

# Events whose Claude output schema needs translation before Codex sees it.
ADAPTED_EVENTS = {"SessionStart", "UserPromptSubmit", "PostToolUse"}
adapter_available = os.path.isfile(adapter)

def cmd(script, event=None, timeout=None):
    path = os.path.join(hooks_dir, script)
    if event and event in ADAPTED_EVENTS and adapter_available:
        command = f'bash "{adapter}" {event} "{path}"'
    else:
        command = f'bash "{path}"'
    entry = {"type": "command", "command": command}
    if timeout is not None:
        entry["timeout"] = timeout
    return entry

def group(scripts, matcher=None, timeouts=None, event=None):
    timeouts = timeouts or {}
    entries = [{"hooks": [cmd(s, event=event, timeout=timeouts.get(s))]} for s in scripts]
    if matcher:
        for e in entries:
            e["matcher"] = matcher
    return entries

# Only wire hooks whose source actually exists in the harness; this keeps the
# config valid for harnesses that haven't ported every hook yet.
def has(s):
    return os.path.isfile(os.path.join(hooks_dir, s))

def load_exclusions():
    exclusions = {"Stop", "post-edit-codex-resync.sh"}
    if not os.path.isfile(hooks_policy_path):
        return exclusions
    in_list = False
    with open(hooks_policy_path, "r", encoding="utf-8") as f:
        for raw in f:
            stripped = raw.strip()
            if stripped == "codex_exclusions:":
                in_list = True
                continue
            if in_list and stripped.startswith("- "):
                exclusions.add(stripped[2:].strip())
                continue
            if in_list and stripped and not raw.startswith(" "):
                in_list = False
    return exclusions

def extract_hook_script(command):
    match = re.search(r"core/hooks/([^\"'\s]+?\.sh)", command or "")
    if not match:
        return None
    return os.path.basename(match.group(1))

def normalize_matcher(matcher):
    if not matcher:
        return None
    tokens = []
    for token in matcher.split("|"):
        token = token.strip()
        if not token or token == "MultiEdit":
            continue
        if token not in tokens:
            tokens.append(token)
    if any(t in {"Edit", "Write"} for t in tokens) and "apply_patch" not in tokens:
        tokens.append("apply_patch")
    return "|".join(tokens) if tokens else None

def settings_driven_config(exclusions):
    if not os.path.isfile(settings_path):
        return None
    with open(settings_path, "r", encoding="utf-8") as f:
        settings = json.load(f)
    config = {"hooks": {}}
    for event, entries in (settings.get("hooks") or {}).items():
        if event in exclusions:
            continue
        out_entries = []
        for entry in entries or []:
            out_hooks = []
            for hook in entry.get("hooks", []) or []:
                script = extract_hook_script(hook.get("command", ""))
                if not script or script in exclusions or not has(script):
                    continue
                out_hooks.append(
                    cmd(script, event=event, timeout=hook.get("timeout"))
                )
            if not out_hooks:
                continue
            out_entry = {"hooks": out_hooks}
            matcher = normalize_matcher(entry.get("matcher"))
            if matcher:
                out_entry["matcher"] = matcher
            out_entries.append(out_entry)
        if out_entries:
            config["hooks"][event] = out_entries
    return config

def legacy_config():
    config = {"hooks": {}}

    session_start = [s for s in ["session-start.sh"] if has(s)]
    if session_start:
        config["hooks"]["SessionStart"] = group(session_start,
                                                event="SessionStart",
                                                timeouts={"session-start.sh": 10000})

    prompts = [s for s in ["user-prompt-session-end-detect.sh", "prompt-keyword-routing.sh"] if has(s)]
    if prompts:
        config["hooks"]["UserPromptSubmit"] = group(prompts, event="UserPromptSubmit")

    pre_bash = [s for s in ["pre-bash-irreversible-guard.sh", "pre-bash-gh-auth.sh",
                            "pre-bash-pr-gate.sh", "pre-bash-worktree-gate.sh"] if has(s)]
    pre_edit = [s for s in ["pre-tool-budget-guard.sh", "pre-edit-config-protection.sh"] if has(s)]
    pre_entries = []
    if pre_bash:
        pre_entries.extend(group(pre_bash, matcher="Bash", event="PreToolUse",
                                 timeouts={"pre-bash-irreversible-guard.sh": 2000}))
    if pre_edit:
        pre_entries.extend(group(pre_edit, matcher="apply_patch|Edit|Write", event="PreToolUse"))
    if pre_entries:
        config["hooks"]["PreToolUse"] = pre_entries

    post_bash = [s for s in ["post-bash-audit.sh", "post-bash-commit-detect.sh"] if has(s)]
    if post_bash:
        config["hooks"]["PostToolUse"] = group(post_bash, matcher="Bash", event="PostToolUse")
    return config

exclusions = load_exclusions()
config = settings_driven_config(exclusions) or legacy_config()

# Stop intentionally NOT wired for Codex. The Claude harness's session-end.sh
# emits a session-termination checklist (delivery-required, instinct-gap,
# session-record-missing). Codex fires Stop after every turn — wiring it would
# surface that checklist on every routine prompt. Session-end intent for Codex
# is detected via UserPromptSubmit instead.

json.dump(config, sys.stdout, indent=2)
sys.stdout.write("\n")
PY

if [[ -f "$hooks_file" ]] && cmp -s "$tmp_hooks" "$hooks_file"; then
  rm -f "$tmp_hooks"
else
  mv "$tmp_hooks" "$hooks_file"
fi

# 5. Subagents: convert .claude/agents/*.md (Claude format) to
# $CODEX_HOME/agents/*.toml (Codex format). Source-of-truth is the .md file;
# .toml is regenerated each run. A managed marker tracks generated files so
# removing a source .md drops its .toml on next run.
agents_src="$HARNESS_DIR/.claude/agents"
agents_out="$CODEX_HOME/agents"
mkdir -p "$agents_out"
agents_marker="$agents_out/.harness-managed"

if [[ -d "$agents_src" ]]; then
  python3 - "$agents_src" "$agents_out" "$agents_marker" <<'PY'
import os, sys, glob

src_dir, out_dir, marker = sys.argv[1], sys.argv[2], sys.argv[3]

# Preserve mtime when nothing changed: read previous marker, regenerate
# unconditionally, then drop only entries no longer present.
prev = set()
if os.path.exists(marker):
    with open(marker, "r", encoding="utf-8") as f:
        prev = {line.strip() for line in f if line.strip()}

# Model mapping: Claude tiers → Codex GPT-5.6 roles.
def map_model(claude_model):
    m = (claude_model or "").strip().lower()
    if m == "haiku":
        return ("gpt-5.6-luna", "low")
    if m == "opus":
        return ("gpt-5.6-sol", "high")
    # sonnet or unspecified → balanced default
    return ("gpt-5.6-terra", "medium")

# Sandbox: read-only if the agent denies Write/Edit/Bash or only allows
# read-shaped tools. Otherwise workspace-write.
def map_sandbox(tools, disallowed):
    blocked = {t.strip() for t in (disallowed or "").split(",") if t.strip()}
    allowed = {t.strip() for t in (tools or "").split(",") if t.strip()}
    write_tools = {"Write", "Edit", "MultiEdit", "Bash"}
    if blocked & write_tools:
        return "read-only"
    if allowed and not (allowed & write_tools):
        return "read-only"
    return "workspace-write"

def parse_frontmatter(text):
    if not text.startswith("---"):
        return {}, text
    end = text.find("\n---", 3)
    if end < 0:
        return {}, text
    fm_block = text[3:end].lstrip("\n")
    body = text[end+4:].lstrip("\n")
    meta = {}
    lines = fm_block.split("\n")
    i = 0
    while i < len(lines):
        line = lines[i]
        if not line.strip() or ":" not in line:
            i += 1; continue
        key, _, val = line.partition(":")
        key = key.strip()
        val = val.strip()
        # Folded scalar: collect indented continuation lines, join with spaces
        if val == ">":
            buf = []
            i += 1
            while i < len(lines) and (lines[i].startswith(" ") or lines[i].startswith("\t") or not lines[i].strip()):
                if lines[i].strip():
                    buf.append(lines[i].strip())
                i += 1
            meta[key] = " ".join(buf)
            continue
        meta[key] = val
        i += 1
    return meta, body

def toml_escape(s):
    # Triple-quoted TOML string. Escape backslashes and triple quotes.
    return s.replace("\\", "\\\\").replace('"""', '\\"""')

generated = []
for path in sorted(glob.glob(os.path.join(src_dir, "*.md"))):
    name = os.path.basename(path)[:-3]
    if name == "_index":
        continue
    with open(path, "r", encoding="utf-8") as f:
        text = f.read()
    meta, body = parse_frontmatter(text)
    if not meta.get("name"):
        continue
    codex_model, effort = map_model(meta.get("model", ""))
    sandbox = map_sandbox(meta.get("tools", ""), meta.get("disallowedTools", ""))
    desc = meta.get("description", "").strip()

    out_lines = []
    out_lines.append(f'name = "{meta["name"]}"')
    if desc:
        # description is single-line in Codex agent TOML
        out_lines.append(f'description = "{desc}"')
    out_lines.append(f'model = "{codex_model}"')
    if effort:
        out_lines.append(f'model_reasoning_effort = "{effort}"')
    out_lines.append(f'sandbox_mode = "{sandbox}"')
    body_text = body.rstrip() + "\n"
    out_lines.append('developer_instructions = """')
    out_lines.append(toml_escape(body_text).rstrip("\n"))
    out_lines.append('"""')

    out_path = os.path.join(out_dir, f"{name}.toml")
    new_content = "\n".join(out_lines) + "\n"
    if os.path.exists(out_path):
        with open(out_path, "r", encoding="utf-8") as f:
            old = f.read()
        if old == new_content:
            generated.append(f"{name}.toml")
            continue
    with open(out_path, "w", encoding="utf-8") as f:
        f.write(new_content)
    generated.append(f"{name}.toml")

# Drop stale entries whose source disappeared.
stale = prev - set(generated)
for entry in stale:
    try:
        os.remove(os.path.join(out_dir, entry))
    except FileNotFoundError:
        pass

new_marker = "".join(g + "\n" for g in generated)
if not os.path.exists(marker) or open(marker).read() != new_marker:
    with open(marker, "w", encoding="utf-8") as f:
        f.write(new_marker)
PY
fi

if [[ "$SURFACE_ENABLED" -eq 1 ]]; then
  python3 "$SURFACE_RESOLVER" write-stamp \
    --stamp "$SURFACE_STAMP" \
    --fingerprint-json "$SURFACE_FINGERPRINT_JSON"
fi
