# Codex MCP Surface Picker Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a default/work MCP-surface choice to the interactive native Codex launcher flow while preserving every existing command-line launch contract.

**Architecture:** `bin/launcher.sh` owns interactive state. Its native Codex branch will prompt for the MCP surface after model selection, export `HARNESS_CODEX_MCP_PROFILE=work` only for the explicit work choice, and run preparation afterward. Empty/default state remains unset so the existing exact default manifest profile is used. The non-interactive `codex work` path in `bin/aliases.zsh` remains unchanged.

**Tech Stack:** Bash, Zsh, existing shell-test harness, Codex surface manifest environment contract.

## Global Constraints

- Preserve `default` as the safe behavior on cancel or unavailable picker; never silently select `work`.
- Export `HARNESS_CODEX_MCP_PROFILE` before `codex-home-prepare.sh`, and make the same environment visible to the launched Codex command.
- Do not change generated project runtime files directly.
- Preserve command-line `codex work`, raw `codex exec work`, session, model, safety, and Happy behavior.

---

### Task 1: Cover interactive MCP surface selection

**Files:**
- Modify: `test/test-launcher-codex-tui.sh`

**Interfaces:**
- Consumes: `bin/launcher.sh` stdin menu sequence and `HARNESS_CODEX_MCP_PROFILE`.
- Produces: failing regression checks for the `default` and `work` Codex TUI paths.

- [ ] **Step 1: Extend the Codex stub to record the profile environment**

  In the test's `codex` stub, add:

  ```bash
  echo "MCP_PROFILE:${HARNESS_CODEX_MCP_PROFILE:-<UNSET>}"
  ```

- [ ] **Step 2: Add a failing work-selection test**

  Add a new TUI invocation with the input sequence runtime=Codex, new session,
  base model, work surface, default safety. Assert the stub records
  `MCP_PROFILE:work` and the TUI log includes `MCP surface` and `Work`.

  ```bash
  run_tui $'2\n1\n2\n2\n1\n' "$STUB_WORK"
  grep -q '^MCP_PROFILE:work$' "$STUB_WORK"
  ```

- [ ] **Step 3: Run the focused test to verify it fails**

  Run:

  ```bash
  bash test/test-launcher-codex-tui.sh
  ```

  Expected: failure because the current TUI consumes the fourth input as
  Safety and never sets `HARNESS_CODEX_MCP_PROFILE`.

- [ ] **Step 4: Commit the regression test**

  ```bash
  git add test/test-launcher-codex-tui.sh
  git commit -m "test: cover Codex TUI MCP surface choice"
  ```

### Task 2: Implement the native Codex surface picker

**Files:**
- Modify: `bin/launcher.sh` in the native Codex branch, after Mode and before Safety.
- Test: `test/test-launcher-codex-tui.sh`

**Interfaces:**
- Consumes: the `CODEX_MCP_PROFILE` TUI-local variable (`""` or `work`).
- Produces: exported `HARNESS_CODEX_MCP_PROFILE` only when `CODEX_MCP_PROFILE=work`.

- [ ] **Step 1: Add the minimal picker**

  After `CODEX_PROFILE` is selected, add:

  ```bash
  CODEX_MCP_PROFILE=""
  menu "MCP surface" \
    "1. Default — minimal project MCPs" \
    "2. Work — approved work MCPs (Slack, Jira, Notion where configured)" || exit 0
  case "$MENU_RESULT" in
    *Work*) CODEX_MCP_PROFILE="work" ;;
  esac
  ```

- [ ] **Step 2: Export the selected surface immediately before preparation**

  Directly before calling `codex-home-prepare.sh`, add:

  ```bash
  if [[ -n "$CODEX_MCP_PROFILE" ]]; then
    export HARNESS_CODEX_MCP_PROFILE="$CODEX_MCP_PROFILE"
  else
    unset HARNESS_CODEX_MCP_PROFILE
  fi
  ```

- [ ] **Step 3: Run the focused test to verify it passes**

  Run:

  ```bash
  bash test/test-launcher-codex-tui.sh
  ```

  Expected: all prior Codex TUI cases pass, and the new work choice records
  `MCP_PROFILE:work`.

- [ ] **Step 4: Run command-line compatibility coverage**

  Run:

  ```bash
  zsh test/test-launcher-codex-cli.sh
  ```

  Expected: existing `codex work` behavior stays base+work and
  `codex exec work` keeps `work` as prompt text.

- [ ] **Step 5: Commit implementation**

  ```bash
  git add bin/launcher.sh test/test-launcher-codex-tui.sh
  git commit -m "feat: select Codex MCP surface in launcher"
  ```

### Task 3: Document and verify the interactive path

**Files:**
- Modify: `README.md`
- Modify: `docs/codex-integration.md`
- Test: `test/test-launcher-codex-tui.sh`

**Interfaces:**
- Consumes: interactive selection semantics from Task 2.
- Produces: user-facing documentation for default/work selection.

- [ ] **Step 1: Update documentation**

  State that interactive native Codex launches prompt for the MCP surface,
  default uses the minimal project surface, and work exposes only the profile
  members configured by `config/codex-surface.json`.

- [ ] **Step 2: Run the full launcher suite**

  Run:

  ```bash
  ./test/run-all.sh
  ```

  Expected: zero failures.

- [ ] **Step 3: Commit docs and final verification evidence**

  ```bash
  git add README.md docs/codex-integration.md
  git commit -m "docs: explain interactive Codex MCP surfaces"
  ```
