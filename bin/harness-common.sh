#!/usr/bin/env bash
# harness-common.sh — single source of truth shared by launcher.sh (bash) and
# aliases.zsh (zsh). Everything here must stay in the bash-3.2 ∩ zsh subset:
# no associative arrays, no ${var,,}, no bash-only ${!arr[@]}, no zsh-only print.
#
# Contents:
#   harness_mode_resolve <mode> <provider>   → HARNESS_MODE_MODEL / HARNESS_MODE_EFFORT
#   harness_mode_label   <mode> <provider>   → display label derived from resolve
#   harness_codex_bin_resolve / harness_kiro_bin_resolve
#   harness_probe_health <url>
#   harness_export_local_env <harness-dir>
#   harness_autocompact_pct <provider> <arg>...
#   harness_mcp_local_configs / harness_validate_mcp_local_configs <harness-dir>
#   harness_ultracode_hint

HARNESS_CODEX_APP_BIN_DEFAULT="/Applications/Codex.app/Contents/Resources/codex"

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
# Kiro CLI takes literal model IDs; shared by the TUI menu and `kh kiro-cli`.
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

# --- per-harness env ------------------------------------------------------------
# Export MCP secrets from .claude/settings.local.json env so gateway/native
# runtimes resolve bearer_token_env_var etc. (they inherit no other harness env).
harness_export_local_env() {
  local harness_dir="$1" _mk _mv
  [ -f "$harness_dir/.claude/settings.local.json" ] || return 0
  while IFS=$'\t' read -r _mk _mv; do
    [ -n "$_mk" ] && export "$_mk=$_mv"
  done < <(python3 - "$harness_dir/.claude/settings.local.json" 2>/dev/null <<'PY'
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
  set --
  [ -f "$harness_dir/.mcp.json" ] && set -- "$@" "$harness_dir/.mcp.json"
  [ -f "$harness_dir/.mcp.local.json" ] && set -- "$@" "$harness_dir/.mcp.local.json"
  [ -f "$harness_dir/mcp.local.json" ] && set -- "$@" "$harness_dir/mcp.local.json"
  [ "$#" -gt 1 ] || return 0
  python3 - "$@" <<'PY'
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

# --- shared user-facing strings ---------------------------------------------------
harness_ultracode_hint() {
  printf '💡 ultracode는 세션 전용입니다 — 시작 후 /effort 에서 ultracode를 선택하면 워크플로우 오케스트레이션이 켜집니다 (지금은 opus[1m] + xhigh로 시작).\n' >&2
}
