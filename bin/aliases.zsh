#!/usr/bin/env zsh
# harness-launcher — generic zsh launcher function + tab completion
# Usage:
#   source /path/to/harness-launcher/bin/aliases.zsh
#   harness_register /path/to/some-harness

_HARNESS_LAUNCHER_BIN="$(cd "$(dirname "${(%):-%x}")" 2>/dev/null && pwd)"
typeset -ga _HARNESS_LAUNCHER_REGISTERED_DIRS=()

# Single source of truth for mode tables, bin resolution, probes, MCP config
# validation, secrets export, and autocompact PCT — shared with launcher.sh.
source "$_HARNESS_LAUNCHER_BIN/harness-common.sh"

_harness_launcher_codex_bin() { harness_codex_bin_resolve "$@"; }

_harness_launcher_probe_provider_health() { harness_probe_health "$@"; }

_harness_launcher_mcp_local_configs() { harness_mcp_local_configs "$@"; }

_harness_launcher_validate_mcp_local_configs() { harness_validate_mcp_local_configs "$@"; }

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

  # MCP secrets from settings.local.json env so codex streamable_http
  # bearer_token_env_var resolves (native codex inherits no other harness env).
  harness_export_local_env "$HARNESS_DIR"
}

_harness_launcher_kiro_bin() { harness_kiro_bin_resolve "$@"; }

_harness_launcher_export_kiro_runtime_env() {
  local HARNESS_DIR="$1"
  local prepare="$_HARNESS_LAUNCHER_BIN/kiro-home-prepare.sh"
  if [[ -x "$prepare" ]]; then
    "$prepare" "$HARNESS_DIR" || return $?
  fi
  export KIRO_HOME="$HARNESS_DIR/.harness/kiro"
  harness_export_local_env "$HARNESS_DIR"
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
  local codex_bin harness_dir broker_started=false
  codex_bin="$(_harness_launcher_codex_bin)" || {
    echo "❌ codex not found in PATH" >&2
    return 1
  }

  if [[ "${HARNESS_LAUNCHER_DISABLE_CODEX_WRAPPER:-}" != "1" ]]; then
    if harness_dir="$(_harness_launcher_codex_harness_for_args "$@")"; then
      local HARNESS_NAME HARNESS_PREFIX
      source "$harness_dir/config/launcher.env"
      export HARNESS_PREFIX
      _harness_launcher_export_codex_runtime_env "$harness_dir" || return $?
      harness_codex_cmux_broker_start "$_HARNESS_LAUNCHER_BIN/codex-cmux-title-sync.py"
      broker_started=true
    fi
  fi

  "$codex_bin" "$@"
  local rc=$?
  $broker_started && harness_codex_cmux_broker_stop
  return $rc
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

  local HARNESS_RUN_DIR=""
  case "${1:-}" in
    --cwd)
      [[ $# -ge 2 ]] || { echo "harness-launcher: --cwd requires a directory" >&2; return 2; }
      HARNESS_RUN_DIR="$(harness_resolve_run_dir "$HARNESS_DIR" "$2")" || return $?
      shift 2
      ;;
  esac

  local -a claude_args=()
  local session_flag="" skip_tui=false env_effort="" provider_url="" gateway_api_key="" provider_name=""
  local mode_applied=false mcp_surface="full"

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
    kiro-cli)
      shift
      _harness_launcher_run_kiro_cli "$HARNESS_DIR" "$@"
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
      fast|base|plan|rich)
        harness_mode_resolve "$1" "${provider_name:-direct}"
        claude_args+=(--model "$HARNESS_MODE_MODEL")
        env_effort="$HARNESS_MODE_EFFORT"
        skip_tui=true; mode_applied=true; shift ;;
      ultracode)
        # ultracode = xhigh + dynamic workflow orchestration. The orchestration
        # half is a SESSION-ONLY Claude Code preset: the CLI rejects 'ultracode'
        # as an --effort / env / settings value (allowed: low|medium|high|xhigh|
        # max), so it cannot be set at launch. Launch as rich (opus[1m] + xhigh)
        # and remind the user to flip it on in-session via /effort.
        # Anthropic direct only — kiro/codex gateways don't support it at all.
        if ! harness_mode_resolve ultracode "${provider_name:-direct}"; then
          echo "❌ ultracode는 Anthropic direct 전용입니다 (codex/kiro 미지원)" >&2
          return 1
        fi
        claude_args+=(--model "$HARNESS_MODE_MODEL"); env_effort="$HARNESS_MODE_EFFORT"
        harness_ultracode_hint
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
      light)    mcp_surface="light"; skip_tui=true; shift ;;
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
    harness_autocompact_pct "${provider_name:-direct}" "${claude_args[@]}"
    # Shared-table globals must not linger in the interactive shell.
    unset HARNESS_MODE_MODEL HARNESS_MODE_EFFORT
    # Plain invocation (not exec) so the user's interactive shell survives
    # the launched process — Ctrl+C returns to the prompt instead of closing
    # the terminal window.
    if [[ "$mcp_surface" == "light" ]]; then
      local _light_file
      _light_file="$(harness_claude_light_mcp_config "$HARNESS_DIR")" || return $?
      if [[ -n "$HARNESS_RUN_DIR" ]]; then
        (cd "$HARNESS_RUN_DIR" && claude --strict-mcp-config --mcp-config "$_light_file" "${claude_args[@]}")
      else
        claude --strict-mcp-config --mcp-config "$_light_file" "${claude_args[@]}"
      fi
    else
      if [[ -n "$HARNESS_RUN_DIR" ]]; then
        (cd "$HARNESS_RUN_DIR" && _harness_launcher_add_claude_mcp_local_args "$HARNESS_DIR" claude "${claude_args[@]}")
      else
        _harness_launcher_add_claude_mcp_local_args "$HARNESS_DIR" claude "${claude_args[@]}"
      fi
    fi
    return $?
  else
    HARNESS_DIR="$HARNESS_DIR" HARNESS_NAME="$HARNESS_NAME" HARNESS_PREFIX="$HARNESS_PREFIX" \
      HARNESS_RUN_DIR="${HARNESS_RUN_DIR:-}" \
      "$_HARNESS_LAUNCHER_BIN/launcher.sh"
    return $?
  fi
}

# _harness_launcher_run_codex_cli <harness-dir> [args...]
#   Launches Codex CLI natively against a per-harness CODEX_HOME.
#   Modes:    fast | base | plan | rich  → -p <profile>
#   Surface:  work → work MCP surface (combinable with any profile)
#   Wrapper:  happy → `happy codex ...`
#   Sessions: resume → `codex resume`,  continue → `codex resume --last`,
#             fork   → `codex fork`
_harness_launcher_run_codex_cli() {
  local HARNESS_DIR="$1"; shift
  local run_dir="${HARNESS_RUN_DIR:-$HARNESS_DIR}"
  export HARNESS_PREFIX
  local profile=""
  local profile_explicit=false
  local mcp_profile=""
  local subcmd=""
  local use_happy=false
  local freeform=false
  local -a codex_args=()

  while [[ $# -gt 0 ]]; do
    case "$1" in
      fast|base|sol|plan|rich)
        profile="$1"; profile_explicit=true; shift ;;
      work)
        # Surface keyword, combinable with any model profile and any launcher
        # keyword in any order (same UX as the claude `light` keyword). Only a
        # genuinely free-form token before it (e.g. `exec work`) demotes it to
        # prompt text — launcher keywords like full-auto/continue must not.
        if $freeform; then
          codex_args+=("$1"); shift
        else
          mcp_profile="work"; shift
        fi
        ;;
      resume)              subcmd="resume"; shift ;;
      continue)            subcmd="resume"; codex_args+=(--last); shift ;;
      fork)                subcmd="fork"; codex_args+=(--last); shift ;;
      happy)               use_happy=true; shift ;;
      full-auto)           codex_args+=(--full-auto); shift ;;
      never)               codex_args+=(-a never); shift ;;
      bypass)              codex_args+=(--dangerously-bypass-approvals-and-sandbox); shift ;;
      *)                   freeform=true; codex_args+=("$1"); shift ;;
    esac
  done

  [[ -z "$profile" ]] && profile="base"

  # Validate incompatible combinations BEFORE preparing the runtime home, so a
  # rejected launch leaves no work-surface residue in the generated config.
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
    if [[ -n "$mcp_profile" ]]; then
      echo "❌ Happy Codex는 work MCP surface와 함께 사용할 수 없습니다." >&2
      return 1
    fi
  else
    local codex_bin
    codex_bin="$(_harness_launcher_codex_bin)" || {
      echo "❌ codex not found in PATH" >&2
      return 1
    }
  fi

  if [[ -n "$mcp_profile" ]]; then
    local HARNESS_CODEX_MCP_PROFILE="$mcp_profile"
    export HARNESS_CODEX_MCP_PROFILE
    _harness_launcher_export_codex_runtime_env "$HARNESS_DIR" || return $?
  else
    _harness_launcher_export_codex_runtime_env "$HARNESS_DIR" || return $?
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
    harness_codex_cmux_broker_start "$_HARNESS_LAUNCHER_BIN/codex-cmux-title-sync.py"
    (cd "$run_dir" && "${launch_cmd[@]}" "$subcmd" --cd "$run_dir" -p "$profile" "${codex_args[@]}")
  elif $use_happy; then
    harness_codex_cmux_broker_start "$_HARNESS_LAUNCHER_BIN/codex-cmux-title-sync.py"
    (cd "$run_dir" && "${launch_cmd[@]}" "${codex_args[@]}")
  else
    harness_codex_cmux_broker_start "$_HARNESS_LAUNCHER_BIN/codex-cmux-title-sync.py"
    (cd "$run_dir" && "${launch_cmd[@]}" --cd "$run_dir" -p "$profile" "${codex_args[@]}")
  fi
  local rc=$?
  harness_codex_cmux_broker_stop
  return $rc
}

# _harness_launcher_run_kiro_cli <harness-dir> [args...]
#   Launches Kiro CLI natively against a per-harness KIRO_HOME.
#   Modes:    fast | base | plan | rich → --model + --effort
#   Sessions: resume → --resume-picker, continue → -r
_harness_launcher_run_kiro_cli() {
  local HARNESS_DIR="$1"; shift
  local run_dir="${HARNESS_RUN_DIR:-$HARNESS_DIR}"
  local model="" effort="" agent="harness" mcp_surface="full"
  local -a kiro_args=()
  local session_flag=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      fast|base|plan|rich)
        harness_kiro_mode_resolve "$1"
        model="$HARNESS_KIRO_MODEL"; effort="$HARNESS_KIRO_EFFORT"; shift ;;
      resume)   session_flag="--resume-picker"; shift ;;
      continue) session_flag="-r"; shift ;;
      bypass)   kiro_args+=(-a); shift ;;
      light)    mcp_surface="light"; shift ;;
      *)        kiro_args+=("$1"); shift ;;
    esac
  done

  if [[ -z "$model" ]]; then
    harness_kiro_mode_resolve base
    model="$HARNESS_KIRO_MODEL"; effort="$HARNESS_KIRO_EFFORT"
  fi

  # Resolve the binary before exporting the surface profile: an early failure
  # return here must not leave HARNESS_KIRO_MCP_PROFILE in the user's shell.
  local kiro_bin
  kiro_bin="$(_harness_launcher_kiro_bin)" || {
    echo "❌ kiro-cli not found in PATH" >&2
    return 1
  }

  if [[ "$mcp_surface" == "light" ]]; then
    export HARNESS_KIRO_MCP_PROFILE="light"
  else
    unset HARNESS_KIRO_MCP_PROFILE
  fi
  _harness_launcher_export_kiro_runtime_env "$HARNESS_DIR" || {
    local rc=$?
    unset HARNESS_KIRO_MCP_PROFILE
    return $rc
  }

  local -a launch_cmd=("$kiro_bin" chat)
  [[ -n "$session_flag" ]] && launch_cmd+=("$session_flag")
  launch_cmd+=(--model "$model" --effort "$effort" --agent "$agent")
  [[ ${#kiro_args[@]} -gt 0 ]] && launch_cmd+=("${kiro_args[@]}")
  unset HARNESS_KIRO_MODEL HARNESS_KIRO_EFFORT

  (cd "$run_dir" && "${launch_cmd[@]}")
  local rc=$?
  unset HARNESS_KIRO_MCP_PROFILE
  return $rc
}

# _harness_launcher_complete <harness-dir>
_harness_launcher_complete() {
  local dir="$1"
  local -a shortcuts
  local m desc
  # Mode descriptions come from the shared table so completion text cannot
  # drift from the launched model/effort. Resolution runs in subshells so the
  # HARNESS_MODE_* globals never touch the interactive shell.
  shortcuts=()
  for m in fast base plan rich; do
    desc="$( harness_mode_resolve "$m" direct; printf '%s · %s' "$HARNESS_MODE_MODEL" "$HARNESS_MODE_EFFORT" )"
    shortcuts+=("$m:$desc")
  done
  desc="$( harness_mode_resolve ultracode direct; printf '%s · %s' "$HARNESS_MODE_MODEL" "$HARNESS_MODE_EFFORT" )"
  shortcuts+=(
    "ultracode:$desc now · /effort→ultracode for workflows (direct only)"
    'light:Light MCP surface — SSH-backed servers excluded (claude/kiro-cli)'
    'continue:Continue last session'
    'resume:Resume from list'
    'bypass:Skip all permission prompts'
    'acceptEdits:Auto-approve edits only'
    'dontAsk:Auto-approve most actions'
    '--chrome:Enable Claude in Chrome integration'
    '--no-chrome:Disable Claude in Chrome integration'
    'codex:Codex CLI native (fast/base/sol/plan/rich · work surface · fork · full-auto/never/bypass)'
    'kiro-cli:Kiro CLI native'
    'happy:Use Happy mobile wrapper for Codex CLI'
  )
  # Gateway env files are sourced in subshells so API keys never leak into
  # the interactive shell's variables.
  local _kiro_url _codex_url
  _kiro_url="${KIRO_GATEWAY_URL:-}"
  [[ -z "$_kiro_url" && -f "$dir/config/.local/kiro-gateway.env" ]] && \
    _kiro_url="$( source "$dir/config/.local/kiro-gateway.env" 2>/dev/null; printf '%s' "${KIRO_GATEWAY_URL:-}" )"
  _codex_url="${CODEX_GATEWAY_URL:-}"
  [[ -z "$_codex_url" && -f "$dir/config/.local/codex-gateway.env" ]] && \
    _codex_url="$( source "$dir/config/.local/codex-gateway.env" 2>/dev/null; printf '%s' "${CODEX_GATEWAY_URL:-}" )"
  [[ -n "$_kiro_url" ]]  && shortcuts+=('kiro:Kiro via gateway')
  [[ -n "$_codex_url" ]] && shortcuts+=('codex-gateway:Claude Code via Codex gateway (legacy)')
  _describe 'harness shortcuts' shortcuts
}
