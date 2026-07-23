#!/usr/bin/env bash
# harness-common.sh — single source of truth shared by launcher.sh (bash) and
# aliases.zsh (zsh). Everything here must stay in the bash-3.2 ∩ zsh subset:
# no associative arrays, no ${var,,}, no bash-only ${!arr[@]}, no zsh-only print.
#
# Contents:
#   harness_resolve_run_dir <harness-dir> <requested-dir>
#   harness_mode_resolve <mode> <provider>   → HARNESS_MODE_MODEL / HARNESS_MODE_EFFORT
#   harness_mode_label   <mode> <provider>   → display label derived from resolve
#   harness_codex_bin_resolve / harness_kiro_bin_resolve
#   harness_probe_health <url>
#   harness_export_local_env <harness-dir>
#   harness_autocompact_pct <provider> <arg>...
#   harness_mcp_local_configs / harness_validate_mcp_local_configs <harness-dir>
#   harness_ultracode_hint

HARNESS_CODEX_APP_BIN_DEFAULT="/Applications/Codex.app/Contents/Resources/codex"

harness_resolve_run_dir() {
  local harness_dir="$1" requested="$2" harness_abs requested_abs
  [ -d "$requested" ] || {
    echo "harness-launcher: --cwd is not a directory: $requested" >&2
    return 2
  }
  harness_abs="$(cd -P "$harness_dir" 2>/dev/null && pwd -P)" || return 2
  requested_abs="$(cd -P "$requested" 2>/dev/null && pwd -P)" || return 2
  case "$requested_abs" in
    "$harness_abs"|"$harness_abs"/*) printf '%s\n' "$requested_abs" ;;
    *)
      echo "harness-launcher: --cwd must stay inside the registered harness: $harness_abs" >&2
      return 2
      ;;
  esac
}

harness_python3_resolve() {
  local candidate
  if [ -n "${HARNESS_PYTHON_BIN:-}" ]; then
    candidate="$HARNESS_PYTHON_BIN"
    [ -x "$candidate" ] && "$candidate" -c 'import sys; raise SystemExit(sys.version_info < (3, 11))' 2>/dev/null && {
      printf '%s\n' "$candidate"
      return 0
    }
  else
    for candidate in \
      /opt/homebrew/opt/python@3.13/libexec/bin/python3 \
      /usr/local/opt/python@3.13/libexec/bin/python3 \
      /opt/homebrew/bin/python3 \
      /usr/local/bin/python3 \
      "$(command -v python3 2>/dev/null || true)"; do
      [ -n "$candidate" ] && [ -x "$candidate" ] || continue
      "$candidate" -c 'import sys; raise SystemExit(sys.version_info < (3, 11))' 2>/dev/null || continue
      printf '%s\n' "$candidate"
      return 0
    done
  fi
  echo "ERROR: harness-launcher requires Python 3.11 or newer (set HARNESS_PYTHON_BIN)" >&2
  return 1
}

# --- mode → model/effort table -------------------------------------------------
# The ONLY place mode/provider → model/effort lives. Labels are derived from
# this resolution so a label can never disagree with the launched model again.
# provider: direct | kiro | codex   (claude-runtime providers)
harness_mode_resolve() {
  local mode="$1" provider="${2:-direct}"
  HARNESS_MODE_MODEL=""
  HARNESS_MODE_EFFORT=""
  case "$mode" in
    fast)
      HARNESS_MODE_MODEL="haiku"; HARNESS_MODE_EFFORT="low" ;;
    base)
      case "$provider" in
        kiro)  HARNESS_MODE_MODEL="sonnet[1m]" ;;
        codex) HARNESS_MODE_MODEL="sonnet${CODEX_CONTEXT_SUFFIX:-}" ;;
        *)     HARNESS_MODE_MODEL="sonnet" ;;
      esac
      HARNESS_MODE_EFFORT="high" ;;
    plan)
      case "$provider" in
        kiro)  HARNESS_MODE_MODEL="opusplan[1m]" ;;
        codex) HARNESS_MODE_MODEL="opusplan${CODEX_CONTEXT_SUFFIX:-}" ;;
        *)     HARNESS_MODE_MODEL="opusplan" ;;
      esac
      HARNESS_MODE_EFFORT="high" ;;
    rich)
      case "$provider" in
        kiro)  HARNESS_MODE_MODEL="claude-opus-4-6[1m]"; HARNESS_MODE_EFFORT="max" ;;
        codex) HARNESS_MODE_MODEL="opus${CODEX_CONTEXT_SUFFIX:-}"; HARNESS_MODE_EFFORT="high" ;;
        *)     HARNESS_MODE_MODEL="opus[1m]"; HARNESS_MODE_EFFORT="xhigh" ;;
      esac ;;
    ultracode)
      # Anthropic direct only; orchestration half is session-only (/effort).
      [ "$provider" = "direct" ] || return 1
      HARNESS_MODE_MODEL="opus[1m]"; HARNESS_MODE_EFFORT="xhigh" ;;
    *) return 1 ;;
  esac
  return 0
}

# Display label derived from the live resolution (drift-proof by construction).
harness_mode_label() {
  local mode="$1" provider="${2:-direct}" icon=""
  harness_mode_resolve "$mode" "$provider" || return 1
  case "$mode" in
    fast)      icon="⚡ Fast" ;;
    base)      icon="⚖️  Base" ;;
    plan)      icon="🗺️  Plan" ;;
    rich)      icon="🧠 Rich" ;;
    ultracode) icon="🌀 Ultracode" ;;
  esac
  printf '%s — %s · %s\n' "$icon" "$HARNESS_MODE_MODEL" "$HARNESS_MODE_EFFORT"
}

# --- kiro-native mode table -------------------------------------------------
# Kiro CLI takes literal model IDs; shared by the TUI menu and `<prefix> kiro-cli`.
harness_kiro_mode_resolve() {
  local mode="$1"
  HARNESS_KIRO_MODEL=""
  HARNESS_KIRO_EFFORT=""
  case "$mode" in
    fast) HARNESS_KIRO_MODEL="claude-haiku-4.5";  HARNESS_KIRO_EFFORT="low" ;;
    base) HARNESS_KIRO_MODEL="claude-sonnet-4.6"; HARNESS_KIRO_EFFORT="high" ;;
    plan) HARNESS_KIRO_MODEL="claude-opus-4.6";   HARNESS_KIRO_EFFORT="high" ;;
    rich) HARNESS_KIRO_MODEL="claude-opus-4.6";   HARNESS_KIRO_EFFORT="max" ;;
    *) return 1 ;;
  esac
  return 0
}

harness_kiro_mode_label() {
  local mode="$1" icon=""
  harness_kiro_mode_resolve "$mode" || return 1
  case "$mode" in
    fast) icon="⚡ Fast" ;;
    base) icon="⚖️  Base" ;;
    plan) icon="🗺️  Plan" ;;
    rich) icon="🧠 Rich" ;;
  esac
  printf '%s — %s · %s\n' "$icon" "$HARNESS_KIRO_MODEL" "$HARNESS_KIRO_EFFORT"
}

# --- binary resolution ----------------------------------------------------------
# Path-only lookup: `command -v` in zsh reports shell functions too, and
# aliases.zsh defines a codex() wrapper — resolving through it would recurse
# forever. whence -p (zsh) / type -P (bash) only ever return filesystem paths.
harness_path_lookup() {
  if [ -n "${ZSH_VERSION:-}" ]; then
    whence -p "$1" 2>/dev/null
  else
    type -P "$1" 2>/dev/null
  fi
}

harness_codex_bin_resolve() {
  local configured="${HARNESS_CODEX_BIN:-}"
  if [ -n "$configured" ]; then
    if [ -x "$configured" ]; then
      printf '%s\n' "$configured"
      return 0
    fi
    harness_path_lookup "$configured"
    return $?
  fi
  if harness_path_lookup codex; then
    return 0
  fi
  local app_bin="${_HARNESS_CODEX_APP_BIN:-$HARNESS_CODEX_APP_BIN_DEFAULT}"
  if [ "${HARNESS_CODEX_ALLOW_APP_FALLBACK:-0}" = "1" ] && [ -x "$app_bin" ]; then
    printf '%s\n' "$app_bin"
    return 0
  fi
  return 1
}

# Keep the title watcher below a live launcher/Codex ancestor. cmux authorizes
# terminal callers through process ancestry, so a watcher orphaned by a
# short-lived SessionStart hook cannot rename the target tab.
harness_codex_cmux_broker_start() {
  local helper="$1" state_dir request_file
  harness_codex_cmux_broker_stop
  [ -x "$helper" ] || return 0
  [ -n "${CODEX_HOME:-}" ] || return 0
  [ -n "${CMUX_WORKSPACE_ID:-}" ] || return 0
  [ -n "${CMUX_TAB_ID:-}" ] || return 0
  [ -n "${CMUX_SURFACE_ID:-}" ] || return 0
  case "${HARNESS_PREFIX:-}" in
    ''|[0-9-]*|*[!A-Za-z0-9_-]*) return 0 ;;
  esac

  state_dir="${CODEX_CMUX_TITLE_STATE_DIR:-$CODEX_HOME/.cmux-title-sync}"
  mkdir -p "$state_dir" 2>/dev/null || return 0
  chmod 700 "$state_dir" 2>/dev/null || return 0
  request_file="$(mktemp "$state_dir/request.XXXXXX")" || return 0
  chmod 600 "$request_file" 2>/dev/null || {
    rm -f "$request_file"
    return 0
  }

  export CODEX_CMUX_TITLE_REQUEST_FILE="$request_file"
  HARNESS_CODEX_CMUX_BROKER_REQUEST="$request_file"
  "$helper" --broker "$request_file" "$CMUX_SURFACE_ID" "$HARNESS_PREFIX" "$CODEX_HOME" "$$" </dev/null >/dev/null 2>&1 &
  HARNESS_CODEX_CMUX_BROKER_PID=$!
  return 0
}

harness_codex_cmux_broker_stop() {
  if [ -n "${HARNESS_CODEX_CMUX_BROKER_PID:-}" ]; then
    kill "$HARNESS_CODEX_CMUX_BROKER_PID" 2>/dev/null || true
    wait "$HARNESS_CODEX_CMUX_BROKER_PID" 2>/dev/null || true
  fi
  if [ -n "${HARNESS_CODEX_CMUX_BROKER_REQUEST:-}" ]; then
    rm -f "$HARNESS_CODEX_CMUX_BROKER_REQUEST"
  fi
  unset HARNESS_CODEX_CMUX_BROKER_PID
  unset HARNESS_CODEX_CMUX_BROKER_REQUEST
  unset CODEX_CMUX_TITLE_REQUEST_FILE
}

harness_kiro_bin_resolve() {
  local configured="${HARNESS_KIRO_BIN:-}"
  if [ -n "$configured" ]; then
    if [ -x "$configured" ]; then
      printf '%s\n' "$configured"
      return 0
    fi
    harness_path_lookup "$configured"
    return $?
  fi
  harness_path_lookup kiro-cli
}

# --- gateway health -------------------------------------------------------------
harness_probe_health() {
  local provider_url="$1"
  [ -z "$provider_url" ] && return 1
  PROBE_PROVIDER_URL="$provider_url" \
    node -e 'const baseUrl = process.env.PROBE_PROVIDER_URL; const controller = new AbortController(); const timer = setTimeout(() => controller.abort(), 2000); fetch(`${baseUrl}/health`, { signal: controller.signal }).then(() => { clearTimeout(timer); process.exit(0); }).catch(() => { clearTimeout(timer); process.exit(1); });' >/dev/null 2>&1
}

# --- local observability --------------------------------------------------------
# Strict parser: local observability config is data, never sourced as shell code.
# Return 0=enabled, 1=disabled/not configured/invalid (optional telemetry is fail-open).
harness_observability_load() {
  local harness_dir="$1" launcher_file config_file line key value prefix="" seen_keys="" HARNESS_OBSERVABILITY_ENABLED=""
  HARNESS_OBSERVABILITY_ACTIVE=0
  HARNESS_OBSERVABILITY_PROFILE=""
  HARNESS_OTLP_HTTP_ENDPOINT=""

  launcher_file="$harness_dir/config/launcher.env"
  if [ -f "$launcher_file" ]; then
    while IFS= read -r line || [ -n "$line" ]; do
      case "$line" in
        HARNESS_PREFIX=*)
          value="${line#HARNESS_PREFIX=}"
          value="${value#\"}"; value="${value%\"}"
          value="${value#\'}"; value="${value%\'}"
          prefix="$value"
          ;;
      esac
    done < "$launcher_file"
  fi

  case "$prefix" in
    ''|[0-9-]*|*[!A-Za-z0-9_-]*) return 1 ;;
  esac
  config_file="$harness_dir/config/.local/observability.env"
  [ -f "$config_file" ] || return 1

  HARNESS_OBSERVABILITY_ENABLED=""
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      ''|'#'*) continue ;;
      *=*) key="${line%%=*}"; value="${line#*=}" ;;
      *) echo "WARN: invalid observability config line; telemetry disabled" >&2; return 1 ;;
    esac
    case " $seen_keys " in
      *" $key "*) echo "WARN: duplicate observability config key: $key; telemetry disabled" >&2; return 1 ;;
    esac
    seen_keys="$seen_keys $key"
    case "$key" in
      HARNESS_OBSERVABILITY_ENABLED) HARNESS_OBSERVABILITY_ENABLED="$value" ;;
      HARNESS_OTLP_HTTP_ENDPOINT) HARNESS_OTLP_HTTP_ENDPOINT="$value" ;;
      *) echo "WARN: unknown observability config key: $key; telemetry disabled" >&2; return 1 ;;
    esac
  done < "$config_file"

  [ "$HARNESS_OBSERVABILITY_ENABLED" = "1" ] || {
    [ -z "$HARNESS_OBSERVABILITY_ENABLED" ] || [ "$HARNESS_OBSERVABILITY_ENABLED" = "0" ] || {
      echo "WARN: HARNESS_OBSERVABILITY_ENABLED must be 0 or 1; telemetry disabled" >&2
      return 1
    }
    return 1
  }
  [ "$HARNESS_OTLP_HTTP_ENDPOINT" = "http://127.0.0.1:4318" ] || {
    echo "WARN: observability HTTP endpoint must be loopback http://127.0.0.1:4318; telemetry disabled" >&2
    return 1
  }

  HARNESS_OBSERVABILITY_ACTIVE=1
  HARNESS_OBSERVABILITY_PROFILE="$prefix"
  return 0
}

# --- per-harness env ------------------------------------------------------------
# Export MCP secrets from .claude/settings.local.json env so gateway/native
# runtimes resolve bearer_token_env_var etc. (they inherit no other harness env).
harness_export_local_env() {
  local harness_dir="$1"
  local harness_python
  [ -f "$harness_dir/.claude/settings.local.json" ] || return 0
  harness_python="$(harness_python3_resolve)" || return 1
  local _mk _mv
  while IFS=$'\t' read -r _mk _mv; do
    [ -n "$_mk" ] && export "$_mk=$_mv"
  done < <("$harness_python" - "$harness_dir/.claude/settings.local.json" 2>/dev/null <<'PY'
import json, sys
with open(sys.argv[1]) as f:
    env = (json.load(f).get("env") or {})
for k, v in env.items():
    print(k + "\t" + str(v))
PY
)
}

# --- auto-compact PCT -----------------------------------------------------------
# [1m] + codex gateway + GPT-5.5 mapping → PCT=35 (real 400K limit; 35% of the
# fake 1M window = 350K fits). [1m] otherwise → PCT=50. No [1m] → leave unset
# (settings.json fallback applies).
harness_autocompact_pct() {
  local provider="$1" _arg _gpt55=0; shift
  case "${CODEX_OPUS_MODEL:-}" in *5.5*) _gpt55=1 ;; esac
  case "${CODEX_SONNET_MODEL:-}" in *5.5*) _gpt55=1 ;; esac
  for _arg in "$@"; do
    case "$_arg" in
      *"[1m]"*)
        if [ "$provider" = "codex" ] && [ "$_gpt55" = "1" ]; then
          export CLAUDE_AUTOCOMPACT_PCT_OVERRIDE=35
        else
          export CLAUDE_AUTOCOMPACT_PCT_OVERRIDE=50
        fi
        return 0 ;;
    esac
  done
  return 0
}

# --- local MCP configs ----------------------------------------------------------
harness_mcp_local_configs() {
  local harness_dir="$1"
  [ -f "$harness_dir/.mcp.local.json" ] && printf '%s\n' "$harness_dir/.mcp.local.json"
  [ -f "$harness_dir/mcp.local.json" ] && printf '%s\n' "$harness_dir/mcp.local.json"
}

harness_validate_mcp_local_configs() {
  local harness_dir="$1"
  local harness_python
  set --
  [ -f "$harness_dir/.mcp.json" ] && set -- "$@" "$harness_dir/.mcp.json"
  [ -f "$harness_dir/.mcp.local.json" ] && set -- "$@" "$harness_dir/.mcp.local.json"
  [ -f "$harness_dir/mcp.local.json" ] && set -- "$@" "$harness_dir/mcp.local.json"
  [ "$#" -gt 1 ] || return 0
  harness_python="$(harness_python3_resolve)" || return 1
  "$harness_python" - "$@" <<'PY'
import json, sys

seen = {}
for path in sys.argv[1:]:
    try:
        with open(path, encoding="utf-8") as f:
            servers = (json.load(f).get("mcpServers") or {})
    except FileNotFoundError:
        continue
    for name in servers:
        if name in seen:
            print(
                f"ERROR: duplicate MCP server '{name}' in {seen[name]} and {path}; "
                "rename the local server instead of overriding committed .mcp.json",
                file=sys.stderr,
            )
            sys.exit(1)
        seen[name] = path
PY
}

# --- MCP surface (light) ----------------------------------------------------------
# The "light" surface drops SSH-backed MCP servers — the heavy class that
# opens remote connections per session — and keeps everything else. Two shapes
# identify that class:
#   1. stdio wrappers: command "bash" + args[0] containing start-ssh-mcp.sh
#   2. loopback HTTP on the SSH-tunnel port band 38200–38299 (RAG/KG tunnels;
#      documented in domains/knowledge/tools/mcp/ssh-backed-mcp.md)
# Local non-SSH services (e.g. 381xx) and remote https servers stay.
# Used by Claude (--strict-mcp-config) and Kiro (HARNESS_KIRO_MCP_PROFILE=light
# in kiro-home-prepare.sh).
#
# harness_claude_light_mcp_config <harness-dir> → prints generated file path.
# Merges .mcp.json + local overlays, filters the SSH class, writes the result
# under .harness/claude/. Fails (rc 1) on duplicate server names.
harness_claude_light_mcp_config() {
  local harness_dir="$1"
  local out="$harness_dir/.harness/claude/mcp-light.json"
  local harness_python
  mkdir -p "$harness_dir/.harness/claude"
  harness_python="$(harness_python3_resolve)" || return 1
  "$harness_python" - "$harness_dir" "$out" <<'PY' || return 1
import json, os, re, sys

harness_dir, out = sys.argv[1], sys.argv[2]

def is_ssh_backed(spec):
    args = spec.get("args") or []
    if spec.get("command") == "bash" and args and "start-ssh-mcp.sh" in str(args[0]):
        return True
    m = re.match(r"https?://(127\.0\.0\.1|localhost):(\d+)(/|$)", str(spec.get("url") or ""))
    return bool(m) and 38200 <= int(m.group(2)) <= 38299

merged, seen = {}, {}
for name in (".mcp.json", ".mcp.local.json", "mcp.local.json"):
    path = os.path.join(harness_dir, name)
    if not os.path.isfile(path):
        continue
    with open(path, encoding="utf-8") as f:
        servers = (json.load(f).get("mcpServers") or {})
    for srv, spec in servers.items():
        if srv in seen:
            print(
                f"ERROR: duplicate MCP server '{srv}' in {seen[srv]} and {path}; "
                "rename the local server instead of overriding committed .mcp.json",
                file=sys.stderr,
            )
            sys.exit(1)
        seen[srv] = path
        if is_ssh_backed(spec):
            continue  # SSH-backed heavy class — excluded from the light surface
        merged[srv] = spec

# --strict-mcp-config also drops user-scope servers (~/.claude.json), so the
# generated file must carry every non-SSH server the session would otherwise
# have. Harness scope wins on name collisions (mirrors claude's precedence).
user_cfg = os.path.expanduser("~/.claude.json")
if os.path.isfile(user_cfg):
    try:
        with open(user_cfg, encoding="utf-8") as f:
            user_servers = json.load(f).get("mcpServers") or {}
    except (OSError, ValueError):
        user_servers = {}
    for srv, spec in user_servers.items():
        if srv not in seen and not is_ssh_backed(spec):
            merged[srv] = spec

tmp = f"{out}.tmp.{os.getpid()}"
with open(tmp, "w", encoding="utf-8") as f:
    json.dump({"mcpServers": merged}, f, indent=2)
os.replace(tmp, out)
print(out)
PY
}

# --- shared user-facing strings ---------------------------------------------------
harness_ultracode_hint() {
  printf '💡 ultracode는 세션 전용입니다 — 시작 후 /effort 에서 ultracode를 선택하면 워크플로우 오케스트레이션이 켜집니다 (지금은 opus[1m] + xhigh로 시작).\n' >&2
}
