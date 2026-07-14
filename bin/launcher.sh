#!/usr/bin/env bash
# harness-launcher — TUI for picking runtime/provider/mode/effort.
# Invoked by bin/aliases.zsh when user runs `<prefix>` with no shortcut args.
# Required env: HARNESS_DIR, HARNESS_NAME
#
# Design (v2):
#   - Choice collection and command assembly are separate: menus only fill
#     CHOICE_* variables; assembly/exec reads them in one place per runtime.
#     "Repeat last" replays saved choices through the same assembly path, so
#     every launch revalidates gateways/homes/MCP configs.
#   - Model/effort/labels come from harness-common.sh (harness_mode_*), the
#     same table the shortcut path uses — labels cannot drift from behavior.
#   - Esc/cancel = one step back everywhere; at the top menu it exits.
#     Ctrl-C exits anywhere.

HARNESS_DIR="${HARNESS_DIR:?HARNESS_DIR required}"
HARNESS_NAME="${HARNESS_NAME:?HARNESS_NAME required}"
cd "$HARNESS_DIR" || exit 1

LAUNCHER_BIN_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=harness-common.sh
. "$LAUNCHER_BIN_DIR/harness-common.sh"

PLAN_FILE="$HARNESS_DIR/.harness/launcher-last"
PROBE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/harness-launcher-probe.XXXXXX")"
trap 'rm -rf "$PROBE_DIR"' EXIT

# ---------------------------------------------------------------------------
# menu <header> <option>...
#   gum: Esc (rc 1) → return 1 ("back"), Ctrl-C (rc 130) → exit.
#   fallback: numbered list, reprompts until valid; 'q' or EOF → return 1.
MENU_RESULT=""
BREADCRUMB=""
menu() {
  local header="$1"; shift
  local options=("$@")
  MENU_RESULT=""
  [ -n "$BREADCRUMB" ] && header="$BREADCRUMB ▸ $header"

  if command -v gum >/dev/null 2>&1 && : </dev/tty 2>/dev/null; then
    local result rc
    result=$(gum choose \
      --header "$header" \
      --cursor "❯ " \
      --select-if-one \
      --height $(( ${#options[@]} + 1 )) \
      "${options[@]}")
    rc=$?
    [ $rc -eq 130 ] && exit 0
    [ $rc -ne 0 ] && return 1
    MENU_RESULT="$result"
    return 0
  fi

  local i choice
  while true; do
    echo ""
    echo "$header"
    for i in "${!options[@]}"; do
      printf "  %d) %s\n" "$((i + 1))" "${options[$i]}"
    done
    if ! read -rp "> " choice; then
      return 1  # EOF → back
    fi
    [ "$choice" = "q" ] && return 1
    if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le "${#options[@]}" ]; then
      MENU_RESULT="${options[$((choice - 1))]}"
      return 0
    fi
    echo "  (1-${#options[@]} 또는 q=뒤로)"
  done
}

# ---------------------------------------------------------------------------
# Gateway probes — fired in the background at startup so the provider menu
# never blocks on them; results are read from status files when needed.
KIRO_GATEWAY_CONFIGURED=false
CODEX_GATEWAY_CONFIGURED=false
prewarm_probes() {
  if [ -f "$HARNESS_DIR/config/.local/kiro-gateway.env" ]; then
    KIRO_GATEWAY_CONFIGURED=true
    (
      . "$HARNESS_DIR/config/.local/kiro-gateway.env"
      if harness_probe_health "${KIRO_GATEWAY_URL:-}"; then echo up; else echo down; fi > "$PROBE_DIR/kiro"
    ) &
  fi
  if [ -f "$HARNESS_DIR/config/.local/codex-gateway.env" ]; then
    CODEX_GATEWAY_CONFIGURED=true
    (
      . "$HARNESS_DIR/config/.local/codex-gateway.env"
      if harness_probe_health "${CODEX_GATEWAY_URL:-}"; then echo up; else echo down; fi > "$PROBE_DIR/codex"
    ) &
  fi
}

# probe_status <kiro|codex> → up | down | ? (probe still running)
probe_status() {
  local f="$PROBE_DIR/$1"
  if [ -s "$f" ]; then cat "$f"; else echo "?"; fi
}

# probe_wait <kiro|codex> — bounded wait (probe itself times out in 2s).
probe_wait() {
  local f="$PROBE_DIR/$1" n=0
  while [ ! -s "$f" ] && [ $n -lt 30 ]; do sleep 0.1; n=$((n + 1)); done
  probe_status "$1"
}

probe_mark() {
  case "$(probe_status "$1")" in
    up) echo "🟢" ;; down) echo "🔴" ;; *) echo "⚪" ;;
  esac
}

# ---------------------------------------------------------------------------
# Launch-plan persistence ("Repeat last").
plan_save() {
  mkdir -p "$HARNESS_DIR/.harness"
  {
    echo "RUNTIME=$CHOICE_RUNTIME"
    echo "SUMMARY=$PLAN_SUMMARY"
    echo "PROVIDER=$CHOICE_PROVIDER"
    echo "SESSION=$CHOICE_SESSION"
    echo "MODE=$CHOICE_MODE"
    echo "C_MODEL=$CHOICE_C_MODEL"
    echo "C_EFFORT=$CHOICE_C_EFFORT"
    echo "PERM=$CHOICE_PERM"
    echo "CHROME=$CHOICE_CHROME"
    echo "HAPPY=$CHOICE_HAPPY"
    echo "CODEX_PROFILE=$CHOICE_CODEX_PROFILE"
    echo "CODEX_SURFACE=$CHOICE_CODEX_SURFACE"
    echo "CODEX_SAFETY=$CHOICE_CODEX_SAFETY"
    echo "KIRO_TRUST=$CHOICE_KIRO_TRUST"
  } > "$PLAN_FILE"
}

plan_load() {
  [ -f "$PLAN_FILE" ] || return 1
  local line key val
  while IFS= read -r line; do
    key="${line%%=*}"; val="${line#*=}"
    case "$key" in
      RUNTIME)       CHOICE_RUNTIME="$val" ;;
      SUMMARY)       PLAN_SUMMARY="$val" ;;
      PROVIDER)      CHOICE_PROVIDER="$val" ;;
      SESSION)       CHOICE_SESSION="$val" ;;
      MODE)          CHOICE_MODE="$val" ;;
      C_MODEL)       CHOICE_C_MODEL="$val" ;;
      C_EFFORT)      CHOICE_C_EFFORT="$val" ;;
      PERM)          CHOICE_PERM="$val" ;;
      CHROME)        CHOICE_CHROME="$val" ;;
      HAPPY)         CHOICE_HAPPY="$val" ;;
      CODEX_PROFILE) CHOICE_CODEX_PROFILE="$val" ;;
      CODEX_SURFACE) CHOICE_CODEX_SURFACE="$val" ;;
      CODEX_SAFETY)  CHOICE_CODEX_SAFETY="$val" ;;
      KIRO_TRUST)    CHOICE_KIRO_TRUST="$val" ;;
    esac
  done < "$PLAN_FILE"
  [ -n "$CHOICE_RUNTIME" ]
}

plan_reset() {
  CHOICE_RUNTIME=""; CHOICE_PROVIDER="direct"; CHOICE_SESSION="new"
  CHOICE_MODE=""; CHOICE_C_MODEL=""; CHOICE_C_EFFORT=""
  CHOICE_PERM="default"; CHOICE_CHROME=0; CHOICE_HAPPY=0
  CHOICE_CODEX_PROFILE="base"; CHOICE_CODEX_SURFACE="default"; CHOICE_CODEX_SAFETY="default"
  CHOICE_KIRO_TRUST=0
  PLAN_SUMMARY=""
}

LAST_SUMMARY=""
plan_available() {
  [ -f "$PLAN_FILE" ] || return 1
  LAST_SUMMARY=$(sed -n 's/^SUMMARY=//p' "$PLAN_FILE" | head -1)
  [ -n "$LAST_SUMMARY" ]
}

# ---------------------------------------------------------------------------
launch_banner() {
  # launch_banner <summary> <cmd>...
  local summary="$1"; shift
  stty sane 2>/dev/null
  echo ""
  echo "▶ $HARNESS_NAME · $summary"
  echo "  $*"
  echo ""
}

# codex_profile_label <profile> — label derived from the generated profile
# config when available (drift-proof), profile name alone otherwise.
codex_profile_label() {
  local profile="$1" cfg="$HARNESS_DIR/.harness/codex/$1.config.toml" model="" effort=""
  if [ -f "$cfg" ]; then
    model=$(sed -n 's/^model = "\(.*\)"/\1/p' "$cfg" | head -1)
    effort=$(sed -n 's/^model_reasoning_effort = "\(.*\)"/\1/p' "$cfg" | head -1)
  fi
  if [ -n "$model" ]; then
    printf '%s — %s · %s\n' "$profile" "$model" "${effort:-default}"
  else
    printf '%s\n' "$profile"
  fi
}

# ---------------------------------------------------------------------------
# Runtime availability.
HAS_CLAUDE=false; HAS_CODEX=false; HAS_KIRO=false; HAS_HAPPY=false
command -v claude >/dev/null 2>&1 && HAS_CLAUDE=true
command -v happy >/dev/null 2>&1 && HAS_HAPPY=true
CODEX_BIN=""
if CODEX_BIN="$(harness_codex_bin_resolve)"; then HAS_CODEX=true; fi
KIRO_BIN=""
if KIRO_BIN="$(harness_kiro_bin_resolve)"; then HAS_KIRO=true; fi

prewarm_probes
plan_reset
REPLAY=false

# ===========================================================================
# Choice collection (interactive) — fills CHOICE_*; plan_load fills the same
# variables for "Repeat last".
# ===========================================================================

AUTO_RUNTIME=false
collect_runtime() {
  local opts=() labels=()
  AUTO_RUNTIME=false
  if plan_available; then
    opts+=("repeat"); labels+=("↩ Repeat last — $LAST_SUMMARY")
  fi
  $HAS_CLAUDE && { opts+=("claude"); labels+=("☁️  Claude Code"); }
  $HAS_CODEX && { opts+=("codex"); labels+=("⚡ Codex CLI — native"); }
  $HAS_KIRO && { opts+=("kiro"); labels+=("🦜 Kiro CLI — native"); }

  if [ ${#opts[@]} -eq 0 ]; then
    echo "Error: no runtime found (claude / codex / kiro-cli not in PATH)" >&2
    echo "  claude 설치 여부 또는 HARNESS_CODEX_BIN / HARNESS_KIRO_BIN 설정을 확인하세요." >&2
    exit 1
  fi
  if [ ${#opts[@]} -eq 1 ]; then
    CHOICE_RUNTIME="${opts[0]}"
    AUTO_RUNTIME=true
    return 0
  fi

  BREADCRUMB=""
  menu "$HARNESS_NAME" "${labels[@]}" || return 1
  local i
  for i in "${!labels[@]}"; do
    if [ "$MENU_RESULT" = "${labels[$i]}" ]; then
      CHOICE_RUNTIME="${opts[$i]}"
      break
    fi
  done
  if [ "$CHOICE_RUNTIME" = "repeat" ]; then
    plan_load || return 1
    REPLAY=true
  fi
  return 0
}

# --- Claude flow -----------------------------------------------------------
claude_summary() {
  local model effort
  if [ "$CHOICE_MODE" = "custom" ]; then
    model="$CHOICE_C_MODEL"; effort="$CHOICE_C_EFFORT"
  else
    harness_mode_resolve "$CHOICE_MODE" "$CHOICE_PROVIDER"
    model="$HARNESS_MODE_MODEL"; effort="$HARNESS_MODE_EFFORT"
  fi
  PLAN_SUMMARY="Claude · $CHOICE_PROVIDER · $CHOICE_SESSION · $model · $effort"
  [ "$CHOICE_PERM" != "default" ] && PLAN_SUMMARY="$PLAN_SUMMARY · $CHOICE_PERM"
  [ "$CHOICE_CHROME" = 1 ] && PLAN_SUMMARY="$PLAN_SUMMARY · chrome"
  [ "$CHOICE_HAPPY" = 1 ] && PLAN_SUMMARY="$PLAN_SUMMARY · happy"
}

collect_claude() {
  local step=provider i
  # Skip the provider menu entirely when no gateway is configured.
  if ! $KIRO_GATEWAY_CONFIGURED && ! $CODEX_GATEWAY_CONFIGURED; then
    CHOICE_PROVIDER="direct"
    step=session
  fi

  while true; do
    case "$step" in
      provider)
        BREADCRUMB="$HARNESS_NAME ▸ Claude"
        local popts=("☁️  Anthropic — direct")
        $KIRO_GATEWAY_CONFIGURED && popts+=("$(probe_mark kiro) Kiro gateway")
        $CODEX_GATEWAY_CONFIGURED && popts+=("$(probe_mark codex) Codex gateway")
        menu "Provider" "${popts[@]}" || return 1
        case "$MENU_RESULT" in
          *Kiro*)  CHOICE_PROVIDER="kiro" ;;
          *Codex*) CHOICE_PROVIDER="codex" ;;
          *)       CHOICE_PROVIDER="direct" ;;
        esac
        step=session ;;

      session)
        BREADCRUMB="$HARNESS_NAME ▸ Claude"
        menu "Session" \
          "🆕 New session" \
          "⏩ Continue last session" \
          "📋 Resume — pick from list" || {
            if $KIRO_GATEWAY_CONFIGURED || $CODEX_GATEWAY_CONFIGURED; then step=provider; continue; fi
            return 1
          }
        case "$MENU_RESULT" in
          *Continue*) CHOICE_SESSION="continue" ;;
          *Resume*)   CHOICE_SESSION="resume" ;;
          *)          CHOICE_SESSION="new" ;;
        esac
        step=mode ;;

      mode)
        BREADCRUMB="$HARNESS_NAME ▸ Claude ▸ $CHOICE_SESSION"
        local mopts=() modes=() m label
        for m in fast base plan rich ultracode; do
          label=$(harness_mode_label "$m" "$CHOICE_PROVIDER") || continue
          mopts+=("$label"); modes+=("$m")
        done
        mopts+=("🔧 Custom — model/effort 직접 선택"); modes+=("custom")
        menu "Mode" "${mopts[@]}" || { step=session; continue; }
        for i in "${!mopts[@]}"; do
          [ "$MENU_RESULT" = "${mopts[$i]}" ] && { CHOICE_MODE="${modes[$i]}"; break; }
        done
        if [ "$CHOICE_MODE" = "custom" ]; then step=custom_model; else step=final; fi ;;

      custom_model)
        BREADCRUMB="$HARNESS_NAME ▸ Claude ▸ custom"
        if [ "$CHOICE_PROVIDER" = "kiro" ]; then
          menu "Model" "sonnet" "opus" "opusplan" "haiku" || { step=mode; continue; }
        else
          menu "Model" "sonnet" "opus" "opus-1m" "opusplan" "haiku" || { step=mode; continue; }
        fi
        CHOICE_C_MODEL="$MENU_RESULT"
        step=custom_effort ;;

      custom_effort)
        BREADCRUMB="$HARNESS_NAME ▸ Claude ▸ custom ▸ $CHOICE_C_MODEL"
        case "$CHOICE_C_MODEL" in
          haiku)    menu "Effort" "low ← Recommended" "medium" || { step=custom_model; continue; } ;;
          sonnet)   menu "Effort" "low" "medium ← Recommended" "high" || { step=custom_model; continue; } ;;
          opus-1m)  menu "Effort" "medium" "high" "max ← Recommended" || { step=custom_model; continue; } ;;
          opus)     menu "Effort" "medium" "high ← Recommended" "max" || { step=custom_model; continue; } ;;
          opusplan) menu "Effort" "medium" "high ← Recommended" || { step=custom_model; continue; } ;;
          *)        menu "Effort" "low" "medium ← Recommended" "high" || { step=custom_model; continue; } ;;
        esac
        CHOICE_C_EFFORT="${MENU_RESULT%% *}"
        step=final ;;

      final)
        claude_summary
        BREADCRUMB=""
        local fopts=("🚀 Start now" "🔐 Permission: $CHOICE_PERM")
        fopts+=("🌐 Chrome: $( [ "$CHOICE_CHROME" = 1 ] && echo on || echo off )")
        $HAS_HAPPY && fopts+=("📱 Happy wrapper: $( [ "$CHOICE_HAPPY" = 1 ] && echo on || echo off )")
        fopts+=("↩ Back")
        menu "$PLAN_SUMMARY" "${fopts[@]}" || {
          if [ "$CHOICE_MODE" = "custom" ]; then step=custom_effort; else step=mode; fi
          continue
        }
        case "$MENU_RESULT" in
          *Start*) return 0 ;;
          *Permission*)
            menu "Permission mode" \
              "default — 매번 확인" \
              "acceptEdits — 편집만 자동 승인" \
              "dontAsk — 대부분 자동 승인" \
              "bypassPermissions — 모든 확인 건너뛰기 (주의)" || continue
            CHOICE_PERM="${MENU_RESULT%% *}" ;;
          *Chrome*)
            if [ "$CHOICE_CHROME" = 1 ]; then CHOICE_CHROME=0; else CHOICE_CHROME=1; fi ;;
          *Happy*)
            if [ "$CHOICE_HAPPY" = 1 ]; then CHOICE_HAPPY=0; else CHOICE_HAPPY=1; fi ;;
          *Back*)
            if [ "$CHOICE_MODE" = "custom" ]; then step=custom_effort; else step=mode; fi ;;
        esac ;;
    esac
  done
}

# --- Codex flow ------------------------------------------------------------
codex_happy_compatible() {
  # Same constraint as the shortcut path: Happy cannot map subcommands,
  # explicit profiles, work surface, or safety overrides.
  [ "$CHOICE_SESSION" = "new" ] && \
  [ "$CHOICE_CODEX_PROFILE" = "base" ] && \
  [ "$CHOICE_CODEX_SURFACE" = "default" ] && \
  [ "$CHOICE_CODEX_SAFETY" = "default" ]
}

codex_summary() {
  PLAN_SUMMARY="Codex · $CHOICE_SESSION · $CHOICE_CODEX_PROFILE"
  [ "$CHOICE_CODEX_SURFACE" = "work" ] && PLAN_SUMMARY="$PLAN_SUMMARY · work-MCP"
  [ "$CHOICE_CODEX_SAFETY" != "default" ] && PLAN_SUMMARY="$PLAN_SUMMARY · $CHOICE_CODEX_SAFETY"
  [ "$CHOICE_HAPPY" = 1 ] && PLAN_SUMMARY="$PLAN_SUMMARY · happy"
}

collect_codex() {
  local step=session
  while true; do
    case "$step" in
      session)
        BREADCRUMB="$HARNESS_NAME ▸ Codex"
        menu "Session" \
          "🆕 New session" \
          "⏩ Continue last session" \
          "📋 Resume — pick from list" \
          "🔱 Fork last session" || return 1
        case "$MENU_RESULT" in
          *Continue*) CHOICE_SESSION="continue" ;;
          *Resume*)   CHOICE_SESSION="resume" ;;
          *Fork*)     CHOICE_SESSION="fork" ;;
          *)          CHOICE_SESSION="new" ;;
        esac
        step=mode ;;

      mode)
        BREADCRUMB="$HARNESS_NAME ▸ Codex ▸ $CHOICE_SESSION"
        menu "Profile" \
          "⚡ $(codex_profile_label fast)" \
          "⚖️  $(codex_profile_label base)" \
          "🗺️  $(codex_profile_label plan)" \
          "🧠 $(codex_profile_label rich)" \
          "💼 work — base 프로필 + work MCP (Slack/Jira/Notion)" || { step=session; continue; }
        case "$MENU_RESULT" in
          "⚡"*) CHOICE_CODEX_PROFILE="fast"; CHOICE_CODEX_SURFACE="default" ;;
          "🗺"*) CHOICE_CODEX_PROFILE="plan"; CHOICE_CODEX_SURFACE="default" ;;
          "🧠"*) CHOICE_CODEX_PROFILE="rich"; CHOICE_CODEX_SURFACE="default" ;;
          "💼"*) CHOICE_CODEX_PROFILE="base"; CHOICE_CODEX_SURFACE="work" ;;
          *)     CHOICE_CODEX_PROFILE="base"; CHOICE_CODEX_SURFACE="default" ;;
        esac
        step=safety ;;

      safety)
        BREADCRUMB="$HARNESS_NAME ▸ Codex ▸ $CHOICE_CODEX_PROFILE"
        menu "Safety" \
          "🛡  Default — sandboxed, ask on request" \
          "🤖 Full auto (--full-auto)" \
          "🙈 Never ask (-a never)" \
          "⚠️  Bypass — 샌드박스·승인 전부 해제 (위험)" || { step=mode; continue; }
        case "$MENU_RESULT" in
          *Full*)   CHOICE_CODEX_SAFETY="full-auto" ;;
          *Never*)  CHOICE_CODEX_SAFETY="never" ;;
          *Bypass*) CHOICE_CODEX_SAFETY="bypass" ;;
          *)        CHOICE_CODEX_SAFETY="default" ;;
        esac
        step=final ;;

      final)
        codex_summary
        BREADCRUMB=""
        local fopts=("🚀 Start now")
        if $HAS_HAPPY && codex_happy_compatible; then
          fopts+=("📱 Happy wrapper: $( [ "$CHOICE_HAPPY" = 1 ] && echo on || echo off )")
        fi
        fopts+=("↩ Back")
        menu "$PLAN_SUMMARY" "${fopts[@]}" || { step=safety; continue; }
        case "$MENU_RESULT" in
          *Start*) return 0 ;;
          *Happy*)
            if [ "$CHOICE_HAPPY" = 1 ]; then CHOICE_HAPPY=0; else CHOICE_HAPPY=1; fi ;;
          *Back*) step=safety ;;
        esac ;;
    esac
  done
}

# --- Kiro flow -------------------------------------------------------------
kiro_summary() {
  harness_kiro_mode_resolve "${CHOICE_MODE:-base}"
  PLAN_SUMMARY="Kiro · $CHOICE_SESSION · $HARNESS_KIRO_MODEL · $HARNESS_KIRO_EFFORT"
  [ "$CHOICE_KIRO_TRUST" = 1 ] && PLAN_SUMMARY="$PLAN_SUMMARY · trust-all"
}

collect_kiro() {
  local step=session i
  while true; do
    case "$step" in
      session)
        BREADCRUMB="$HARNESS_NAME ▸ Kiro"
        menu "Session" \
          "🆕 New session" \
          "⏩ Continue last session" \
          "📋 Resume — pick from list" || return 1
        case "$MENU_RESULT" in
          *Continue*) CHOICE_SESSION="continue" ;;
          *Resume*)   CHOICE_SESSION="resume" ;;
          *)          CHOICE_SESSION="new" ;;
        esac
        step=mode ;;

      mode)
        BREADCRUMB="$HARNESS_NAME ▸ Kiro ▸ $CHOICE_SESSION"
        local kopts=() modes=() m label
        for m in fast base plan rich; do
          label=$(harness_kiro_mode_label "$m") || continue
          kopts+=("$label"); modes+=("$m")
        done
        menu "Mode" "${kopts[@]}" || { step=session; continue; }
        for i in "${!kopts[@]}"; do
          [ "$MENU_RESULT" = "${kopts[$i]}" ] && { CHOICE_MODE="${modes[$i]}"; break; }
        done
        step=final ;;

      final)
        kiro_summary
        BREADCRUMB=""
        menu "$PLAN_SUMMARY" \
          "🚀 Start now" \
          "🔓 Trust all tools: $( [ "$CHOICE_KIRO_TRUST" = 1 ] && echo on || echo off )" \
          "↩ Back" || { step=mode; continue; }
        case "$MENU_RESULT" in
          *Start*) return 0 ;;
          *Trust*)
            if [ "$CHOICE_KIRO_TRUST" = 1 ]; then CHOICE_KIRO_TRUST=0; else CHOICE_KIRO_TRUST=1; fi ;;
          *Back*) step=mode ;;
        esac ;;
    esac
  done
}

# ===========================================================================
# Assembly + exec — one place per runtime; replay enters here directly.
# ===========================================================================

launch_claude() {
  local provider_url="" gateway_api_key=""
  case "$CHOICE_PROVIDER" in
    kiro)
      [ -f "$HARNESS_DIR/config/.local/kiro-gateway.env" ] && . "$HARNESS_DIR/config/.local/kiro-gateway.env"
      provider_url="${KIRO_GATEWAY_URL:-}"
      gateway_api_key="${KIRO_GATEWAY_API_KEY:-}"
      [ -z "$provider_url" ] && { echo "❌ KIRO_GATEWAY_URL이 설정되지 않았습니다" >&2; return 1; }
      [ "$(probe_wait kiro)" = "up" ] || harness_probe_health "$provider_url" || {
        echo "❌ kiro-gateway에 연결할 수 없습니다 ($provider_url)" >&2; return 1; } ;;
    codex)
      [ -f "$HARNESS_DIR/config/.local/codex-gateway.env" ] && . "$HARNESS_DIR/config/.local/codex-gateway.env"
      provider_url="${CODEX_GATEWAY_URL:-}"
      gateway_api_key="${CODEX_GATEWAY_API_KEY:-}"
      [ -z "$provider_url" ] && { echo "❌ CODEX_GATEWAY_URL이 설정되지 않았습니다" >&2; return 1; }
      [ "$(probe_wait codex)" = "up" ] || harness_probe_health "$provider_url" || {
        echo "❌ codex-gateway에 연결할 수 없습니다 ($provider_url)" >&2; return 1; } ;;
  esac

  local model effort
  if [ "$CHOICE_MODE" = "custom" ]; then
    model="$CHOICE_C_MODEL"; effort="$CHOICE_C_EFFORT"
    if [ "$model" = "opus-1m" ]; then
      case "$CHOICE_PROVIDER" in
        codex) model="opus${CODEX_CONTEXT_SUFFIX:-[1m]}" ;;
        *)     model="claude-opus-4-6[1m]" ;;
      esac
    fi
  else
    harness_mode_resolve "$CHOICE_MODE" "$CHOICE_PROVIDER" || {
      echo "❌ mode '$CHOICE_MODE'는 provider '$CHOICE_PROVIDER'에서 지원되지 않습니다" >&2; return 1; }
    model="$HARNESS_MODE_MODEL"; effort="$HARNESS_MODE_EFFORT"
  fi

  local args=()
  case "$CHOICE_SESSION" in
    continue) args+=(--continue) ;;
    resume)   args+=(--resume) ;;
  esac
  args+=(--model "$model")
  [ "$CHOICE_PERM" != "default" ] && args+=(--permission-mode "$CHOICE_PERM")
  [ "$CHOICE_CHROME" = 1 ] && args+=(--chrome)
  [ -n "$effort" ] && args+=(--effort "$effort")
  args+=(--exclude-dynamic-system-prompt-sections)

  if [ -n "$provider_url" ]; then
    export ANTHROPIC_BASE_URL="$provider_url"
    if [ -n "$gateway_api_key" ]; then
      export ANTHROPIC_AUTH_TOKEN="$gateway_api_key"
      unset ANTHROPIC_API_KEY
    fi
    unset ANTHROPIC_DEFAULT_OPUS_MODEL ANTHROPIC_DEFAULT_SONNET_MODEL ANTHROPIC_DEFAULT_HAIKU_MODEL ANTHROPIC_CUSTOM_HEADERS
    if [ "$CHOICE_PROVIDER" = "codex" ]; then
      [ -n "${CODEX_OPUS_MODEL:-}" ]   && export ANTHROPIC_DEFAULT_OPUS_MODEL="$CODEX_OPUS_MODEL"
      [ -n "${CODEX_SONNET_MODEL:-}" ] && export ANTHROPIC_DEFAULT_SONNET_MODEL="$CODEX_SONNET_MODEL"
      [ -n "${CODEX_HAIKU_MODEL:-}" ]  && export ANTHROPIC_DEFAULT_HAIKU_MODEL="$CODEX_HAIKU_MODEL"
    fi
  fi
  harness_autocompact_pct "$CHOICE_PROVIDER" "${args[@]}"

  local exe="claude"
  [ "$CHOICE_HAPPY" = 1 ] && exe="happy"
  command -v "$exe" >/dev/null 2>&1 || { echo "Error: $exe not found in PATH" >&2; return 1; }

  harness_validate_mcp_local_configs "$HARNESS_DIR" || return 1
  local f
  while IFS= read -r f; do
    [ -n "$f" ] && args+=(--mcp-config "$f")
  done < <(harness_mcp_local_configs "$HARNESS_DIR")

  [ "$CHOICE_MODE" = "ultracode" ] && harness_ultracode_hint

  plan_save
  launch_banner "$PLAN_SUMMARY" "$exe" "${args[@]}"
  exec "$exe" "${args[@]}"
}

launch_codex() {
  if [ "$CHOICE_CODEX_SURFACE" = "work" ]; then
    export HARNESS_CODEX_MCP_PROFILE="work"
  else
    unset HARNESS_CODEX_MCP_PROFILE
  fi
  if [ -x "$LAUNCHER_BIN_DIR/codex-home-prepare.sh" ]; then
    echo "⏳ Codex 홈 준비 중…" >&2
    "$LAUNCHER_BIN_DIR/codex-home-prepare.sh" "$HARNESS_DIR" || return $?
  fi
  export CODEX_HOME="$HARNESS_DIR/.harness/codex"
  harness_export_local_env "$HARNESS_DIR"

  if [ "$CHOICE_HAPPY" = 1 ]; then
    command -v happy >/dev/null 2>&1 || { echo "❌ happy not found in PATH" >&2; return 1; }
    codex_happy_compatible || { echo "❌ Happy는 base 프로필 새 세션에서만 사용할 수 있습니다" >&2; return 1; }
    plan_save
    launch_banner "$PLAN_SUMMARY" happy codex
    cd "$HARNESS_DIR" && exec happy codex
  fi

  [ -n "$CODEX_BIN" ] || { echo "❌ codex not found in PATH" >&2; return 1; }
  local cmd=("$CODEX_BIN")
  case "$CHOICE_SESSION" in
    continue) cmd+=(resume --last) ;;
    resume)   cmd+=(resume) ;;
    fork)     cmd+=(fork --last) ;;
  esac
  cmd+=(--cd "$HARNESS_DIR" -p "$CHOICE_CODEX_PROFILE")
  case "$CHOICE_CODEX_SAFETY" in
    full-auto) cmd+=(--full-auto) ;;
    never)     cmd+=(-a never) ;;
    bypass)    cmd+=(--dangerously-bypass-approvals-and-sandbox) ;;
  esac

  plan_save
  launch_banner "$PLAN_SUMMARY" "${cmd[@]}"
  exec "${cmd[@]}"
}

launch_kiro() {
  if [ -x "$LAUNCHER_BIN_DIR/kiro-home-prepare.sh" ]; then
    "$LAUNCHER_BIN_DIR/kiro-home-prepare.sh" "$HARNESS_DIR" || return $?
  fi
  export KIRO_HOME="$HARNESS_DIR/.harness/kiro"
  harness_export_local_env "$HARNESS_DIR"

  [ -n "$KIRO_BIN" ] || { echo "❌ kiro-cli not found in PATH" >&2; return 1; }
  harness_kiro_mode_resolve "${CHOICE_MODE:-base}"
  local cmd=("$KIRO_BIN" chat)
  case "$CHOICE_SESSION" in
    continue) cmd+=(-r) ;;
    resume)   cmd+=(--resume-picker) ;;
  esac
  cmd+=(--model "$HARNESS_KIRO_MODEL" --effort "$HARNESS_KIRO_EFFORT" --agent harness)
  [ "$CHOICE_KIRO_TRUST" = 1 ] && cmd+=(-a)

  plan_save
  launch_banner "$PLAN_SUMMARY" "${cmd[@]}"
  exec "${cmd[@]}"
}

# ===========================================================================
# Main loop — collect (or replay), then assemble/exec. Backing out of a
# flow's first menu returns here; backing out of the runtime menu exits.
# ===========================================================================
while true; do
  REPLAY=false
  plan_reset
  # A failed previous attempt must not leak provider env into the next one.
  unset ANTHROPIC_BASE_URL ANTHROPIC_AUTH_TOKEN CLAUDE_AUTOCOMPACT_PCT_OVERRIDE HARNESS_CODEX_MCP_PROFILE
  collect_runtime || exit 0

  if ! $REPLAY; then
    case "$CHOICE_RUNTIME" in
      # When the runtime was auto-selected (single option), backing out of the
      # flow's first menu means exit, not an infinite reselect loop.
      claude) collect_claude || { $AUTO_RUNTIME && exit 0; continue; } ;;
      codex)  collect_codex || { $AUTO_RUNTIME && exit 0; continue; } ;;
      kiro)   collect_kiro || { $AUTO_RUNTIME && exit 0; continue; } ;;
      *) echo "Error: unknown runtime '$CHOICE_RUNTIME'" >&2; exit 1 ;;
    esac
  fi

  case "$CHOICE_RUNTIME" in
    claude) launch_claude ;;
    codex)  launch_codex ;;
    kiro)   launch_kiro ;;
  esac
  # launch_* only returns on failure — surface it and let the user retry.
  echo "" >&2
  echo "⚠️  시작 실패 — 메뉴로 돌아갑니다." >&2
done
