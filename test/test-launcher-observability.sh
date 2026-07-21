#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ALIASES="$ROOT/bin/aliases.zsh"
LAUNCHER="$ROOT/bin/launcher.sh"

for file in "$ALIASES" "$LAUNCHER"; do
  grep -q 'OTEL_LOGS_EXPORTER=otlp OTEL_TRACES_EXPORTER=none' "$file" || {
    echo "FAIL: Claude metadata logs must be enabled while traces stay disabled in $(basename "$file")" >&2
    exit 1
  }
  grep -q 'OTEL_LOG_USER_PROMPTS=0 OTEL_LOG_ASSISTANT_RESPONSES=0' "$file" || {
    echo "FAIL: prompt/response logging must stay disabled in $(basename "$file")" >&2
    exit 1
  }
  grep -q 'OTEL_LOG_TOOL_DETAILS=0 OTEL_LOG_TOOL_CONTENT=0 OTEL_LOG_RAW_API_BODIES=0' "$file" || {
    echo "FAIL: tool/body content logging must stay disabled in $(basename "$file")" >&2
    exit 1
  }
done

echo 'PASS: Claude exports metadata-only logs and metrics without traces or content'
