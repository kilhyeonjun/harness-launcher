#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

HOME_FAKE="$TMP/home"
HARNESS="$TMP/harness"
mkdir -p "$HOME_FAKE" "$HARNESS"

cat > "$HOME_FAKE/.claude.json" <<'JSON'
{
  "mcpServers": {
    "glider": {
      "type": "stdio",
      "command": "/usr/local/bin/glider",
      "args": ["mcp", "serve"]
    }
  }
}
JSON

cat > "$HARNESS/.mcp.json" <<'JSON'
{
  "mcpServers": {
    "context7": {
      "command": "npx",
      "args": ["-y", "@upstash/context7-mcp"]
    }
  }
}
JSON

output="$(
  HOME="$HOME_FAKE" bash "$ROOT/bin/codex-home-prepare.sh" "$HARNESS" 2>&1 >/dev/null
)"

if printf '%s\n' "$output" | grep -q 'WARN: Claude global MCP server not declared in harness .mcp.json: glider'; then
  echo "FAIL: global MCP drift warning should be opt-in"
  printf '%s\n' "$output"
  exit 1
fi

output="$(
  HOME="$HOME_FAKE" HARNESS_CODEX_WARN_CLAUDE_GLOBAL_MCP_DRIFT=1 \
    bash "$ROOT/bin/codex-home-prepare.sh" "$HARNESS" 2>&1 >/dev/null
)"

printf '%s\n' "$output" | grep -q 'WARN: Claude global MCP server not declared in harness .mcp.json: glider' \
  || { echo "FAIL: missing opt-in global MCP drift warning"; printf '%s\n' "$output"; exit 1; }

grep -q '^\[mcp_servers.context7\]' "$HARNESS/.harness/codex/config.toml" \
  || { echo "FAIL: harness MCP missing from generated config"; exit 1; }

if grep -q '^\[mcp_servers.glider\]' "$HARNESS/.harness/codex/config.toml"; then
  echo "FAIL: global glider must not be auto-imported into Codex config"
  exit 1
fi

echo "PASS: global MCP drift warning is opt-in and never auto-imports global servers"
