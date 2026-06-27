#!/usr/bin/env zsh
# test-codex-home-prepare.sh — verify codex-home-prepare.sh side effects.

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LAUNCHER_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
PREPARE="$LAUNCHER_DIR/bin/codex-home-prepare.sh"

find_harness_repo_root() {
  local candidate
  for candidate in \
    "${HARNESS_TEST_REPO_ROOT:-}" \
    "$LAUNCHER_DIR/../.." \
    "$HOME/kilhyeonjun-harness" \
    "$HOME/gameduo-personal-harness" \
    "$HOME/gameduo-platform-harness"
  do
    [[ -n "$candidate" ]] || continue
    if [[ -f "$candidate/core/scripts/harness_compile.py" ]]; then
      (cd "$candidate" && pwd)
      return 0
    fi
  done
  return 1
}

REPO_ROOT="$(find_harness_repo_root || true)"

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
    "glider": {
      "type": "stdio",
      "command": "/usr/local/bin/glider",
      "args": ["mcp", "serve"]
    },
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

# AGENTS.md: with no rules, falls back to symlink → CLAUDE.md so Codex's
# project-scope walk still picks up harness instructions
[[ -L "$CODEX_HOME/AGENTS.md" ]] || { echo "FAIL: AGENTS.md should be symlink when no rules"; exit 1; }
target="$(readlink "$CODEX_HOME/AGENTS.md")"
[[ "$target" == "../../CLAUDE.md" ]] || { echo "FAIL: AGENTS.md target wrong: $target"; exit 1; }
echo "PASS: AGENTS.md → CLAUDE.md (no-rules fallback)"

# config.toml structure
config="$CODEX_HOME/config.toml"
[[ -f "$config" ]] || { echo "FAIL: config.toml missing"; exit 1; }
grep -q '^model = "gpt-5.5"' "$config" || { echo "FAIL: top-level model missing"; exit 1; }
# Context window must NOT be pinned — Codex resolves the real backend limit
# (272K for gpt-5.5) from its model metadata; pinned 1M values broke auto-compact.
if grep -q '^model_context_window' "$config"; then
  echo "FAIL: model_context_window pinned (must come from Codex model metadata)"; exit 1;
fi
if grep -q '^model_auto_compact_token_limit' "$config"; then
  echo "FAIL: model_auto_compact_token_limit pinned (must come from Codex model metadata)"; exit 1;
fi
# Codex 0.134.0+ rejects `--profile` when config.toml still contains inline
# [profiles.*] tables. Profiles must live in separate <name>.config.toml files.
if grep -q '^\[profiles\.' "$config"; then
  echo "FAIL: config.toml still has legacy [profiles.*] table (Codex 0.134.0+ rejects --profile)"; exit 1;
fi
echo "PASS: config.toml has no legacy [profiles.*] tables"

# Per-profile overlay files: top-level keys (NOT nested under [profiles.<name>])
for p in fast base plan rich; do
  pf="$CODEX_HOME/$p.config.toml"
  [[ -f "$pf" ]] || { echo "FAIL: $p.config.toml missing"; exit 1; }
  grep -q '^model = "gpt-5.5"' "$pf" || { echo "FAIL: $p.config.toml missing top-level model"; exit 1; }
  if grep -q '^\[profiles' "$pf"; then
    echo "FAIL: $p.config.toml must use top-level keys, not a [profiles.$p] table"; exit 1;
  fi
done
grep -q '^model_reasoning_effort = "low"' "$CODEX_HOME/fast.config.toml" || { echo "FAIL: fast effort wrong"; exit 1; }
grep -q '^model_reasoning_effort = "medium"' "$CODEX_HOME/base.config.toml" || { echo "FAIL: base effort wrong"; exit 1; }
grep -q '^model_reasoning_effort = "high"' "$CODEX_HOME/plan.config.toml" || { echo "FAIL: plan effort wrong"; exit 1; }
grep -q '^sandbox_mode = "read-only"' "$CODEX_HOME/plan.config.toml" || { echo "FAIL: plan sandbox_mode missing"; exit 1; }
grep -q '^approval_policy = "on-request"' "$CODEX_HOME/plan.config.toml" || { echo "FAIL: plan approval_policy missing"; exit 1; }
grep -q '^model_reasoning_effort = "high"' "$CODEX_HOME/rich.config.toml" || { echo "FAIL: rich effort wrong"; exit 1; }
echo "PASS: per-profile *.config.toml files (top-level keys; fast/base/plan/rich)"

# mcp_servers schema (HTTP, stdio, env)
grep -q '^\[mcp_servers.atlassian\]' "$config" || { echo "FAIL: atlassian section missing"; exit 1; }
grep -q '^url = "http://localhost:38100/mcp"' "$config" || { echo "FAIL: atlassian url missing"; exit 1; }
grep -q '^\[mcp_servers.context7\]' "$config" || { echo "FAIL: context7 section missing"; exit 1; }
grep -q '^command = "npx"' "$config" || { echo "FAIL: context7 command missing"; exit 1; }
grep -q '^args = \["-y", "@upstash/context7-mcp"\]' "$config" || { echo "FAIL: context7 args missing"; exit 1; }
grep -q '^\[mcp_servers.glider\]' "$config" || { echo "FAIL: glider section missing"; exit 1; }
grep -q '^command = "/usr/local/bin/glider"' "$config" || { echo "FAIL: glider command missing"; exit 1; }
grep -q '^args = \["mcp", "serve"\]' "$config" || { echo "FAIL: glider args missing"; exit 1; }
grep -q '^\[mcp_servers.google_workspace\]' "$config" || { echo "FAIL: google_workspace section missing"; exit 1; }
grep -q '^\[mcp_servers.google_workspace.env\]' "$config" || { echo "FAIL: env subtable missing"; exit 1; }
grep -q '^FOO = "bar"' "$config" || { echo "FAIL: env value missing"; exit 1; }
echo "PASS: mcp_servers TOML schema (HTTP, stdio, env)"
echo "PASS: glider stdio MCP converted"

# HTTP Authorization Bearer headers → bearer_token_env_var. Codex streamable_http
# only accepts bearer_token_env_var (the env-var *name*), never a literal
# bearer_token. `${VAR}` and `${VAR:-default}` both map to the name; any other
# Authorization shape (or no headers) emits nothing — keeping the change additive.
TEST_HARNESS_AUTH="$TEST_TEMP/fake-harness-auth"
mkdir -p "$TEST_HARNESS_AUTH"
echo "# rules" > "$TEST_HARNESS_AUTH/CLAUDE.md"
cat > "$TEST_HARNESS_AUTH/.mcp.json" <<'EOF'
{
  "mcpServers": {
    "bearer_default": {
      "type": "http",
      "url": "https://example.test/api/mcp",
      "headers": { "Authorization": "Bearer ${HYPERDX_API_KEY:-}" }
    },
    "bearer_plain": {
      "type": "http",
      "url": "https://other.test/mcp",
      "headers": { "Authorization": "Bearer ${OTHER_TOKEN}" }
    },
    "bearer_literal": {
      "type": "http",
      "url": "https://lit.test/mcp",
      "headers": { "Authorization": "Bearer sk-static-literal" }
    },
    "no_auth": { "type": "http", "url": "https://noauth.test/mcp" }
  }
}
EOF
"$PREPARE" "$TEST_HARNESS_AUTH"
config_auth="$TEST_HARNESS_AUTH/.harness/codex/config.toml"
[[ -f "$config_auth" ]] || { echo "FAIL: auth config.toml missing"; exit 1; }
# ${VAR:-default} form → bearer_token_env_var = "VAR"
grep -q '^bearer_token_env_var = "HYPERDX_API_KEY"' "$config_auth" || {
  echo "FAIL: \${VAR:-} Bearer header not mapped to bearer_token_env_var"; exit 1;
}
# ${VAR} form → bearer_token_env_var = "VAR"
grep -q '^bearer_token_env_var = "OTHER_TOKEN"' "$config_auth" || {
  echo "FAIL: \${VAR} Bearer header not mapped to bearer_token_env_var"; exit 1;
}
# Codex rejects a literal bearer_token for streamable_http — must NEVER emit one
if grep -qE '^bearer_token[[:space:]]*=' "$config_auth"; then
  echo "FAIL: literal bearer_token emitted (Codex rejects it for streamable_http)"; exit 1;
fi
# Non-\${VAR} Authorization (literal) and header-less servers must emit nothing
[[ "$(grep -c '^bearer_token_env_var = ' "$config_auth")" == "2" ]] || {
  echo "FAIL: expected exactly 2 bearer_token_env_var lines (literal/no-auth must not emit)"; exit 1;
}
echo "PASS: HTTP Authorization Bearer \${VAR}/\${VAR:-} → bearer_token_env_var (no literal bearer_token)"

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
         "$FAKE_HOME/.agents/skills/agents-global-skill" \
         "$FAKE_HOME/.codex/skills/.system/system-skill" \
         "$FAKE_HOME/.codex/superpowers/skills/brainstorming" \
         "$FAKE_HARNESS_S/.claude/skills/harness-skill" \
         "$FAKE_HOME/.codex/.tmp/bundled-marketplaces/openai-bundled/plugins/browser/.codex-plugin" \
         "$FAKE_HOME/.codex/.tmp/bundled-marketplaces/openai-bundled/plugins/browser/scripts" \
         "$FAKE_HOME/.codex/.tmp/bundled-marketplaces/openai-bundled/plugins/browser/skills/browser" \
         "$FAKE_HOME/.codex/.tmp/bundled-marketplaces/openai-bundled/plugins/chrome/.codex-plugin" \
         "$FAKE_HOME/.codex/.tmp/bundled-marketplaces/openai-bundled/plugins/chrome/extension-host/macos/arm64" \
         "$FAKE_HOME/.codex/.tmp/bundled-marketplaces/openai-bundled/plugins/chrome/scripts" \
         "$FAKE_HOME/.codex/.tmp/bundled-marketplaces/openai-bundled/plugins/chrome/skills/chrome" \
         "$FAKE_HOME/.codex/plugins/cache/openai-bundled/chrome" \
         "$FAKE_HOME/.codex/.tmp/bundled-marketplaces/openai-bundled/plugins/computer-use/.codex-plugin" \
         "$FAKE_HOME/.codex/.tmp/bundled-marketplaces/openai-bundled/plugins/computer-use/skills/computer-use"
echo "# fake rules" > "$FAKE_HARNESS_S/CLAUDE.md"
cat > "$FAKE_HOME/.codex/skills/global-skill/SKILL.md" <<'EOF'
---
name: global-skill
description: Globally available skill
---
EOF
cat > "$FAKE_HOME/.agents/skills/agents-global-skill/SKILL.md" <<'EOF'
---
name: agents-global-skill
description: Global skill installed by skills CLI
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
cat > "$FAKE_HOME/.codex/superpowers/skills/brainstorming/SKILL.md" <<'EOF'
---
name: brainstorming
description: Superpowers brainstorming skill
---
EOF
cat > "$FAKE_HOME/.codex/.tmp/bundled-marketplaces/openai-bundled/plugins/browser/.codex-plugin/plugin.json" <<'EOF'
{"name":"browser","version":"0.1.0-test","skills":"./skills/"}
EOF
cat > "$FAKE_HOME/.codex/.tmp/bundled-marketplaces/openai-bundled/plugins/browser/skills/browser/SKILL.md" <<'EOF'
---
name: browser
description: Browser test skill
---
EOF
cat > "$FAKE_HOME/.codex/.tmp/bundled-marketplaces/openai-bundled/plugins/browser/scripts/browser-client.mjs" <<'EOF'
export const fakeBrowserClient = "browser-current";
EOF
cat > "$FAKE_HOME/.codex/.tmp/bundled-marketplaces/openai-bundled/plugins/chrome/.codex-plugin/plugin.json" <<'EOF'
{"name":"chrome","version":"0.1.0-test","skills":"./skills/"}
EOF
cat > "$FAKE_HOME/.codex/.tmp/bundled-marketplaces/openai-bundled/plugins/chrome/skills/chrome/SKILL.md" <<'EOF'
---
name: chrome
description: Chrome test skill
---
EOF
cat > "$FAKE_HOME/.codex/.tmp/bundled-marketplaces/openai-bundled/plugins/chrome/scripts/browser-client.mjs" <<'EOF'
export const fakeBrowserClient = "chrome-current";
EOF
cat > "$FAKE_HOME/.codex/.tmp/bundled-marketplaces/openai-bundled/plugins/chrome/scripts/extension-id.json" <<'EOF'
{
  "extensionId": "fake-chrome-extension-id",
  "extensionHostName": "com.openai.codexextension"
}
EOF
cat > "$FAKE_HOME/.codex/.tmp/bundled-marketplaces/openai-bundled/plugins/chrome/extension-host/macos/arm64/extension-host" <<'EOF'
#!/bin/sh
trap 'exit 0' TERM INT
while :; do sleep 1; done
EOF
chmod +x "$FAKE_HOME/.codex/.tmp/bundled-marketplaces/openai-bundled/plugins/chrome/extension-host/macos/arm64/extension-host"
cp -pR "$FAKE_HOME/.codex/.tmp/bundled-marketplaces/openai-bundled/plugins/chrome" \
        "$FAKE_HOME/.codex/plugins/cache/openai-bundled/chrome/0.1.0-test"
cat > "$FAKE_HOME/.codex/.tmp/bundled-marketplaces/openai-bundled/plugins/computer-use/.codex-plugin/plugin.json" <<'EOF'
{"name":"computer-use","version":"1.0.0-test","skills":"./skills/"}
EOF
cat > "$FAKE_HOME/.codex/.tmp/bundled-marketplaces/openai-bundled/plugins/computer-use/skills/computer-use/SKILL.md" <<'EOF'
---
name: computer-use
description: Computer Use test skill
---
EOF
cat > "$FAKE_HARNESS_S/.mcp.json" <<'EOF'
{
  "mcpServers": {
    "node_repl": {
      "command": "/fake/node_repl",
      "env": {
        "NODE_REPL_BROWSER_CLIENT_MARKETPLACE_NAME": "openai-bundled",
        "NODE_REPL_TRUSTED_BROWSER_CLIENT_SHA256S": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
      }
    }
  }
}
EOF
mkdir -p "$FAKE_HARNESS_S/.harness/codex/plugins/cache/openai-bundled/chrome/0.0.1-stale"
mkdir -p "$FAKE_HOME/.codex/plugins/cache/openai-bundled/chrome/0.0.1-stale"
ln -s 0.0.1-stale "$FAKE_HARNESS_S/.harness/codex/plugins/cache/openai-bundled/chrome/latest"
ln -s 0.0.1-stale "$FAKE_HOME/.codex/plugins/cache/openai-bundled/chrome/latest"
"$FAKE_HOME/.codex/plugins/cache/openai-bundled/chrome/0.1.0-test/extension-host/macos/arm64/extension-host" chrome-extension://fake-chrome-extension-id/ &
FAKE_EXTENSION_HOST_PID=$!
HOME="$FAKE_HOME" HARNESS_CODEX_BUNDLED_MARKETPLACE_SOURCE="$FAKE_HOME/.codex/.tmp/bundled-marketplaces/openai-bundled" "$PREPARE" "$FAKE_HARNESS_S"
SKILLS_OUT="$FAKE_HARNESS_S/.harness/codex/skills"
FAKE_CONFIG="$FAKE_HARNESS_S/.harness/codex/config.toml"

[[ -d "$SKILLS_OUT" && ! -L "$SKILLS_OUT" ]] || {
  echo "FAIL: skills should be a real directory, not a single symlink"; exit 1;
}
echo "PASS: skills is a real directory"

[[ -L "$SKILLS_OUT/global-skill" ]] || { echo "FAIL: global-skill symlink missing"; exit 1; }
[[ -f "$SKILLS_OUT/global-skill/SKILL.md" ]] || { echo "FAIL: global-skill resolves to file"; exit 1; }
echo "PASS: ~/.codex/skills/global-skill linked"

[[ -L "$SKILLS_OUT/agents-global-skill" ]] || { echo "FAIL: agents-global-skill symlink missing"; exit 1; }
[[ -f "$SKILLS_OUT/agents-global-skill/SKILL.md" ]] || { echo "FAIL: agents-global-skill resolves to file"; exit 1; }
echo "PASS: ~/.agents/skills/agents-global-skill linked"

[[ -L "$SKILLS_OUT/harness-skill" ]] || { echo "FAIL: harness-skill symlink missing"; exit 1; }
[[ -f "$SKILLS_OUT/harness-skill/SKILL.md" ]] || { echo "FAIL: harness-skill resolves to file"; exit 1; }
echo "PASS: \$HARNESS_DIR/.claude/skills/harness-skill linked"

[[ -L "$SKILLS_OUT/.system" ]] || { echo "FAIL: .system bundle symlink missing"; exit 1; }
echo "PASS: ~/.codex/skills/.system bundle linked"

[[ -L "$SKILLS_OUT/superpowers" ]] || { echo "FAIL: superpowers namespace symlink missing"; exit 1; }
[[ -f "$SKILLS_OUT/superpowers/brainstorming/SKILL.md" ]] || {
  echo "FAIL: superpowers namespace symlink does not resolve to nested skills"; exit 1;
}
echo "PASS: ~/.codex/superpowers/skills namespace linked"

[[ -f "$SKILLS_OUT/.harness-managed" ]] || { echo "FAIL: .harness-managed marker missing"; exit 1; }
grep -qx 'global-skill' "$SKILLS_OUT/.harness-managed"  || { echo "FAIL: marker missing global-skill"; exit 1; }
grep -qx 'agents-global-skill' "$SKILLS_OUT/.harness-managed" || { echo "FAIL: marker missing agents-global-skill"; exit 1; }
grep -qx 'harness-skill' "$SKILLS_OUT/.harness-managed" || { echo "FAIL: marker missing harness-skill"; exit 1; }
grep -qx 'superpowers' "$SKILLS_OUT/.harness-managed" || { echo "FAIL: marker missing superpowers"; exit 1; }
echo "PASS: .harness-managed marker tracks all linked entries"

[[ -f "$FAKE_HARNESS_S/.harness/codex/plugins/cache/openai-bundled/computer-use/1.0.0-test/.codex-plugin/plugin.json" ]] || {
  echo "FAIL: computer-use plugin cache not materialized"; exit 1;
}
[[ -f "$FAKE_HARNESS_S/.harness/codex/plugins/cache/openai-bundled/computer-use/1.0.0-test/skills/computer-use/SKILL.md" ]] || {
  echo "FAIL: computer-use plugin skill not materialized"; exit 1;
}
[[ -f "$FAKE_HARNESS_S/.harness/codex/plugins/cache/openai-bundled/chrome/0.1.0-test/.codex-plugin/plugin.json" ]] || {
  echo "FAIL: chrome plugin cache not materialized"; exit 1;
}
[[ -f "$FAKE_HARNESS_S/.harness/codex/plugins/cache/openai-bundled/chrome/0.1.0-test/scripts/browser-client.mjs" ]] || {
  echo "FAIL: chrome browser-client not materialized"; exit 1;
}
[[ -L "$FAKE_HARNESS_S/.harness/codex/plugins/cache/openai-bundled/chrome/latest" ]] || {
  echo "FAIL: harness chrome latest symlink missing"; exit 1;
}
[[ "$(readlink "$FAKE_HARNESS_S/.harness/codex/plugins/cache/openai-bundled/chrome/latest")" == "0.1.0-test" ]] || {
  echo "FAIL: harness chrome latest symlink should replace stale target"; exit 1;
}
[[ -f "$FAKE_HARNESS_S/.harness/codex/plugins/cache/openai-bundled/chrome/latest/scripts/browser-client.mjs" ]] || {
  echo "FAIL: harness chrome latest symlink does not resolve"; exit 1;
}
[[ -L "$FAKE_HOME/.codex/plugins/cache/openai-bundled/chrome/latest" ]] || {
  echo "FAIL: global chrome latest symlink missing"; exit 1;
}
[[ "$(readlink "$FAKE_HOME/.codex/plugins/cache/openai-bundled/chrome/latest")" == "0.1.0-test" ]] || {
  echo "FAIL: global chrome latest symlink should replace stale target"; exit 1;
}
[[ -f "$FAKE_HOME/.codex/plugins/cache/openai-bundled/chrome/latest/extension-host/macos/arm64/extension-host" ]] || {
  echo "FAIL: global chrome latest symlink does not expose extension host"; exit 1;
}
HOST_CONFIG="$FAKE_HOME/.codex/plugins/cache/openai-bundled/chrome/latest/extension-host/macos/arm64/extension-host-config.json"
[[ -f "$HOST_CONFIG" ]] || {
  echo "FAIL: global chrome extension-host-config.json missing"; exit 1;
}
grep -q "\"browserClientPath\": \"$FAKE_HOME/.codex/plugins/cache/openai-bundled/chrome/latest/scripts/browser-client.mjs\"" "$HOST_CONFIG" || {
  echo "FAIL: extension-host-config browserClientPath should point at global chrome latest browser-client"; exit 1;
}
grep -q '"codexCliPath": "/Applications/Codex.app/Contents/Resources/codex"' "$HOST_CONFIG" || {
  echo "FAIL: extension-host-config codexCliPath missing"; exit 1;
}
grep -q '"nodeReplPath": "/Applications/Codex.app/Contents/Resources/cua_node/bin/node_repl"' "$HOST_CONFIG" || {
  echo "FAIL: extension-host-config nodeReplPath missing"; exit 1;
}
grep -q '"extensionId": "fake-chrome-extension-id"' "$HOST_CONFIG" || {
  echo "FAIL: extension-host-config extensionId should follow chrome plugin metadata"; exit 1;
}
sleep 0.3
if kill -0 "$FAKE_EXTENSION_HOST_PID" 2>/dev/null && ! ps -p "$FAKE_EXTENSION_HOST_PID" -o stat= | grep -q 'Z'; then
  ps -p "$FAKE_EXTENSION_HOST_PID" -o pid=,stat=,command= >&2 || true
  kill "$FAKE_EXTENSION_HOST_PID" 2>/dev/null || true
  echo "FAIL: stale global chrome extension-host should be stopped after config rewrite"; exit 1;
fi
wait "$FAKE_EXTENSION_HOST_PID" 2>/dev/null || true
echo "PASS: stale global chrome extension-host stopped after config rewrite"
[[ ! -e "$FAKE_HOME/.codex/.codex-home-prepare-global.lock" ]] || {
  echo "FAIL: global Codex cache lock was not released"; exit 1;
}
FAKE_HARNESS_PAR_A="$TEST_TEMP/fake-harness-parallel-a"
FAKE_HARNESS_PAR_B="$TEST_TEMP/fake-harness-parallel-b"
mkdir -p "$FAKE_HARNESS_PAR_A" "$FAKE_HARNESS_PAR_B"
echo "# fake rules" > "$FAKE_HARNESS_PAR_A/CLAUDE.md"
echo "# fake rules" > "$FAKE_HARNESS_PAR_B/CLAUDE.md"
HOME="$FAKE_HOME" HARNESS_CODEX_BUNDLED_MARKETPLACE_SOURCE="$FAKE_HOME/.codex/.tmp/bundled-marketplaces/openai-bundled" "$PREPARE" "$FAKE_HARNESS_PAR_A" &
pid_a=$!
HOME="$FAKE_HOME" HARNESS_CODEX_BUNDLED_MARKETPLACE_SOURCE="$FAKE_HOME/.codex/.tmp/bundled-marketplaces/openai-bundled" "$PREPARE" "$FAKE_HARNESS_PAR_B" &
pid_b=$!
set +e
wait "$pid_a"; rc_a=$?
wait "$pid_b"; rc_b=$?
set -e
[[ "$rc_a" -eq 0 && "$rc_b" -eq 0 ]] || {
  echo "FAIL: concurrent prepare should not race on global Codex cache"; exit 1;
}
[[ ! -e "$FAKE_HOME/.codex/.codex-home-prepare-global.lock" ]] || {
  echo "FAIL: global Codex cache lock left behind after concurrent prepare"; exit 1;
}
echo "PASS: concurrent prepare serializes global Codex cache updates"
[[ ! -e "$FAKE_HARNESS_S/.harness/codex/plugins/cache/openai-bundled/browser" ]] || {
  echo "FAIL: browser plugin cache should be pruned for terminal Codex"; exit 1;
}
grep -q '^\[plugins."chrome@openai-bundled"\]' "$FAKE_HARNESS_S/.harness/codex/config.toml" || {
  echo "FAIL: chrome plugin config missing"; exit 1;
}
if grep -q '^\[plugins."browser@openai-bundled"\]' "$FAKE_HARNESS_S/.harness/codex/config.toml"; then
  echo "FAIL: browser plugin config should be omitted for terminal Codex TUI"; exit 1;
fi
grep -q '^\[plugins."computer-use@openai-bundled"\]' "$FAKE_HARNESS_S/.harness/codex/config.toml" || {
  echo "FAIL: computer-use plugin config missing"; exit 1;
}
echo "PASS: terminal Codex plugin cache exposes Computer Use and Chrome; Browser pruned"

grep -q '^NODE_REPL_TRUSTED_BROWSER_CLIENT_SHA256S = ' "$FAKE_CONFIG" || {
  echo "FAIL: node_repl should trust Chrome browser-client hash"; exit 1;
}
grep -q '^NODE_REPL_BROWSER_CLIENT_MARKETPLACE_NAME = "openai-bundled"' "$FAKE_CONFIG" || {
  echo "FAIL: node_repl should carry browser-client marketplace"; exit 1;
}
grep -q '^BROWSER_USE_AVAILABLE_BACKENDS = "chrome"' "$FAKE_CONFIG" || {
  echo "FAIL: node_repl should enable Chrome backend"; exit 1;
}
grep -q '^BROWSER_USE_CODEX_APP_BUILD_FLAVOR = "prod"' "$FAKE_CONFIG" || {
  echo "FAIL: node_repl missing Browser Use build flavor"; exit 1;
}
grep -q '^BROWSER_USE_CODEX_APP_VERSION = "0.1.0-test"' "$FAKE_CONFIG" || {
  echo "FAIL: node_repl missing Browser Use app version"; exit 1;
}
grep -q '^NODE_REPL_UNTRUSTED_ENV_ALLOWLIST = "BROWSER_USE_AVAILABLE_BACKENDS,BROWSER_USE_CODEX_APP_BUILD_FLAVOR,BROWSER_USE_CODEX_APP_VERSION,BROWSER_USE_DISABLE_AMBIENT_NETWORK,BROWSER_USE_DISABLE_BROWSER_CAPABILITIES,BROWSER_USE_DISABLE_TAB_CAPABILITIES,BROWSER_USE_SECURITY_MODE"' "$FAKE_CONFIG" || {
  echo "FAIL: node_repl must expose Browser Use env to browser-client when it runs outside trusted context"; exit 1;
}
grep -q "^CODEX_HOME = \"$FAKE_HARNESS_S/.harness/codex\"" "$FAKE_CONFIG" || {
  echo "FAIL: node_repl missing generated CODEX_HOME env"; exit 1;
}
grep -q "^NODE_REPL_TRUSTED_CODE_PATHS = \".*$FAKE_HARNESS_S/.harness/codex.*$FAKE_HOME/.codex" "$FAKE_CONFIG" || {
  echo "FAIL: node_repl trusted code paths do not include harness and global Codex homes"; exit 1;
}
grep -q '^NODE_REPL_NATIVE_PIPE_CONNECT_TIMEOUT_MS = "5000"' "$FAKE_CONFIG" || {
  echo "FAIL: node_repl missing native pipe connect timeout env"; exit 1;
}
grep -q '^NODE_REPL_INSTRUCTIONS_USE_CASE_BROWSER = "Terminal kh/gd/gp Codex sessions do not receive Codex Desktop'\''s in-app Browser/IAB backend. Do not use @Browser from terminal Codex."' "$FAKE_CONFIG" || {
  echo "FAIL: node_repl Browser instruction should state terminal Browser/IAB absence"; exit 1;
}
grep -q '^NODE_REPL_INSTRUCTIONS_USE_CASE_CHROME = "Chrome plugin cache and native host are prepared, but terminal codex exec/TUI currently may not receive the extension backend. Verify agent.browsers.list() before claiming @Chrome works; Codex Desktop @Chrome remains the supported path."' "$FAKE_CONFIG" || {
  echo "FAIL: node_repl Chrome instruction should require live backend verification"; exit 1;
}
grep -q '^NODE_REPL_NODE_PATH = "/Applications/Codex.app/Contents/Resources/cua_node/bin/node"' "$FAKE_CONFIG" || {
  echo "FAIL: node_repl missing bundled node path env"; exit 1;
}
grep -q '^NODE_REPL_NODE_MODULE_DIRS = "/Applications/Codex.app/Contents/Resources/cua_node/lib/node_modules"' "$FAKE_CONFIG" || {
  echo "FAIL: node_repl missing bundled node module dirs env"; exit 1;
}
echo "PASS: node_repl Browser Use runtime env mirrors Codex app defaults"

# Re-run after dropping a per-harness skill should remove its symlink
rm -rf "$FAKE_HARNESS_S/.claude/skills/harness-skill"
HOME="$FAKE_HOME" HARNESS_CODEX_BUNDLED_MARKETPLACE_SOURCE="$FAKE_HOME/.codex/.tmp/bundled-marketplaces/openai-bundled" "$PREPARE" "$FAKE_HARNESS_S"
[[ ! -L "$SKILLS_OUT/harness-skill" ]] || { echo "FAIL: stale harness-skill symlink not removed"; exit 1; }
[[ -L "$SKILLS_OUT/global-skill" ]] || { echo "FAIL: global-skill should still be present"; exit 1; }
echo "PASS: re-run drops sources that were removed"

# Migration: old single-symlink layout should be replaced with directory
rm -rf "$FAKE_HARNESS_S/.harness/codex/skills"
ln -s "$FAKE_HOME/.codex/skills" "$FAKE_HARNESS_S/.harness/codex/skills"
[[ -L "$FAKE_HARNESS_S/.harness/codex/skills" ]] || { echo "FAIL: setup precondition"; exit 1; }
HOME="$FAKE_HOME" HARNESS_CODEX_BUNDLED_MARKETPLACE_SOURCE="$FAKE_HOME/.codex/.tmp/bundled-marketplaces/openai-bundled" "$PREPARE" "$FAKE_HARNESS_S"
[[ -d "$SKILLS_OUT" && ! -L "$SKILLS_OUT" ]] || {
  echo "FAIL: migration from old symlink layout failed"; exit 1;
}
echo "PASS: migrates from old single-symlink layout"

# Missing .mcp.json should not break — per-profile files still generated
TEST_HARNESS2="$TEST_TEMP/fake-harness-2"
mkdir -p "$TEST_HARNESS2"
echo "# rules" > "$TEST_HARNESS2/CLAUDE.md"
"$PREPARE" "$TEST_HARNESS2"
config2="$TEST_HARNESS2/.harness/codex/config.toml"
[[ -f "$config2" ]] || { echo "FAIL: config.toml missing for harness without .mcp.json"; exit 1; }
[[ -f "$TEST_HARNESS2/.harness/codex/rich.config.toml" ]] || { echo "FAIL: rich.config.toml missing for harness without .mcp.json"; exit 1; }
if grep -q '^\[mcp_servers' "$config2"; then
  echo "FAIL: should not have mcp_servers when .mcp.json missing"; exit 1;
fi
echo "PASS: works without .mcp.json (no mcp_servers section, per-profile files intact)"

# Codex hooks infrastructure: config.toml must enable hooks feature,
# and hooks.json must reference Claude harness's core/hooks/*.sh by absolute path.
# Source-of-truth: Claude harness owns hook scripts; Codex layer references them.
TEST_HARNESS3="$TEST_TEMP/fake-harness-hooks"
mkdir -p "$TEST_HARNESS3/core/hooks" "$TEST_HARNESS3/.claude/source"
echo "# rules" > "$TEST_HARNESS3/CLAUDE.md"
mkdir -p "$TEST_HARNESS3/.codex"
cat > "$TEST_HARNESS3/.codex/hooks.json" <<'EOF'
{
  "hooks": {
    "PreToolUse": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "bash \"$CLAUDE_PROJECT_DIR/core/hooks/pre-tool-budget-guard.sh\""
          }
        ]
      }
    ]
  }
}
EOF
# Stub hook scripts so the generator can verify they exist
for h in session-start user-prompt-session-end-detect prompt-keyword-routing \
         pre-bash-irreversible-guard pre-bash-gh-auth pre-bash-pr-gate pre-bash-worktree-gate \
         pre-tool-budget-guard pre-tool-opus-guard pre-edit-config-protection \
         pre-edit-codex-output-guard pre-write-memory-block pre-tool-scoped-context \
         post-edit-codex-resync suggest-compact post-bash-audit post-bash-commit-detect \
         post-tool-auto-pilot-reinject session-end; do
  : > "$TEST_HARNESS3/core/hooks/$h.sh"
done
cat > "$TEST_HARNESS3/.claude/source/hooks.yaml" <<'EOF'
hooks:
  source: .claude/settings.json
  mode: settings-driven
  codex_exclusions:
    - Stop
    - post-edit-codex-resync.sh
EOF
cat > "$TEST_HARNESS3/.claude/settings.json" <<'EOF'
{
  "hooks": {
    "SessionStart": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "bash \"$CLAUDE_PROJECT_DIR/core/hooks/session-start.sh\"",
            "timeout": 10000
          }
        ]
      }
    ],
    "UserPromptSubmit": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "bash \"$CLAUDE_PROJECT_DIR/core/hooks/prompt-keyword-routing.sh\""
          },
          {
            "type": "command",
            "command": "bash \"$CLAUDE_PROJECT_DIR/core/hooks/user-prompt-session-end-detect.sh\"",
            "timeout": 5000
          }
        ]
      }
    ],
    "PreToolUse": [
      {
        "matcher": "Edit|Write",
        "hooks": [
          {
            "type": "command",
            "command": "bash \"$CLAUDE_PROJECT_DIR/core/hooks/pre-tool-budget-guard.sh\""
          }
        ]
      },
      {
        "matcher": "Edit|Write|MultiEdit",
        "hooks": [
          {
            "type": "command",
            "command": "bash \"$CLAUDE_PROJECT_DIR/core/hooks/pre-tool-opus-guard.sh\""
          },
          {
            "type": "command",
            "command": "bash \"$CLAUDE_PROJECT_DIR/core/hooks/pre-edit-codex-output-guard.sh\""
          }
        ]
      },
      {
        "matcher": "Write",
        "hooks": [
          {
            "type": "command",
            "command": "bash \"$CLAUDE_PROJECT_DIR/core/hooks/pre-write-memory-block.sh\""
          }
        ]
      },
      {
        "matcher": "Read|Edit|Write|MultiEdit|Grep|Glob",
        "hooks": [
          {
            "type": "command",
            "command": "bash \"$CLAUDE_PROJECT_DIR/core/hooks/pre-tool-scoped-context.sh\""
          }
        ]
      },
      {
        "matcher": "Bash",
        "hooks": [
          {
            "type": "command",
            "command": "bash \"$CLAUDE_PROJECT_DIR/core/hooks/pre-bash-irreversible-guard.sh\"",
            "timeout": 2000
          },
          {
            "type": "command",
            "command": "bash \"$CLAUDE_PROJECT_DIR/core/hooks/pre-bash-gh-auth.sh\""
          },
          {
            "type": "command",
            "command": "bash \"$CLAUDE_PROJECT_DIR/core/hooks/pre-bash-pr-gate.sh\""
          },
          {
            "type": "command",
            "command": "bash \"$CLAUDE_PROJECT_DIR/core/hooks/pre-bash-worktree-gate.sh\""
          }
        ]
      }
    ],
    "PostToolUse": [
      {
        "matcher": "Edit|Write|MultiEdit",
        "hooks": [
          {
            "type": "command",
            "command": "bash \"$CLAUDE_PROJECT_DIR/core/hooks/post-edit-codex-resync.sh\"",
            "timeout": 2000
          }
        ]
      },
      {
        "matcher": ".*",
        "hooks": [
          {
            "type": "command",
            "command": "bash \"$CLAUDE_PROJECT_DIR/core/hooks/suggest-compact.sh\"",
            "timeout": 3000
          },
          {
            "type": "command",
            "command": "bash \"$CLAUDE_PROJECT_DIR/core/hooks/post-tool-auto-pilot-reinject.sh\"",
            "timeout": 1000
          }
        ]
      },
      {
        "matcher": "Bash",
        "hooks": [
          {
            "type": "command",
            "command": "bash \"$CLAUDE_PROJECT_DIR/core/hooks/post-bash-audit.sh\"",
            "timeout": 3000
          },
          {
            "type": "command",
            "command": "bash \"$CLAUDE_PROJECT_DIR/core/hooks/post-bash-commit-detect.sh\"",
            "timeout": 3000
          }
        ]
      }
    ],
    "Stop": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "bash \"$CLAUDE_PROJECT_DIR/core/hooks/session-end.sh\"",
            "timeout": 20000
          }
        ]
      }
    ]
  }
}
EOF
"$PREPARE" "$TEST_HARNESS3"
config3="$TEST_HARNESS3/.harness/codex/config.toml"
hooks_json="$TEST_HARNESS3/.harness/codex/hooks.json"
legacy_backup_count="$(find "$TEST_HARNESS3" -maxdepth 1 -type d -name '.codex.legacy-*' | wc -l | tr -d ' ')"
[[ ! -e "$TEST_HARNESS3/.codex" ]] || { echo "FAIL: legacy project .codex directory should be quarantined"; exit 1; }
[[ "$legacy_backup_count" == "1" ]] || {
  echo "FAIL: expected one .codex.legacy-* quarantine backup, got $legacy_backup_count"; exit 1;
}
echo "PASS: legacy project .codex quarantined so Codex does not load stale root hooks"

grep -q '^\[features\]' "$config3" || { echo "FAIL: [features] section missing"; exit 1; }
grep -q '^hooks = true' "$config3" || { echo "FAIL: hooks feature flag missing"; exit 1; }
grep -q '^goals = true' "$config3" || { echo "FAIL: goals feature flag missing"; exit 1; }
grep -q '^multi_agent = true' "$config3" || { echo "FAIL: multi_agent feature flag missing"; exit 1; }
if grep -q '^codex_hooks = true' "$config3"; then
  echo "FAIL: deprecated codex_hooks feature flag present"; exit 1;
fi
echo "PASS: [features].hooks, goals, and multi_agent enabled in config.toml"

# ChatGPT Apps/connectors disabled at feature-flag level — harness sessions
# don't need them and the user opts deny-by-default globally.
grep -q '^apps = false' "$config3" || { echo "FAIL: [features].apps = false missing"; exit 1; }
echo "PASS: [features].apps disabled in config.toml"

if grep -q '^model_context_window\|^model_auto_compact_token_limit' "$config3"; then
  echo "FAIL: context window/auto-compact pinned (must come from Codex model metadata)"; exit 1;
fi
echo "PASS: no pinned context-window overrides (Codex metadata is source of truth)"

grep -q '^\[marketplaces.openai-bundled\]' "$config3" || {
  echo "FAIL: openai-bundled marketplace missing"; exit 1;
}
grep -q "^source = \"$HOME/.codex/.tmp/bundled-marketplaces/openai-bundled\"" "$config3" || {
  echo "FAIL: openai-bundled marketplace source missing"; exit 1;
}
grep -q '^\[plugins\."computer-use@openai-bundled"\]' "$config3" || {
  echo "FAIL: computer-use plugin section missing"; exit 1;
}
grep -q '^\[plugins\."chrome@openai-bundled"\]' "$config3" || {
  echo "FAIL: chrome plugin section missing"; exit 1;
}
if grep -q '^\[plugins\."browser@openai-bundled"\]' "$config3"; then
  echo "FAIL: browser plugin should not be enabled in terminal Codex config"; exit 1;
fi
grep -A1 '^\[plugins\."computer-use@openai-bundled"\]' "$config3" | grep -q '^enabled = true' || {
  echo "FAIL: computer-use plugin not enabled"; exit 1;
}
grep -A1 '^\[plugins\."chrome@openai-bundled"\]' "$config3" | grep -q '^enabled = true' || {
  echo "FAIL: chrome plugin not enabled"; exit 1;
}
echo "PASS: terminal Codex enables Computer Use and Chrome; Browser omitted"

grep -q '^\[tui\]' "$config3" || { echo "FAIL: [tui] section missing"; exit 1; }
grep -q '^status_line = \["model-with-reasoning", "current-dir", "git-branch", "run-state", "context-remaining", "context-used"\]' "$config3" || {
  echo "FAIL: [tui].status_line missing expected harness defaults"; exit 1;
}
echo "PASS: [tui].status_line configured in config.toml"

cat >> "$config3" <<'EOF'

[hooks.state."test-preserve-hook"]
trusted_hash = "sha256:preserved"
EOF
"$PREPARE" "$TEST_HARNESS3"
grep -q '^\[hooks\.state\."test-preserve-hook"\]' "$config3" || {
  echo "FAIL: hooks.state trust section was not preserved across config regeneration"; exit 1;
}
grep -q '^trusted_hash = "sha256:preserved"' "$config3" || {
  echo "FAIL: hooks.state trusted_hash was not preserved across config regeneration"; exit 1;
}
echo "PASS: Codex hooks.state trust sections preserved across config regeneration"

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
                   "pre-tool-budget-guard.sh", "pre-tool-opus-guard.sh",
                   "pre-edit-codex-output-guard.sh", "pre-write-memory-block.sh",
                   "pre-tool-scoped-context.sh"],
    "PostToolUse": ["suggest-compact.sh", "post-bash-audit.sh",
                    "post-bash-commit-detect.sh", "post-tool-auto-pilot-reinject.sh"],
}
# Stop is intentionally NOT wired: Codex fires Stop after every turn while
# session-end.sh emits a session-termination checklist. Wiring it would
# trigger session-end procedures on every routine prompt.
if "Stop" in hooks:
    print(f"FAIL: Stop event must not be wired (Codex fires per-turn): {hooks['Stop']}")
    sys.exit(1)
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

python3 - "$hooks_json" <<'PY' || exit 1
import json, sys
data = json.load(open(sys.argv[1]))
blob = json.dumps(data)
for excluded in ("post-edit-codex-resync.sh", "session-end.sh"):
    if excluded in blob:
        print(f"FAIL: excluded hook should not be wired for Codex: {excluded}")
        sys.exit(1)
print("OK")
PY
echo "PASS: hooks.yaml exclusions respected for Codex hooks"

# Adapter wrapping: SessionStart, UserPromptSubmit, and PostToolUse may emit
# Claude-format JSON ({"additionalContext": ...}) which Codex rejects. Those
# events MUST be routed through codex-hook-adapter.sh; PreToolUse stays direct
# so blocking guard decisions are not hidden.
python3 - "$hooks_json" <<'PY' || exit 1
import json, sys
data = json.load(open(sys.argv[1]))
adapted = {"SessionStart", "UserPromptSubmit", "PostToolUse"}
direct = {"PreToolUse"}
for event in adapted:
    for entry in data["hooks"].get(event, []):
        for h in entry.get("hooks", []):
            cmd = h.get("command", "")
            if "codex-hook-adapter.sh" not in cmd:
                print(f"FAIL: {event} hook not wrapped via adapter: {cmd}")
                sys.exit(1)
            if event not in cmd:
                print(f"FAIL: {event} adapter call missing event arg: {cmd}")
                sys.exit(1)
for event in direct:
    for entry in data["hooks"].get(event, []):
        for h in entry.get("hooks", []):
            cmd = h.get("command", "")
            if "codex-hook-adapter.sh" in cmd:
                print(f"FAIL: {event} hook should NOT use adapter (no rewrite needed): {cmd}")
                sys.exit(1)
PY
echo "PASS: SessionStart/UserPromptSubmit/PostToolUse routed through codex-hook-adapter.sh; Stop unwired"

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

# AGENTS.md generation when .claude/rules/* exist: concatenate rule contents
# into $CODEX_HOME/AGENTS.md as a real generated file (not symlink). Codex's
# global-scope discovery loads it; the harness-root AGENTS.md → CLAUDE.md
# symlink continues to feed the project-scope walk.
TEST_HARNESS_R="$TEST_TEMP/fake-harness-rules"
mkdir -p "$TEST_HARNESS_R/.claude/rules"
echo "# CLAUDE rules" > "$TEST_HARNESS_R/CLAUDE.md"
cat > "$TEST_HARNESS_R/.claude/rules/cascading-updates.md" <<'EOF'
# Cascading Updates

When Edit/Write to core/hooks/foo.sh, also touch core/hooks/test/test-foo.sh.
EOF
cat > "$TEST_HARNESS_R/.claude/rules/_index.md" <<'EOF'
# Rules Index — should be skipped
EOF

"$PREPARE" "$TEST_HARNESS_R"
agents_file="$TEST_HARNESS_R/.harness/codex/AGENTS.md"

[[ -f "$agents_file" ]] || { echo "FAIL: rules-AGENTS.md not generated"; exit 1; }
[[ -L "$agents_file" ]] && { echo "FAIL: rules-AGENTS.md should be a real file, not symlink"; exit 1; }
grep -q "Generated by codex-home-prepare.sh" "$agents_file" || {
  echo "FAIL: rules-AGENTS.md missing generator header"; exit 1;
}
grep -q "When Edit/Write to core/hooks" "$agents_file" || {
  echo "FAIL: rules-AGENTS.md missing rule body"; exit 1;
}
if grep -q "Rules Index" "$agents_file"; then
  echo "FAIL: rules-AGENTS.md should skip _index.md"; exit 1;
fi
echo "PASS: AGENTS.md generated from .claude/rules/* (skips _index.md)"

# Idempotent
mtime_b=$(stat -f %m "$agents_file" 2>/dev/null || stat -c %Y "$agents_file")
sleep 1.1
"$PREPARE" "$TEST_HARNESS_R"
mtime_a=$(stat -f %m "$agents_file" 2>/dev/null || stat -c %Y "$agents_file")
[[ "$mtime_b" == "$mtime_a" ]] || { echo "FAIL: AGENTS.md mtime changed on no-op re-run"; exit 1; }
echo "PASS: rules-AGENTS.md idempotent"

# Adding a new rule must show up in regenerated AGENTS.md
cat > "$TEST_HARNESS_R/.claude/rules/budget.md" <<'EOF'
# Budget Rule

CLAUDE.md ≤ 60 lines.
EOF
"$PREPARE" "$TEST_HARNESS_R"
grep -q "CLAUDE.md ≤ 60 lines" "$agents_file" || {
  echo "FAIL: new rule not picked up on regen"; exit 1;
}
echo "PASS: new rule auto-picked-up on regen"

# Compiler integration: when a harness has canonical .claude/source files and
# core/scripts/harness_compile.py, codex-home-prepare must delegate AGENTS.md
# generation to the compiler so the Codex runtime gets the XML contract first.
TEST_HARNESS_COMP="$TEST_TEMP/fake-harness-compiler"
mkdir -p "$TEST_HARNESS_COMP/.claude/source" \
         "$TEST_HARNESS_COMP/.claude/rules" \
         "$TEST_HARNESS_COMP/core/scripts"
echo "# compiler harness" > "$TEST_HARNESS_COMP/CLAUDE.md"
[[ -n "$REPO_ROOT" ]] || { echo "FAIL: harness repo root with core/scripts/harness_compile.py not found"; exit 1; }
cp "$REPO_ROOT/core/scripts/harness_compile.py" "$TEST_HARNESS_COMP/core/scripts/harness_compile.py"
cat > "$TEST_HARNESS_COMP/.claude/source/runtime-contract.yaml" <<'EOF'
runtime_contract:
  id: harness-runtime-v1
  source_of_truth: Claude harness source is canonical. Runtime surfaces are generated.
  forbidden_edits:
    - path: .harness/codex/**
      reason: Generated Codex adapter layer.
  before_work:
    - Read relevant domain knowledge before repo work.
    - Check cascading update rules before editing.
  completion_gate:
    - Run concrete verification before claiming done.
    - Report failed or skipped verification.
EOF
cat > "$TEST_HARNESS_COMP/.claude/source/budgets.yaml" <<'EOF'
budgets:
  claude_md_max_lines: 80
  always_on_total_max_lines: 160
  codex_agents_max_bytes: 32768
  skill_md_max_bytes: 10000
EOF
cat > "$TEST_HARNESS_COMP/.claude/rules/cascading-updates.md" <<'EOF'
# Cascading Updates

compiler cascading rule body
EOF
cat > "$TEST_HARNESS_COMP/.claude/rules/runtime-contract.md" <<'EOF'
stale generated runtime duplicate should be skipped
EOF
cat > "$TEST_HARNESS_COMP/.claude/rules/_index.md" <<'EOF'
compiler index should be skipped
EOF

"$PREPARE" "$TEST_HARNESS_COMP"
compiler_agents="$TEST_HARNESS_COMP/.harness/codex/AGENTS.md"
[[ -f "$compiler_agents" && ! -L "$compiler_agents" ]] || {
  echo "FAIL: compiler AGENTS.md should be real generated file"; exit 1;
}
grep -q "Generated by harness_compile.py" "$compiler_agents" || {
  echo "FAIL: compiler AGENTS.md missing compiler header"; exit 1;
}
grep -q '<runtime_contract id="harness-runtime-v1">' "$compiler_agents" || {
  echo "FAIL: compiler AGENTS.md missing XML runtime contract"; exit 1;
}
grep -q "compiler cascading rule body" "$compiler_agents" || {
  echo "FAIL: compiler AGENTS.md missing non-runtime rule body"; exit 1;
}
if grep -q "compiler index should be skipped" "$compiler_agents"; then
  echo "FAIL: compiler AGENTS.md should skip _index.md"; exit 1;
fi
if grep -q "stale generated runtime duplicate" "$compiler_agents"; then
  echo "FAIL: compiler AGENTS.md should skip generated runtime-contract.md rule"; exit 1;
fi
runtime_count=$(grep -c '<runtime_contract id=' "$compiler_agents")
[[ "$runtime_count" == "1" ]] || {
  echo "FAIL: compiler AGENTS.md should include runtime contract once, got $runtime_count"; exit 1;
}
echo "PASS: codex-home-prepare delegates AGENTS.md generation to harness compiler"

# Migration from legacy symlink layout: if AGENTS.md exists as symlink AND
# rules now exist, we must replace it with the generated file.
TEST_HARNESS_M="$TEST_TEMP/fake-harness-migrate"
mkdir -p "$TEST_HARNESS_M/.harness/codex" "$TEST_HARNESS_M/.claude/rules"
echo "# rules" > "$TEST_HARNESS_M/CLAUDE.md"
ln -s "../../CLAUDE.md" "$TEST_HARNESS_M/.harness/codex/AGENTS.md"
echo "# fresh rule" > "$TEST_HARNESS_M/.claude/rules/r1.md"
[[ -L "$TEST_HARNESS_M/.harness/codex/AGENTS.md" ]] || { echo "FAIL: migration setup precondition"; exit 1; }
"$PREPARE" "$TEST_HARNESS_M"
[[ ! -L "$TEST_HARNESS_M/.harness/codex/AGENTS.md" ]] || {
  echo "FAIL: legacy symlink not replaced on migration"; exit 1;
}
grep -q "fresh rule" "$TEST_HARNESS_M/.harness/codex/AGENTS.md" || {
  echo "FAIL: migrated AGENTS.md missing rule content"; exit 1;
}
echo "PASS: legacy AGENTS.md symlink migrates to generated file"

# Commands → Codex skills: portable orchestration commands (no Claude-state
# dependency) become skills under $CODEX_HOME/skills/ with explicit-invocation
# policy. Claude-coupled commands (auto-pilot, cost-analysis, ralph) are
# skipped so we don't ship dead config.
TEST_HARNESS_C="$TEST_TEMP/fake-harness-cmds"
mkdir -p "$TEST_HARNESS_C/.claude/commands"
echo "# rules" > "$TEST_HARNESS_C/CLAUDE.md"

# Portable: pure orchestration, no Claude refs
cat > "$TEST_HARNESS_C/.claude/commands/daily-pipeline.md" <<'EOF'
---
description: Run daily workflow in sequence
---
# Daily Pipeline

Run daily-sync → worklog → slack-format.

<command_contract>
  <completion_gate>Run daily workflow only after prerequisites pass.</completion_gate>
</command_contract>
EOF

# Skipped: references CLAUDE_PROJECT_DIR (Claude-coupled)
cat > "$TEST_HARNESS_C/.claude/commands/auto-pilot.md" <<'EOF'
---
description: Toggle auto-pilot
---
Read $CLAUDE_PROJECT_DIR/core/bin/auto-pilot.sh
Marker: ~/.claude/.auto-pilot-active-$PPID
EOF

# Skipped: invokes Claude Skill tool
cat > "$TEST_HARNESS_C/.claude/commands/ralph.md" <<'EOF'
---
description: Ralph wrapper
---
Skill(skill="ralph-loop:ralph-loop", args="...")
EOF

# Skipped: _index
cat > "$TEST_HARNESS_C/.claude/commands/_index.md" <<'EOF'
# Commands index
EOF

"$PREPARE" "$TEST_HARNESS_C"
skills_out="$TEST_HARNESS_C/.harness/codex/skills"

[[ -d "$skills_out/daily-pipeline" ]] || { echo "FAIL: portable command not converted to skill"; exit 1; }
[[ -f "$skills_out/daily-pipeline/SKILL.md" ]] || { echo "FAIL: SKILL.md missing for daily-pipeline"; exit 1; }
grep -q "^name: daily-pipeline" "$skills_out/daily-pipeline/SKILL.md" || { echo "FAIL: SKILL.md frontmatter name"; exit 1; }
grep -q "Run daily-sync" "$skills_out/daily-pipeline/SKILL.md" || { echo "FAIL: SKILL.md body content"; exit 1; }
grep -q "<execution_policy>" "$skills_out/daily-pipeline/SKILL.md" || { echo "FAIL: command contract was not converted to skill execution policy"; exit 1; }
if grep -q "<command_contract>" "$skills_out/daily-pipeline/SKILL.md"; then
  echo "FAIL: command contract leaked into generated skill"; exit 1;
fi
echo "PASS: portable command → SKILL.md generated"

# Explicit-only invocation policy
[[ -f "$skills_out/daily-pipeline/agents/openai.yaml" ]] || { echo "FAIL: agents/openai.yaml missing"; exit 1; }
grep -q "allow_implicit_invocation: false" "$skills_out/daily-pipeline/agents/openai.yaml" || {
  echo "FAIL: explicit-invocation policy missing"; exit 1;
}
echo "PASS: command-skill marked explicit-invocation only"

# Claude-coupled commands must NOT be converted
[[ ! -d "$skills_out/auto-pilot" ]] || { echo "FAIL: Claude-coupled auto-pilot was wrongly converted"; exit 1; }
[[ ! -d "$skills_out/ralph" ]] || { echo "FAIL: Claude-coupled ralph was wrongly converted"; exit 1; }
[[ ! -d "$skills_out/_index" ]] || { echo "FAIL: _index.md should be skipped"; exit 1; }
echo "PASS: Claude-coupled commands skipped (auto-pilot, ralph, _index)"

# Removing source command must drop generated skill
rm "$TEST_HARNESS_C/.claude/commands/daily-pipeline.md"
"$PREPARE" "$TEST_HARNESS_C"
[[ ! -d "$skills_out/daily-pipeline" ]] || { echo "FAIL: removed command's skill not cleaned up"; exit 1; }
echo "PASS: removing source command drops generated skill"

# ---------------------------------------------------------------------------
# Claude plugin cache merge: ~/.claude/plugins/cache/<mp>/<plugin>/<version>/
# skills must be linked into $CODEX_HOME/skills, newest version auto-resolved.
# ---------------------------------------------------------------------------
CPLUG="$FAKE_HOME/.claude/plugins/cache"

# Single-skill plugin: SKILL.md at version root. Two versions present; newest wins.
mkdir -p "$CPLUG/vid-mp/watchx/0.9.0" "$CPLUG/vid-mp/watchx/0.10.0"
cat > "$CPLUG/vid-mp/watchx/0.9.0/SKILL.md" <<'EOF'
---
name: watchx
description: old
---
old body
EOF
cat > "$CPLUG/vid-mp/watchx/0.10.0/SKILL.md" <<'EOF'
---
name: watchx
description: new
---
new body
EOF

# Multi-skill plugin: skills/<name>/SKILL.md under the version dir.
mkdir -p "$CPLUG/multi-mp/bundle/2.0.0/skills/alpha" \
         "$CPLUG/multi-mp/bundle/2.0.0/skills/beta"
cat > "$CPLUG/multi-mp/bundle/2.0.0/skills/alpha/SKILL.md" <<'EOF'
---
name: alpha
description: a
---
a
EOF
cat > "$CPLUG/multi-mp/bundle/2.0.0/skills/beta/SKILL.md" <<'EOF'
---
name: beta
description: b
---
b
EOF

# Stale version-pin self-heal regression: a dangling manual link in ~/.codex/skills
# pointing at a now-missing version must not survive as a broken link; the engine
# must produce a working link to the current version instead.
mkdir -p "$CPLUG/pin-mp/pinned/1.2.0"
cat > "$CPLUG/pin-mp/pinned/1.2.0/SKILL.md" <<'EOF'
---
name: pinned
description: p
---
p
EOF
mkdir -p "$FAKE_HOME/.codex/skills"
ln -sfn "$CPLUG/pin-mp/pinned/1.0.0" "$FAKE_HOME/.codex/skills/pinned"  # dangling (1.0.0 absent)

HOME="$FAKE_HOME" HARNESS_CODEX_BUNDLED_MARKETPLACE_SOURCE="$FAKE_HOME/.codex/.tmp/bundled-marketplaces/openai-bundled" "$PREPARE" "$FAKE_HARNESS_S"

# 1. Single-skill plugin linked, resolving to the NEWEST version (0.10.0 > 0.9.0).
[[ -L "$SKILLS_OUT/watchx" ]] || { echo "FAIL: watchx symlink missing"; exit 1; }
[[ -f "$SKILLS_OUT/watchx/SKILL.md" ]] || { echo "FAIL: watchx resolves to file"; exit 1; }
grep -q "new body" "$SKILLS_OUT/watchx/SKILL.md" || { echo "FAIL: watchx not pointing at newest version (sort -V)"; exit 1; }
echo "PASS: Claude-plugin single-skill merged at newest version"

# 2. Multi-skill plugin: both skills linked.
[[ -f "$SKILLS_OUT/alpha/SKILL.md" ]] || { echo "FAIL: multi-skill alpha not linked"; exit 1; }
[[ -f "$SKILLS_OUT/beta/SKILL.md" ]] || { echo "FAIL: multi-skill beta not linked"; exit 1; }
echo "PASS: Claude-plugin multi-skill merged"

# 3. Stale manual pin self-heals: pinned resolves to a real SKILL.md (current version).
[[ -f "$SKILLS_OUT/pinned/SKILL.md" ]] || { echo "FAIL: stale version pin did not self-heal"; exit 1; }
echo "PASS: stale Claude-plugin version pin self-healed"

echo "✓ All codex-home-prepare tests passed"
