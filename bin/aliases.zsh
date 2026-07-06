#!/usr/bin/env zsh
# harness-launcher — generic zsh launcher function + tab completion
# Usage:
#   source /path/to/harness-launcher/bin/aliases.zsh
#   harness_register /path/to/some-harness

_HARNESS_LAUNCHER_BIN="$(cd "$(dirname "${(%):-%x}")" 2>/dev/null && pwd)"
_HARNESS_CODEX_APP_BIN="/Applications/Codex.app/Contents/Resources/codex"
typeset -ga _HARNESS_LAUNCHER_REGISTERED_DIRS=()

_harness_launcher_codex_bin() {
  local configured="${HARNESS_CODEX_BIN:-}"
  if [[ -n "$configured" ]]; then
    if [[ -x "$configured" ]]; then
      print -r -- "$configured"
      return 0
    fi
    whence -p -- "$configured" 2>/dev/null
    return $?
  fi
  if [[ -x "$_HARNESS_CODEX_APP_BIN" ]]; then
    print -r -- "$_HARNESS_CODEX_APP_BIN"
    return 0
  fi
  whence -p -- codex 2>/dev/null
}

_harness_launcher_probe_provider_health() {
  local provider_url="$1"
  [[ -z "$provider_url" ]] && return 1
  PROBE_PROVIDER_URL="$provider_url" \
    node -e 'const baseUrl = process.env.PROBE_PROVIDER_URL; const controller = new AbortController(); const timer = setTimeout(() => controller.abort(), 2000); fetch(`${baseUrl}/health`, { signal: controller.signal }).then(() => { clearTimeout(timer); process.exit(0); }).catch(() => { clearTimeout(timer); process.exit(1); });' >/dev/null 2>&1
}

_harness_launcher_mcp_local_configs() {
  local HARNESS_DIR="$1"
  [[ -f "$HARNESS_DIR/.mcp.local.json" ]] && print -r -- "$HARNESS_DIR/.mcp.local.json"
  [[ -f "$HARNESS_DIR/mcp.local.json" ]] && print -r -- "$HARNESS_DIR/mcp.local.json"
}

_harness_launcher_validate_mcp_local_configs() {
  local HARNESS_DIR="$1"
  local -a mcp_files=("$HARNESS_DIR/.mcp.json")
  [[ -f "$HARNESS_DIR/.mcp.local.json" ]] && mcp_files+=("$HARNESS_DIR/.mcp.local.json")
  [[ -f "$HARNESS_DIR/mcp.local.json" ]] && mcp_files+=("$HARNESS_DIR/mcp.local.json")
  [[ ${#mcp_files[@]} -gt 1 ]] || return 0

  python3 - "${mcp_files[@]}" <<'PY'
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

_harness_launcher_add_claude_mcp_local_args() {
  local HARNESS_DIR="$1"; shift
  local -a local_files=()
  local f

  _harness_launcher_validate_mcp_local_configs "$HARNESS_DIR" || return $?
  while IFS= read -r f; do
    [[ -n "$f" ]] && local_files+=("$f")
  done < <(_harness_launcher_mcp_local_configs "$HARNESS_DIR")

  if [[ ${#local_files[@]} -gt 0 ]]; then
    "$@" --mcp-config "${local_files[@]}"
  else
    "$@"
  fi
}

_harness_launcher_export_codex_runtime_env() {
  local HARNESS_DIR="$1"
  local prepare="$_HARNESS_LAUNCHER_BIN/codex-home-prepare.sh"
  if [[ -x "$prepare" ]]; then
    "$prepare" "$HARNESS_DIR" || return $?
  fi

  export CODEX_HOME="$HARNESS_DIR/.harness/codex"

  # Export MCP secrets from settings.local.json env so codex streamable_http
  # bearer_token_env_var resolves (native codex inherits no other harness env).
  if [[ -f "$HARNESS_DIR/.claude/settings.local.json" ]]; then
    while IFS=$'\t' read -r _mk _mv; do
      [[ -n "$_mk" ]] && export "$_mk=$_mv"
    done < <(python3 - "$HARNESS_DIR/.claude/settings.local.json" 2>/dev/null <<'PY'
import json, sys
with open(sys.argv[1]) as f:
    env = (json.load(f).get("env") or {})
for k, v in env.items():
    print(k + "\t" + str(v))
PY
)
  fi
}

_harness_launcher_codex_cd_arg() {
  local -a args=("$@")
  local i arg
  for (( i = 1; i <= ${#args[@]}; i++ )); do
    arg="${args[$i]}"
    case "$arg" in
      --cd|-C)
        (( i < ${#args[@]} )) && print -r -- "${args[$((i + 1))]}"
        return 0
        ;;
      --cd=*)
        print -r -- "${arg#--cd=}"
        return 0
        ;;
    esac
  done
  return 1
}

_harness_launcher_codex_harness_for_args() {
  local cd_arg cd_abs registered
  cd_arg="$(_harness_launcher_codex_cd_arg "$@")" || return 1
  [[ -n "$cd_arg" && -d "$cd_arg" ]] || return 1
  cd_abs="${cd_arg:A}"

  for registered in "${_HARNESS_LAUNCHER_REGISTERED_DIRS[@]}"; do
    [[ "$cd_abs" == "$registered" ]] && {
      print -r -- "$registered"
      return 0
    }
  done

  if [[ -f "$cd_abs/config/launcher.env" ]]; then
    print -r -- "$cd_abs"
    return 0
  fi

  return 1
}

codex() {
  local codex_bin harness_dir
  codex_bin="$(_harness_launcher_codex_bin)" || {
    echo "❌ codex not found in PATH" >&2
    return 1
  }

  if [[ "${HARNESS_LAUNCHER_DISABLE_CODEX_WRAPPER:-}" != "1" ]]; then
    if harness_dir="$(_harness_launcher_codex_harness_for_args "$@")"; then
      _harness_launcher_export_codex_runtime_env "$harness_dir" || return $?
    fi
  fi

  "$codex_bin" "$@"
}

# harness_register <harness-dir>
#   Reads <dir>/config/launcher.env (HARNESS_NAME, HARNESS_PREFIX),
#   defines the prefix function, wires tab completion.
harness_register() {
  local dir="$1"
  [[ -z "$dir" || ! -d "$dir" ]] && { echo "harness_register: invalid dir: $dir" >&2; return 1; }
  dir="${dir:A}"
  local env_file="$dir/config/launcher.env"
  [[ ! -f "$env_file" ]] && { echo "harness_register: missing $env_file" >&2; return 1; }

  local HARNESS_NAME HARNESS_PREFIX
  source "$env_file"
  [[ -z "$HARNESS_PREFIX" ]] && { echo "harness_register: HARNESS_PREFIX required in $env_file" >&2; return 1; }
  [[ -z "$HARNESS_NAME" ]] && { echo "harness_register: HARNESS_NAME required in $env_file" >&2; return 1; }

  # Remove any pre-existing alias that shadows the prefix (e.g., oh-my-zsh gd/gp aliases)
  unalias "$HARNESS_PREFIX" 2>/dev/null || true

  # Define <prefix>() — delegates to generic runner with harness dir
  eval "${HARNESS_PREFIX}() { _harness_launcher_run '$dir' \"\$@\"; }"
  # Define _<prefix>_complete() — delegates to generic completion
  eval "_${HARNESS_PREFIX}_complete() { _harness_launcher_complete '$dir' \"\$@\"; }"
  if (( $+functions[compdef] )); then
    compdef "_${HARNESS_PREFIX}_complete" "$HARNESS_PREFIX"
  fi

  local registered exists=false
  for registered in "${_HARNESS_LAUNCHER_REGISTERED_DIRS[@]}"; do
    [[ "$registered" == "$dir" ]] && { exists=true; break; }
  done
  $exists || _HARNESS_LAUNCHER_REGISTERED_DIRS+=("$dir")
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
      _harness_launcher_probe_provider_health "$provider_url" \
        || { echo "❌ kiro-gateway에 연결할 수 없습니다 ($provider_url)"; return 1; }
      skip_tui=true; shift ;;
    codex)
      shift
      _harness_launcher_run_codex_cli "$HARNESS_DIR" "$@"
      return $?
      ;;
    codex-gateway)
      provider_name="codex"
      local _env_file="$HARNESS_DIR/config/.local/codex-gateway.env"
      if [[ -f "$_env_file" ]]; then
        source "$_env_file"
        [[ -n "${CODEX_GATEWAY_URL:-}" ]] && provider_url="$CODEX_GATEWAY_URL"
        [[ -n "${CODEX_GATEWAY_API_KEY:-}" ]] && gateway_api_key="$CODEX_GATEWAY_API_KEY"
      fi
      [[ -z "$provider_url" ]] && echo "❌ CODEX_GATEWAY_URL이 설정되지 않았습니다" && return 1
      _harness_launcher_probe_provider_health "$provider_url" \
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
          kiro)  claude_args+=(--model 'sonnet[1m]') ;; # kiro gateway supports 1M
          codex) claude_args+=(--model "sonnet${CODEX_CONTEXT_SUFFIX:-}") ;; # codex proxy supports 1M
          *)     claude_args+=(--model sonnet) ;;       # direct OAuth: sonnet[1m] needs API plan
        esac
        env_effort=high; skip_tui=true; mode_applied=true; shift ;;
      plan)
        case "$provider_name" in
          kiro)  claude_args+=(--model 'opusplan[1m]'); env_effort=high ;;
          codex) claude_args+=(--model "opusplan${CODEX_CONTEXT_SUFFIX:-}"); env_effort=high ;;
          *)     claude_args+=(--model opusplan); env_effort=high ;;
        esac
        skip_tui=true; mode_applied=true; shift ;;
      rich)
        case "$provider_name" in
          kiro)  claude_args+=(--model 'claude-opus-4-6[1m]'); env_effort=max ;;
          codex) claude_args+=(--model "opus${CODEX_CONTEXT_SUFFIX:-}"); env_effort=high ;;
          *)     claude_args+=(--model 'opus[1m]'); env_effort=xhigh ;;
        esac
        skip_tui=true; mode_applied=true; shift ;;
      ultracode)
        # ultracode = xhigh + dynamic workflow orchestration. The orchestration
        # half is a SESSION-ONLY Claude Code preset: the CLI rejects 'ultracode'
        # as an --effort / env / settings value (allowed: low|medium|high|xhigh|
        # max), so it cannot be set at launch. Launch as rich (opus[1m] + xhigh)
        # and remind the user to flip it on in-session via /effort.
        # Anthropic direct only — kiro/codex gateways don't support it at all.
        if [[ "$provider_name" == "kiro" || "$provider_name" == "codex" ]]; then
          echo "❌ ultracode는 Anthropic direct 전용입니다 (codex/kiro 미지원)" >&2
          return 1
        fi
        claude_args+=(--model 'opus[1m]'); env_effort=xhigh
        print -u2 "💡 ultracode는 세션 전용입니다 — 시작 후 /effort 에서 ultracode를 선택하면 워크플로우 오케스트레이션이 켜집니다 (지금은 opus[1m] + xhigh로 시작)."
        skip_tui=true; mode_applied=true; shift ;;
      low|medium|high|xhigh|max)
        env_effort="$1"
        if ! $mode_applied; then
          case "$provider_name" in
            kiro)  ;;
            codex) claude_args+=(--model "sonnet${CODEX_CONTEXT_SUFFIX:-}") ;;
            *)     claude_args+=(--model sonnet) ;;
          esac
        fi
        skip_tui=true; shift ;;
      continue) session_flag="--continue"; skip_tui=true; shift ;;
      resume)   session_flag="--resume"; skip_tui=true; shift ;;
      bypass)       claude_args+=(--permission-mode bypassPermissions); skip_tui=true; shift ;;
      acceptEdits)  claude_args+=(--permission-mode acceptEdits); skip_tui=true; shift ;;
      dontAsk)      claude_args+=(--permission-mode dontAsk); skip_tui=true; shift ;;
      --chrome|--no-chrome)
                    claude_args+=("$1"); skip_tui=true; shift ;;
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
    [[ -n "$env_effort" ]] && claude_args+=(--effort "$env_effort")
    claude_args+=(--exclude-dynamic-system-prompt-sections)
    # Auto-compact PCT by detected context size + provider + model:
    #   [1m] + codex + (opus|sonnet contains "5.5") → PCT=35 (real GPT-5.5/Codex
    #                  limit is 400K, not 1M; 35% of fake 1M = 350K fits 400K)
    #   [1m] otherwise (direct Anthropic, or codex with non-5.5 model) → PCT=50
    #   200K (no [1m])                          → settings.json fallback applies
    for _arg in "${claude_args[@]}"; do
      if [[ "$_arg" == *"[1m]"* ]]; then
        if [[ "$provider_name" == "codex" ]] && {
             [[ "${CODEX_OPUS_MODEL:-}" == *"5.5"* ]] || [[ "${CODEX_SONNET_MODEL:-}" == *"5.5"* ]]
           }; then
          export CLAUDE_AUTOCOMPACT_PCT_OVERRIDE=35
        else
          export CLAUDE_AUTOCOMPACT_PCT_OVERRIDE=50
        fi
        break
      fi
    done
    # Plain invocation (not exec) so the user's interactive shell survives
    # the launched process — Ctrl+C returns to the prompt instead of closing
    # the terminal window.
    _harness_launcher_add_claude_mcp_local_args "$HARNESS_DIR" claude "${claude_args[@]}"
    return $?
  else
    HARNESS_DIR="$HARNESS_DIR" HARNESS_NAME="$HARNESS_NAME" \
      "$_HARNESS_LAUNCHER_BIN/launcher.sh"
    return $?
  fi
}

# _harness_launcher_run_codex_cli <harness-dir> [args...]
#   Launches Codex CLI natively against a per-harness CODEX_HOME.
#   Modes:    fast | base | plan | rich  → -p <profile>
#   Wrapper:  happy → `happy codex ...`
#   Sessions: resume → `codex resume`,  continue → `codex resume --last`,
#             fork   → `codex fork`
_harness_launcher_run_codex_cli() {
  local HARNESS_DIR="$1"; shift
  local profile=""
  local profile_explicit=false
  local subcmd=""
  local use_happy=false
  local -a codex_args=()

  while [[ $# -gt 0 ]]; do
    case "$1" in
      fast|base|plan|rich) profile="$1"; profile_explicit=true; shift ;;
      resume)              subcmd="resume"; shift ;;
      continue)            subcmd="resume"; codex_args+=(--last); shift ;;
      fork)                subcmd="fork"; shift ;;
      happy)               use_happy=true; shift ;;
      *)                   codex_args+=("$1"); shift ;;
    esac
  done

  [[ -z "$profile" ]] && profile="base"

  _harness_launcher_export_codex_runtime_env "$HARNESS_DIR" || return $?

  if $use_happy; then
    command -v happy >/dev/null 2>&1 || {
      echo "❌ happy not found in PATH" >&2
      return 1
    }
    if [[ -n "$subcmd" ]]; then
      echo "❌ Happy Codex cannot map Codex CLI resume/continue/fork. Use 'happy resume <happy-session-id>' or 'happy codex --resume <codex-thread-id>'." >&2
      return 1
    fi
    if $profile_explicit; then
      echo "❌ Happy Codex does not support launcher profiles. Use '${HARNESS_PREFIX:-harness} codex happy' for Happy mode, or '${HARNESS_PREFIX:-harness} codex $profile' for native Codex CLI." >&2
      return 1
    fi
  else
    local codex_bin
    codex_bin="$(_harness_launcher_codex_bin)" || {
      echo "❌ codex not found in PATH" >&2
      return 1
    }
  fi

  # Plain invocation (not exec) so the user's interactive shell survives
  # codex exit — Ctrl+C returns to the prompt instead of closing the terminal.
  local -a launch_cmd=()
  if $use_happy; then
    launch_cmd=(happy codex)
  else
    launch_cmd=("$codex_bin")
  fi
  if [[ -n "$subcmd" ]]; then
    "${launch_cmd[@]}" "$subcmd" --cd "$HARNESS_DIR" -p "$profile" "${codex_args[@]}"
  elif $use_happy; then
    (cd "$HARNESS_DIR" && "${launch_cmd[@]}" "${codex_args[@]}")
  else
    "${launch_cmd[@]}" --cd "$HARNESS_DIR" -p "$profile" "${codex_args[@]}"
  fi
  return $?
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
    'ultracode:Opus 1M xhigh now · /effort→ultracode for workflows (direct only)'
    'continue:Continue last session'
    'resume:Resume from list'
    'bypass:Skip all permission prompts'
    'acceptEdits:Auto-approve edits only'
    'dontAsk:Auto-approve most actions'
    '--chrome:Enable Claude in Chrome integration'
    '--no-chrome:Disable Claude in Chrome integration'
    'codex:Codex CLI native'
    'happy:Use Happy mobile wrapper for Codex CLI'
  )
  if [[ -z "$_kiro_url" && -f "$_kiro_env" ]]; then
    source "$_kiro_env"; _kiro_url="${KIRO_GATEWAY_URL:-}"
  fi
  if [[ -z "$_codex_url" && -f "$_codex_env" ]]; then
    source "$_codex_env"; _codex_url="${CODEX_GATEWAY_URL:-}"
  fi
  [[ -n "$_kiro_url" ]]  && shortcuts+=('kiro:Kiro via gateway')
  [[ -n "$_codex_url" ]] && shortcuts+=('codex-gateway:Claude Code via Codex gateway (legacy)')
  _describe 'harness shortcuts' shortcuts
}
