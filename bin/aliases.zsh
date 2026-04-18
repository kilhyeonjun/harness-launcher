#!/usr/bin/env zsh
# harness-launcher — generic zsh launcher function + tab completion
# Usage:
#   source /path/to/harness-launcher/bin/aliases.zsh
#   harness_register /path/to/some-harness

_HARNESS_LAUNCHER_BIN="$(cd "$(dirname "${(%):-%x}")" 2>/dev/null && pwd)"

# harness_register <harness-dir>
#   Reads <dir>/config/launcher.env (HARNESS_NAME, HARNESS_PREFIX),
#   defines the prefix function, wires tab completion.
harness_register() {
  local dir="$1"
  [[ -z "$dir" || ! -d "$dir" ]] && { echo "harness_register: invalid dir: $dir" >&2; return 1; }
  local env_file="$dir/config/launcher.env"
  [[ ! -f "$env_file" ]] && { echo "harness_register: missing $env_file" >&2; return 1; }

  local HARNESS_NAME HARNESS_PREFIX
  source "$env_file"
  [[ -z "$HARNESS_PREFIX" ]] && { echo "harness_register: HARNESS_PREFIX required in $env_file" >&2; return 1; }
  [[ -z "$HARNESS_NAME" ]] && { echo "harness_register: HARNESS_NAME required in $env_file" >&2; return 1; }

  # Define <prefix>() — delegates to generic runner with harness dir
  eval "${HARNESS_PREFIX}() { _harness_launcher_run '$dir' \"\$@\"; }"
  # Define _<prefix>_complete() — delegates to generic completion
  eval "_${HARNESS_PREFIX}_complete() { _harness_launcher_complete '$dir' \"\$@\"; }"
  compdef "_${HARNESS_PREFIX}_complete" "$HARNESS_PREFIX"
}

# _harness_launcher_run <harness-dir> [args...]
#   Mirrors the behavior of the old kh/gd/gp function.
_harness_launcher_run() {
  local HARNESS_DIR="$1"; shift
  local HARNESS_NAME HARNESS_PREFIX
  source "$HARNESS_DIR/config/launcher.env"

  local -a claude_args=()
  local session_flag="" skip_tui=false env_effort="" provider_url="" gateway_api_key="" provider_name=""
  local mode_applied=false

  # Optional provider prefix (must be first arg)
  case "${1:-}" in
    kiro)
      provider_name="kiro"
      local _env_file="$HARNESS_DIR/config/.local/kiro-gateway.env"
      if [[ -f "$_env_file" ]]; then
        source "$_env_file"
        [[ -n "${KIRO_GATEWAY_URL:-}" ]] && provider_url="$KIRO_GATEWAY_URL"
        [[ -n "${KIRO_GATEWAY_API_KEY:-}" ]] && gateway_api_key="$KIRO_GATEWAY_API_KEY"
      fi
      [[ -z "$provider_url" ]] && echo "❌ KIRO_GATEWAY_URL이 설정되지 않았습니다" && return 1
      curl -s --max-time 2 -o /dev/null "${provider_url}/health" >/dev/null 2>&1 \
        || { echo "❌ kiro-gateway에 연결할 수 없습니다 ($provider_url)"; return 1; }
      skip_tui=true; shift ;;
    codex)
      provider_name="codex"
      local _env_file="$HARNESS_DIR/config/.local/codex-gateway.env"
      if [[ -f "$_env_file" ]]; then
        source "$_env_file"
        [[ -n "${CODEX_GATEWAY_URL:-}" ]] && provider_url="$CODEX_GATEWAY_URL"
        [[ -n "${CODEX_GATEWAY_API_KEY:-}" ]] && gateway_api_key="$CODEX_GATEWAY_API_KEY"
      fi
      [[ -z "$provider_url" ]] && echo "❌ CODEX_GATEWAY_URL이 설정되지 않았습니다" && return 1
      curl -s --max-time 2 -o /dev/null "${provider_url}/health" >/dev/null 2>&1 \
        || { echo "❌ codex-gateway에 연결할 수 없습니다 ($provider_url)"; return 1; }
      skip_tui=true; shift ;;
  esac

  while [[ $# -gt 0 ]]; do
    case "$1" in
      fast)
        claude_args+=(--model haiku)
        env_effort=low; skip_tui=true; mode_applied=true; shift ;;
      base)
        case "$provider_name" in
          kiro)  ;; # default sonnet, 200K
          codex) claude_args+=(--model 'sonnet[1m]') ;; # codex proxy supports 1M
          *)     claude_args+=(--model sonnet) ;;       # direct OAuth: sonnet[1m] needs API plan
        esac
        env_effort=high; skip_tui=true; mode_applied=true; shift ;;
      plan)
        case "$provider_name" in
          kiro)  claude_args+=(--model opusplan); env_effort=high ;;
          codex) claude_args+=(--model 'opusplan[1m]'); env_effort=xhigh ;;
          *)     claude_args+=(--model opusplan); env_effort=high ;;
        esac
        skip_tui=true; mode_applied=true; shift ;;
      rich)
        case "$provider_name" in
          kiro)  claude_args+=(--model 'claude-opus-4-6') ;;
          codex) claude_args+=(--model 'opus[1m]') ;;   # DRIFT FIX: was opus, now opus[1m]
          *)     claude_args+=(--model 'opus[1m]') ;;
        esac
        env_effort=max; skip_tui=true; mode_applied=true; shift ;;
      low|medium|high|xhigh|max)
        env_effort="$1"
        if ! $mode_applied; then
          case "$provider_name" in
            kiro)  ;;
            codex) claude_args+=(--model 'sonnet[1m]') ;;
            *)     claude_args+=(--model sonnet) ;;
          esac
        fi
        skip_tui=true; shift ;;
      continue) session_flag="--continue"; skip_tui=true; shift ;;
      resume)   session_flag="--resume"; skip_tui=true; shift ;;
      bypass)       claude_args+=(--permission-mode bypassPermissions); skip_tui=true; shift ;;
      acceptEdits)  claude_args+=(--permission-mode acceptEdits); skip_tui=true; shift ;;
      dontAsk)      claude_args+=(--permission-mode dontAsk); skip_tui=true; shift ;;
      *)            claude_args+=("$1"); shift ;;
    esac
  done

  if $skip_tui; then
    [[ -n "$session_flag" ]] && claude_args=("$session_flag" "${claude_args[@]}")
    if [[ -n "$provider_url" ]]; then
      export ANTHROPIC_BASE_URL="$provider_url"
      if [[ -n "$gateway_api_key" ]]; then
        export ANTHROPIC_AUTH_TOKEN="$gateway_api_key"
        unset ANTHROPIC_API_KEY
      fi
      unset ANTHROPIC_DEFAULT_OPUS_MODEL ANTHROPIC_DEFAULT_SONNET_MODEL ANTHROPIC_DEFAULT_HAIKU_MODEL ANTHROPIC_CUSTOM_HEADERS
      if [[ "$provider_name" == "codex" ]]; then
        # DRIFT FIX: no dead fallbacks — only export what user configured
        [[ -n "${CODEX_OPUS_MODEL:-}" ]]   && export ANTHROPIC_DEFAULT_OPUS_MODEL="$CODEX_OPUS_MODEL"
        [[ -n "${CODEX_SONNET_MODEL:-}" ]] && export ANTHROPIC_DEFAULT_SONNET_MODEL="$CODEX_SONNET_MODEL"
        [[ -n "${CODEX_HAIKU_MODEL:-}" ]]  && export ANTHROPIC_DEFAULT_HAIKU_MODEL="$CODEX_HAIKU_MODEL"
      fi
    fi
    [[ -n "$env_effort" ]] && export CLAUDE_CODE_EFFORT_LEVEL="$env_effort"
    exec claude "${claude_args[@]}"
  else
    HARNESS_DIR="$HARNESS_DIR" HARNESS_NAME="$HARNESS_NAME" \
      exec "$_HARNESS_LAUNCHER_BIN/launcher.sh"
  fi
}

# _harness_launcher_complete <harness-dir>
_harness_launcher_complete() {
  local dir="$1"
  local -a shortcuts
  local _kiro_url="${KIRO_GATEWAY_URL:-}"
  local _kiro_env="$dir/config/.local/kiro-gateway.env"
  local _codex_url="${CODEX_GATEWAY_URL:-}"
  local _codex_env="$dir/config/.local/codex-gateway.env"
  shortcuts=(
    'fast:Sonnet low effort'
    'base:Sonnet high effort'
    'plan:Opusplan — Opus plan, Sonnet exec, high effort'
    'rich:Opus 1M max effort'
    'continue:Continue last session'
    'resume:Resume from list'
    'bypass:Skip all permission prompts'
    'acceptEdits:Auto-approve edits only'
    'dontAsk:Auto-approve most actions'
  )
  if [[ -z "$_kiro_url" && -f "$_kiro_env" ]]; then
    source "$_kiro_env"; _kiro_url="${KIRO_GATEWAY_URL:-}"
  fi
  if [[ -z "$_codex_url" && -f "$_codex_env" ]]; then
    source "$_codex_env"; _codex_url="${CODEX_GATEWAY_URL:-}"
  fi
  [[ -n "$_kiro_url" ]]  && shortcuts+=('kiro:Kiro via gateway')
  [[ -n "$_codex_url" ]] && shortcuts+=('codex:Codex via gateway')
  _describe 'harness shortcuts' shortcuts
}
