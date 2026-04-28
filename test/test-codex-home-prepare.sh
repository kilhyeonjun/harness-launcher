#!/usr/bin/env zsh
# test-codex-home-prepare.sh — verify codex-home-prepare.sh side effects.

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LAUNCHER_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
PREPARE="$LAUNCHER_DIR/bin/codex-home-prepare.sh"

cleanup() {
  [[ -n "${TEST_TEMP:-}" && -d "$TEST_TEMP" ]] && rm -rf "$TEST_TEMP"
}
trap cleanup EXIT

[[ -x "$PREPARE" ]] || { echo "FAIL: $PREPARE missing or not executable"; exit 1; }

TEST_TEMP="$(mktemp -d)"
TEST_HARNESS="$TEST_TEMP/fake-harness"
mkdir -p "$TEST_HARNESS"

cat > "$TEST_HARNESS/CLAUDE.md" <<'EOF'
# Fake harness rules
EOF

cat > "$TEST_HARNESS/.mcp.json" <<'EOF'
{
  "mcpServers": {
    "atlassian": { "type": "http", "url": "http://localhost:38100/mcp" },
    "context7": { "command": "npx", "args": ["-y", "@upstash/context7-mcp"] },
    "google_workspace": {
      "command": "bash",
      "args": ["core/bin/start-google-workspace-mcp.sh"],
      "env": { "FOO": "bar" }
    }
  }
}
EOF

"$PREPARE" "$TEST_HARNESS"

CODEX_HOME="$TEST_HARNESS/.harness/codex"

[[ -d "$CODEX_HOME" ]] || { echo "FAIL: CODEX_HOME dir not created"; exit 1; }
echo "PASS: CODEX_HOME directory created"

# AGENTS.md → ../../CLAUDE.md
[[ -L "$CODEX_HOME/AGENTS.md" ]] || { echo "FAIL: AGENTS.md is not a symlink"; exit 1; }
target="$(readlink "$CODEX_HOME/AGENTS.md")"
[[ "$target" == "../../CLAUDE.md" ]] || { echo "FAIL: AGENTS.md target wrong: $target"; exit 1; }
[[ -f "$CODEX_HOME/AGENTS.md" ]] || { echo "FAIL: AGENTS.md does not resolve to file"; exit 1; }
echo "PASS: AGENTS.md → ../../CLAUDE.md"

# config.toml structure
config="$CODEX_HOME/config.toml"
[[ -f "$config" ]] || { echo "FAIL: config.toml missing"; exit 1; }
grep -q '^model = "gpt-5.5"' "$config" || { echo "FAIL: top-level model missing"; exit 1; }
grep -q '^\[profiles.fast\]' "$config" || { echo "FAIL: profiles.fast missing"; exit 1; }
grep -q '^\[profiles.base\]' "$config" || { echo "FAIL: profiles.base missing"; exit 1; }
grep -q '^\[profiles.plan\]' "$config" || { echo "FAIL: profiles.plan missing"; exit 1; }
grep -q '^\[profiles.rich\]' "$config" || { echo "FAIL: profiles.rich missing"; exit 1; }
grep -q '^sandbox_mode = "read-only"' "$config" || { echo "FAIL: plan sandbox_mode missing"; exit 1; }
echo "PASS: config.toml has top-level + 4 profiles"

# mcp_servers schema (HTTP, stdio, env)
grep -q '^\[mcp_servers.atlassian\]' "$config" || { echo "FAIL: atlassian section missing"; exit 1; }
grep -q '^url = "http://localhost:38100/mcp"' "$config" || { echo "FAIL: atlassian url missing"; exit 1; }
grep -q '^\[mcp_servers.context7\]' "$config" || { echo "FAIL: context7 section missing"; exit 1; }
grep -q '^command = "npx"' "$config" || { echo "FAIL: context7 command missing"; exit 1; }
grep -q '^args = \["-y", "@upstash/context7-mcp"\]' "$config" || { echo "FAIL: context7 args missing"; exit 1; }
grep -q '^\[mcp_servers.google_workspace\]' "$config" || { echo "FAIL: google_workspace section missing"; exit 1; }
grep -q '^\[mcp_servers.google_workspace.env\]' "$config" || { echo "FAIL: env subtable missing"; exit 1; }
grep -q '^FOO = "bar"' "$config" || { echo "FAIL: env value missing"; exit 1; }
echo "PASS: mcp_servers TOML schema (HTTP, stdio, env)"

# Idempotent: re-run leaves config.toml mtime unchanged when input unchanged
mtime_before=$(stat -f %m "$config" 2>/dev/null || stat -c %Y "$config")
sleep 1.1
"$PREPARE" "$TEST_HARNESS"
mtime_after=$(stat -f %m "$config" 2>/dev/null || stat -c %Y "$config")
[[ "$mtime_before" == "$mtime_after" ]] || {
  echo "FAIL: config.toml mtime changed on no-op re-run ($mtime_before -> $mtime_after)"; exit 1;
}
echo "PASS: idempotent (mtime unchanged on no-op re-run)"

# Regenerates on .mcp.json change
cat > "$TEST_HARNESS/.mcp.json" <<'EOF'
{ "mcpServers": { "newone": { "type": "http", "url": "http://example.com/mcp" } } }
EOF
"$PREPARE" "$TEST_HARNESS"
grep -q '^\[mcp_servers.newone\]' "$config" || { echo "FAIL: regen didn't add newone"; exit 1; }
if grep -q '^\[mcp_servers.atlassian\]' "$config"; then
  echo "FAIL: regen didn't drop atlassian"; exit 1;
fi
echo "PASS: regenerates on .mcp.json change (adds new, drops old)"

# auth.json + skills symlinks (best-effort: only if global source exists)
if [[ -f "$HOME/.codex/auth.json" ]]; then
  [[ -L "$CODEX_HOME/auth.json" ]] || { echo "FAIL: auth.json symlink missing"; exit 1; }
  echo "PASS: auth.json symlink present"
else
  echo "SKIP: auth.json — ~/.codex/auth.json not present"
fi
# Skills merge: $CODEX_HOME/skills must be a real directory containing
# per-skill symlinks from both global ~/.codex/skills/* and per-harness
# .claude/skills/*. Use a mocked HOME so the test is self-contained.
FAKE_HOME="$TEST_TEMP/fake-home"
FAKE_HARNESS_S="$TEST_TEMP/fake-harness-skills"
mkdir -p "$FAKE_HOME/.codex/skills/global-skill" \
         "$FAKE_HOME/.codex/skills/.system/system-skill" \
         "$FAKE_HARNESS_S/.claude/skills/harness-skill"
echo "# fake rules" > "$FAKE_HARNESS_S/CLAUDE.md"
cat > "$FAKE_HOME/.codex/skills/global-skill/SKILL.md" <<'EOF'
---
name: global-skill
description: Globally available skill
---
EOF
cat > "$FAKE_HOME/.codex/skills/.system/system-skill/SKILL.md" <<'EOF'
---
name: system-skill
description: Codex system bundle
---
EOF
cat > "$FAKE_HARNESS_S/.claude/skills/harness-skill/SKILL.md" <<'EOF'
---
name: harness-skill
description: Per-harness Claude skill
---
EOF
HOME="$FAKE_HOME" "$PREPARE" "$FAKE_HARNESS_S"
SKILLS_OUT="$FAKE_HARNESS_S/.harness/codex/skills"

[[ -d "$SKILLS_OUT" && ! -L "$SKILLS_OUT" ]] || {
  echo "FAIL: skills should be a real directory, not a single symlink"; exit 1;
}
echo "PASS: skills is a real directory"

[[ -L "$SKILLS_OUT/global-skill" ]] || { echo "FAIL: global-skill symlink missing"; exit 1; }
[[ -f "$SKILLS_OUT/global-skill/SKILL.md" ]] || { echo "FAIL: global-skill resolves to file"; exit 1; }
echo "PASS: ~/.codex/skills/global-skill linked"

[[ -L "$SKILLS_OUT/harness-skill" ]] || { echo "FAIL: harness-skill symlink missing"; exit 1; }
[[ -f "$SKILLS_OUT/harness-skill/SKILL.md" ]] || { echo "FAIL: harness-skill resolves to file"; exit 1; }
echo "PASS: \$HARNESS_DIR/.claude/skills/harness-skill linked"

[[ -L "$SKILLS_OUT/.system" ]] || { echo "FAIL: .system bundle symlink missing"; exit 1; }
echo "PASS: ~/.codex/skills/.system bundle linked"

[[ -f "$SKILLS_OUT/.harness-managed" ]] || { echo "FAIL: .harness-managed marker missing"; exit 1; }
grep -qx 'global-skill' "$SKILLS_OUT/.harness-managed"  || { echo "FAIL: marker missing global-skill"; exit 1; }
grep -qx 'harness-skill' "$SKILLS_OUT/.harness-managed" || { echo "FAIL: marker missing harness-skill"; exit 1; }
echo "PASS: .harness-managed marker tracks all linked entries"

# Re-run after dropping a per-harness skill should remove its symlink
rm -rf "$FAKE_HARNESS_S/.claude/skills/harness-skill"
HOME="$FAKE_HOME" "$PREPARE" "$FAKE_HARNESS_S"
[[ ! -L "$SKILLS_OUT/harness-skill" ]] || { echo "FAIL: stale harness-skill symlink not removed"; exit 1; }
[[ -L "$SKILLS_OUT/global-skill" ]] || { echo "FAIL: global-skill should still be present"; exit 1; }
echo "PASS: re-run drops sources that were removed"

# Migration: old single-symlink layout should be replaced with directory
rm -rf "$FAKE_HARNESS_S/.harness/codex/skills"
ln -s "$FAKE_HOME/.codex/skills" "$FAKE_HARNESS_S/.harness/codex/skills"
[[ -L "$FAKE_HARNESS_S/.harness/codex/skills" ]] || { echo "FAIL: setup precondition"; exit 1; }
HOME="$FAKE_HOME" "$PREPARE" "$FAKE_HARNESS_S"
[[ -d "$SKILLS_OUT" && ! -L "$SKILLS_OUT" ]] || {
  echo "FAIL: migration from old symlink layout failed"; exit 1;
}
echo "PASS: migrates from old single-symlink layout"

# Missing .mcp.json should not break — config.toml still has profiles
TEST_HARNESS2="$TEST_TEMP/fake-harness-2"
mkdir -p "$TEST_HARNESS2"
echo "# rules" > "$TEST_HARNESS2/CLAUDE.md"
"$PREPARE" "$TEST_HARNESS2"
config2="$TEST_HARNESS2/.harness/codex/config.toml"
[[ -f "$config2" ]] || { echo "FAIL: config.toml missing for harness without .mcp.json"; exit 1; }
grep -q '^\[profiles.fast\]' "$config2" || { echo "FAIL: profiles missing for harness without .mcp.json"; exit 1; }
if grep -q '^\[mcp_servers' "$config2"; then
  echo "FAIL: should not have mcp_servers when .mcp.json missing"; exit 1;
fi
echo "PASS: works without .mcp.json (no mcp_servers section, profiles intact)"

# Codex hooks infrastructure: config.toml must enable codex_hooks feature,
# and hooks.json must reference Claude harness's core/hooks/*.sh by absolute path.
# Source-of-truth: Claude harness owns hook scripts; Codex layer references them.
TEST_HARNESS3="$TEST_TEMP/fake-harness-hooks"
mkdir -p "$TEST_HARNESS3/core/hooks"
echo "# rules" > "$TEST_HARNESS3/CLAUDE.md"
# Stub hook scripts so the generator can verify they exist
for h in session-start user-prompt-session-end-detect prompt-keyword-routing \
         pre-bash-irreversible-guard pre-bash-gh-auth pre-bash-pr-gate pre-bash-worktree-gate \
         pre-tool-budget-guard pre-edit-config-protection \
         post-bash-audit post-bash-commit-detect session-end; do
  : > "$TEST_HARNESS3/core/hooks/$h.sh"
done
"$PREPARE" "$TEST_HARNESS3"
config3="$TEST_HARNESS3/.harness/codex/config.toml"
hooks_json="$TEST_HARNESS3/.harness/codex/hooks.json"

grep -q '^\[features\]' "$config3" || { echo "FAIL: [features] section missing"; exit 1; }
grep -q '^codex_hooks = true' "$config3" || { echo "FAIL: codex_hooks feature flag missing"; exit 1; }
echo "PASS: [features].codex_hooks enabled in config.toml"

[[ -f "$hooks_json" ]] || { echo "FAIL: hooks.json not generated"; exit 1; }
python3 -c "import json; json.load(open('$hooks_json'))" 2>/dev/null \
  || { echo "FAIL: hooks.json is not valid JSON"; exit 1; }
echo "PASS: hooks.json generated and valid JSON"

# Verify each event has the expected hook entries
python3 - "$hooks_json" "$TEST_HARNESS3" <<'PY' || exit 1
import json, sys, os
path, harness = sys.argv[1], sys.argv[2]
with open(path) as f: data = json.load(f)
hooks = data.get("hooks", {})
expected = {
    "SessionStart": ["session-start.sh"],
    "UserPromptSubmit": ["user-prompt-session-end-detect.sh", "prompt-keyword-routing.sh"],
    "PreToolUse": ["pre-bash-irreversible-guard.sh", "pre-bash-gh-auth.sh",
                   "pre-bash-pr-gate.sh", "pre-bash-worktree-gate.sh",
                   "pre-tool-budget-guard.sh", "pre-edit-config-protection.sh"],
    "PostToolUse": ["post-bash-audit.sh", "post-bash-commit-detect.sh"],
    "Stop": ["session-end.sh"],
}
for event, scripts in expected.items():
    found = []
    for entry in hooks.get(event, []):
        for h in entry.get("hooks", []):
            cmd = h.get("command", "")
            for s in scripts:
                if s in cmd:
                    found.append(s)
                    abs_expected = os.path.join(harness, "core/hooks", s)
                    if abs_expected not in cmd:
                        print(f"FAIL: {event} hook {s} should reference absolute path {abs_expected}, got: {cmd}")
                        sys.exit(1)
    missing = set(scripts) - set(found)
    if missing:
        print(f"FAIL: {event} missing hooks: {missing}")
        sys.exit(1)
print("OK")
PY
echo "PASS: hooks.json wires all expected hooks via absolute paths to core/hooks/"

# Bash matcher should be present and gate Bash-only hooks
python3 - "$hooks_json" <<'PY' || exit 1
import json, sys
data = json.load(open(sys.argv[1]))
bash_only = ["pre-bash-irreversible-guard.sh", "pre-bash-gh-auth.sh",
             "pre-bash-pr-gate.sh", "pre-bash-worktree-gate.sh",
             "post-bash-audit.sh", "post-bash-commit-detect.sh"]
for event in ("PreToolUse", "PostToolUse"):
    for entry in data["hooks"].get(event, []):
        cmds = " ".join(h.get("command","") for h in entry.get("hooks", []))
        if any(b in cmds for b in bash_only):
            m = entry.get("matcher", "")
            if "Bash" not in m:
                print(f"FAIL: {event} entry with bash-specific hook lacks Bash matcher: {entry}")
                sys.exit(1)
PY
echo "PASS: Bash-specific hooks gated by Bash matcher"

# Idempotent: re-running should not change hooks.json mtime
mtime_h_before=$(stat -f %m "$hooks_json" 2>/dev/null || stat -c %Y "$hooks_json")
sleep 1.1
"$PREPARE" "$TEST_HARNESS3"
mtime_h_after=$(stat -f %m "$hooks_json" 2>/dev/null || stat -c %Y "$hooks_json")
[[ "$mtime_h_before" == "$mtime_h_after" ]] || {
  echo "FAIL: hooks.json mtime changed on no-op re-run"; exit 1;
}
echo "PASS: hooks.json idempotent on no-op re-run"

# Subagents: .claude/agents/*.md should be converted to $CODEX_HOME/agents/*.toml
# with model mapping (haiku→gpt-5.4-mini, sonnet→gpt-5.5, opus→gpt-5.5+high effort)
# and sandbox derived from tools/disallowedTools.
TEST_HARNESS4="$TEST_TEMP/fake-harness-agents"
mkdir -p "$TEST_HARNESS4/.claude/agents"
echo "# rules" > "$TEST_HARNESS4/CLAUDE.md"
cat > "$TEST_HARNESS4/.claude/agents/explorer.md" <<'EOF'
---
name: explorer
model: haiku
description: >
  Fast codebase search and analysis. Read-only investigation.
tools: Read, Glob, Grep
disallowedTools: Write, Edit, Bash, Agent
---

## Role

Quickly search and analyze codebases.
EOF
cat > "$TEST_HARNESS4/.claude/agents/reviewer.md" <<'EOF'
---
name: reviewer
model: opus
description: >
  Code review specialist. Read-only review.
tools: Read, Glob, Grep, Agent
disallowedTools: Write, Edit, Bash
---

## Role

Review changed code read-only.
EOF
cat > "$TEST_HARNESS4/.claude/agents/implementer.md" <<'EOF'
---
name: implementer
model: sonnet
description: >
  TDD implementation specialist.
tools: Read, Glob, Grep, Edit, Write, Bash, Agent
---

## Role

Implement code changes with strict TDD.
EOF
# _index.md should be ignored
echo "# index — not an agent" > "$TEST_HARNESS4/.claude/agents/_index.md"

"$PREPARE" "$TEST_HARNESS4"
agents_out="$TEST_HARNESS4/.harness/codex/agents"

[[ -d "$agents_out" ]] || { echo "FAIL: agents output dir missing"; exit 1; }
echo "PASS: agents output directory created"

[[ -f "$agents_out/explorer.toml" ]] || { echo "FAIL: explorer.toml missing"; exit 1; }
[[ -f "$agents_out/reviewer.toml" ]] || { echo "FAIL: reviewer.toml missing"; exit 1; }
[[ -f "$agents_out/implementer.toml" ]] || { echo "FAIL: implementer.toml missing"; exit 1; }
[[ -f "$agents_out/_index.toml" ]] && { echo "FAIL: _index.md should be skipped"; exit 1; }
echo "PASS: 3 agents converted, _index.md skipped"

# explorer: haiku → gpt-5.4-mini, read-only sandbox
grep -q '^name = "explorer"' "$agents_out/explorer.toml" || { echo "FAIL: explorer name"; exit 1; }
grep -q '^model = "gpt-5.4-mini"' "$agents_out/explorer.toml" || { echo "FAIL: explorer model"; exit 1; }
grep -q '^sandbox_mode = "read-only"' "$agents_out/explorer.toml" || { echo "FAIL: explorer sandbox"; exit 1; }
grep -q '^developer_instructions = """' "$agents_out/explorer.toml" || { echo "FAIL: explorer developer_instructions"; exit 1; }
grep -q 'Quickly search and analyze' "$agents_out/explorer.toml" || { echo "FAIL: explorer body content"; exit 1; }
echo "PASS: explorer (haiku) → gpt-5.4-mini + read-only"

# reviewer: opus → gpt-5.5 + effort=high, read-only sandbox
grep -q '^model = "gpt-5.5"' "$agents_out/reviewer.toml" || { echo "FAIL: reviewer model"; exit 1; }
grep -q '^model_reasoning_effort = "high"' "$agents_out/reviewer.toml" || { echo "FAIL: reviewer effort"; exit 1; }
grep -q '^sandbox_mode = "read-only"' "$agents_out/reviewer.toml" || { echo "FAIL: reviewer sandbox"; exit 1; }
echo "PASS: reviewer (opus) → gpt-5.5 + effort=high + read-only"

# implementer: sonnet → gpt-5.5 default effort, workspace-write sandbox
grep -q '^model = "gpt-5.5"' "$agents_out/implementer.toml" || { echo "FAIL: implementer model"; exit 1; }
if grep -q '^model_reasoning_effort' "$agents_out/implementer.toml"; then
  echo "FAIL: implementer should not have explicit effort (sonnet uses default)"; exit 1
fi
grep -q '^sandbox_mode = "workspace-write"' "$agents_out/implementer.toml" || { echo "FAIL: implementer sandbox"; exit 1; }
echo "PASS: implementer (sonnet) → gpt-5.5 + workspace-write"

# Idempotent
mtime_a_before=$(stat -f %m "$agents_out/explorer.toml" 2>/dev/null || stat -c %Y "$agents_out/explorer.toml")
sleep 1.1
"$PREPARE" "$TEST_HARNESS4"
mtime_a_after=$(stat -f %m "$agents_out/explorer.toml" 2>/dev/null || stat -c %Y "$agents_out/explorer.toml")
[[ "$mtime_a_before" == "$mtime_a_after" ]] || {
  echo "FAIL: agents toml mtime changed on no-op re-run"; exit 1;
}
echo "PASS: agents idempotent on no-op re-run"

# Removing source agent should drop the generated toml
rm "$TEST_HARNESS4/.claude/agents/reviewer.md"
"$PREPARE" "$TEST_HARNESS4"
[[ ! -f "$agents_out/reviewer.toml" ]] || { echo "FAIL: stale reviewer.toml not removed"; exit 1; }
[[ -f "$agents_out/explorer.toml" ]] || { echo "FAIL: explorer.toml should remain"; exit 1; }
echo "PASS: removing source agent drops generated toml"

echo "✓ All codex-home-prepare tests passed"
