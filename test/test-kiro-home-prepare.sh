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

# Local servers (gitignored) — e.g. RAG over ssh
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

# ─── settings/mcp.json: merged + type field ──────────────────────────────────
mcp_settings="$KIRO_HOME/settings/mcp.json"
[[ -f "$mcp_settings" ]] || { echo "FAIL: settings/mcp.json missing"; exit 1; }
settings_count=$(python3 -c "import json;print(len(json.load(open('$mcp_settings'))['mcpServers']))")
[[ "$settings_count" == "3" ]] || { echo "FAIL: settings/mcp.json should merge 3 servers, got $settings_count"; FAIL=1; }
# stdio type inferred for command-only entries
python3 -c "import json,sys; d=json.load(open('$mcp_settings'))['mcpServers']; sys.exit(0 if d['harness-rag'].get('type')=='stdio' else 1)" \
  || { echo "FAIL: harness-rag should get type=stdio"; FAIL=1; }
echo "PASS: settings/mcp.json merges committed + local servers with type field"

# ─── agents/harness.json: MCP inlined (regression) ───────────────────────────
agent="$KIRO_HOME/agents/harness.json"
[[ -f "$agent" ]] || { echo "FAIL: agents/harness.json missing"; exit 1; }

agent_count=$(python3 -c "import json;print(len(json.load(open('$agent')).get('mcpServers',{})))")
[[ "$agent_count" == "3" ]] || {
  echo "FAIL: harness agent must inline all 3 merged MCP servers, got $agent_count"
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

# ─── Summary ─────────────────────────────────────────────────────────────────
if [[ $FAIL -gt 0 ]]; then
  echo "Results: FAILED"
  exit 1
fi
echo "✓ All kiro-home-prepare tests passed"
