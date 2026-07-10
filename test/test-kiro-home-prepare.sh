#!/usr/bin/env zsh
# test-kiro-home-prepare.sh — verify kiro-home-prepare.sh side effects.
#
# Regression guard: the harness agent MUST carry the merged MCP servers inline.
# A prior bug generated harness.json with "mcpServers": {} + useLegacyMcpJson:
# false, so `kiro-cli chat --agent harness` saw zero MCP servers even though
# settings/mcp.json was populated correctly.

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LAUNCHER_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
PREPARE="$LAUNCHER_DIR/bin/kiro-home-prepare.sh"

cleanup() {
  [[ -n "${TEST_TEMP:-}" && -d "$TEST_TEMP" ]] && rm -rf "$TEST_TEMP"
}
trap cleanup EXIT

[[ -x "$PREPARE" ]] || { echo "FAIL: $PREPARE missing or not executable"; exit 1; }

TEST_TEMP="$(mktemp -d)"
TEST_HARNESS="$TEST_TEMP/fake-harness"
mkdir -p "$TEST_HARNESS/core/hooks"

cat > "$TEST_HARNESS/CLAUDE.md" <<'EOF'
# Fake harness rules
EOF

# Committed servers (shared)
cat > "$TEST_HARNESS/.mcp.json" <<'EOF'
{
  "mcpServers": {
    "atlassian": { "type": "http", "url": "http://localhost:38100/mcp" },
    "context7": { "command": "npx", "args": ["-y", "@upstash/context7-mcp"] }
  }
}
EOF

# First local overlay is loaded alongside the committed config.
cat > "$TEST_HARNESS/.mcp.local.json" <<'EOF'
{
  "mcpServers": {
    "local-docs": { "command": "npx", "args": ["-y", "@example/docs-mcp"] }
  }
}
EOF

# Second local overlay is also loaded.
cat > "$TEST_HARNESS/mcp.local.json" <<'EOF'
{
  "mcpServers": {
    "harness-rag": { "command": "ssh", "args": ["host", "serve-mcp"] }
  }
}
EOF

"$PREPARE" "$TEST_HARNESS"

KIRO_HOME="$TEST_HARNESS/.harness/kiro"
FAIL=0

# ─── settings output ──────────────────────────────────────────────────────────
cli_settings="$KIRO_HOME/settings/cli.json"
[[ -f "$cli_settings" ]] || { echo "FAIL: settings/cli.json missing"; exit 1; }

# ─── settings/mcp.json: merged + type field ──────────────────────────────────
mcp_settings="$KIRO_HOME/settings/mcp.json"
[[ -f "$mcp_settings" ]] || { echo "FAIL: settings/mcp.json missing"; exit 1; }
settings_count=$(python3 -c "import json;print(len(json.load(open('$mcp_settings'))['mcpServers']))")
[[ "$settings_count" == "4" ]] || { echo "FAIL: settings/mcp.json should merge 4 servers, got $settings_count"; FAIL=1; }
# stdio type inferred for command-only entries
python3 -c "import json,sys; d=json.load(open('$mcp_settings'))['mcpServers']; sys.exit(0 if d['harness-rag'].get('type')=='stdio' else 1)" \
  || { echo "FAIL: harness-rag should get type=stdio"; FAIL=1; }
echo "PASS: settings/mcp.json merges committed + local servers with type field"

# ─── agents/harness.json: MCP inlined (regression) ───────────────────────────
agent="$KIRO_HOME/agents/harness.json"
[[ -f "$agent" ]] || { echo "FAIL: agents/harness.json missing"; exit 1; }

agent_count=$(python3 -c "import json;print(len(json.load(open('$agent')).get('mcpServers',{})))")
[[ "$agent_count" == "4" ]] || {
  echo "FAIL: harness agent must inline all 4 merged MCP servers, got $agent_count"
  echo "      (empty mcpServers + useLegacyMcpJson:false = agent sees zero MCP)"
  FAIL=1
}

# The inlined set must equal the merged settings set exactly
python3 - "$agent" "$mcp_settings" <<'PY' || FAIL=1
import json, sys
agent = json.load(open(sys.argv[1])).get("mcpServers", {})
settings = json.load(open(sys.argv[2])).get("mcpServers", {})
if set(agent) != set(settings):
    print(f"FAIL: agent MCP set {sorted(agent)} != settings set {sorted(settings)}")
    sys.exit(1)
PY
echo "PASS: harness agent inlines the merged MCP servers"

# Duplicate names across committed and local inputs must fail instead of letting
# a local machine silently replace a committed endpoint. Existing generated
# settings and agent files must remain byte-identical after rejection. Make the
# CLI settings intentionally stale to prove validation happens before *any*
# generated output is written.
printf '{"stale": true}\n' > "$cli_settings"
cp "$cli_settings" "$TEST_TEMP/cli-settings.before.json"
cp "$mcp_settings" "$TEST_TEMP/mcp-settings.before.json"
cp "$agent" "$TEST_TEMP/harness-agent.before.json"
cat > "$TEST_HARNESS/mcp.local.json" <<'EOF'
{
  "mcpServers": {
    "atlassian": { "command": "echo", "args": ["shadowed"] }
  }
}
EOF
set +e
"$PREPARE" "$TEST_HARNESS" >"$TEST_TEMP/duplicate-mcp.log" 2>&1
duplicate_rc=$?
set -e
[[ "$duplicate_rc" -ne 0 ]] || {
  echo "FAIL: Kiro preparation accepted a duplicate local MCP server name"
  FAIL=1
}
grep -q "duplicate MCP server 'atlassian'" "$TEST_TEMP/duplicate-mcp.log" || {
  echo "FAIL: duplicate Kiro MCP rejection did not identify the server"
  FAIL=1
}
cmp -s "$TEST_TEMP/cli-settings.before.json" "$cli_settings" || {
  echo "FAIL: duplicate rejection changed existing generated CLI settings"
  FAIL=1
}
cmp -s "$TEST_TEMP/mcp-settings.before.json" "$mcp_settings" || {
  echo "FAIL: duplicate rejection changed the existing generated MCP settings"
  FAIL=1
}
cmp -s "$TEST_TEMP/harness-agent.before.json" "$agent" || {
  echo "FAIL: duplicate rejection changed the existing generated agent"
  FAIL=1
}
echo "PASS: Kiro preparation rejects duplicates without changing generated output"

# A fresh harness with duplicate MCP names must not gain a generated Kiro home,
# including hidden temporary files, when validation rejects the configuration.
FRESH_HARNESS="$TEST_TEMP/fresh-duplicate-harness"
mkdir -p "$FRESH_HARNESS"
cat > "$FRESH_HARNESS/.mcp.json" <<'EOF'
{"mcpServers":{"committed":{"command":"echo"}}}
EOF
cat > "$FRESH_HARNESS/mcp.local.json" <<'EOF'
{"mcpServers":{"committed":{"command":"echo","args":["shadowed"]}}}
EOF
set +e
"$PREPARE" "$FRESH_HARNESS" >"$TEST_TEMP/fresh-duplicate-mcp.log" 2>&1
fresh_duplicate_rc=$?
set -e
[[ "$fresh_duplicate_rc" -ne 0 ]] || {
  echo "FAIL: fresh Kiro preparation accepted a duplicate MCP server name"
  FAIL=1
}
grep -q "duplicate MCP server 'committed'" "$TEST_TEMP/fresh-duplicate-mcp.log" || {
  echo "FAIL: fresh duplicate rejection did not identify the server"
  FAIL=1
}
[[ ! -e "$FRESH_HARNESS/.harness" ]] || {
  echo "FAIL: fresh duplicate rejection created generated Kiro state"
  FAIL=1
}
echo "PASS: fresh duplicate rejection creates no generated Kiro state"

# ─── Summary ─────────────────────────────────────────────────────────────────
if [[ $FAIL -gt 0 ]]; then
  echo "Results: FAILED"
  exit 1
fi
echo "✓ All kiro-home-prepare tests passed"
