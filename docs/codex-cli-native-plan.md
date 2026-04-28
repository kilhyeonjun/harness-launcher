# kh/gd/gp Codex CLI Native Support — Implementation Plan

Status: in-progress (feature/codex-cli-native).
Owner: hyeonjun.
Last updated: 2026-04-28.

## 1. Goal / Non-goal

### Goal
- `kh`, `gd`, `gp` launcher가 Codex CLI를 네이티브 runtime으로 지원한다.
- 기존 Claude Code + Codex gateway 경로는 `*-gateway` 이름으로 보존한다.
- TUI를 provider-first → runtime-first로 재구성한다 (Claude Code vs Codex CLI).
- Claude 전용 surface(`CLAUDE.md`, `.mcp.json`, `.claude/skills`)를 단일 진실원으로 유지하고 adapter가 변환한다.
- 수동 동기화 파일을 만들지 않는다.

### Non-goal
- Claude Code의 hook lifecycle을 Codex CLI에 1:1 이식하지 않는다.
- 글로벌 `~/.codex/config.toml`을 하네스별 MCP로 오염시키지 않는다.
- `CLAUDE.md` / `AGENTS.md` / `HARNESS.md` 다중 수동 관리 구조를 만들지 않는다.

## 2. Codex CLI 0.125.0 실측 사실 (2026-04-28)

확인된 옵션:
- `-c key=value` (TOML 리터럴, 도트경로, 반복 가능)
- `-C, --cd <DIR>` 모든 서브커맨드에서 동작
- `-p, --profile <NAME>` config.toml의 `[profiles.<name>]` 사용
- `-s, --sandbox` (`read-only` | `workspace-write` | `danger-full-access`)
- `-a, --ask-for-approval` (`untrusted` | `on-request` | `never`; `on-failure`는 DEPRECATED)
- `--full-auto`, `--dangerously-bypass-approvals-and-sandbox`
- `resume [SESSION_ID] [PROMPT]`, `--last`, `--all`
- `fork [SESSION_ID] [PROMPT]`, `--last`
- `mcp list/get/add/remove`
- `--no-alt-screen` (Zellij 호환)
- `CODEX_HOME` 환경변수 → config 디렉토리 통째 우회 (per-harness 격리 가능 핵심)

`codex mcp add`로 검증된 `[mcp_servers.<name>]` TOML schema:
```toml
[mcp_servers.atlassian]
url = "http://localhost:38100/mcp"

[mcp_servers.context7]
command = "npx"
args = ["-y", "@upstash/context7-mcp"]

[mcp_servers.google_workspace]
command = "bash"
args = ["core/bin/start-google-workspace-mcp.sh"]
[mcp_servers.google_workspace.env]
KEY = "value"
```

## 3. Desired UX

### Shortcut commands

```
kh codex                # Codex CLI native
kh codex base           # Codex CLI native, base mode
kh codex plan           # Codex CLI native, plan mode
kh codex resume         # Codex CLI resume picker
kh codex-gateway        # Claude Code + Codex gateway (legacy)
kh codex-gateway base   # Same legacy w/ mode
kh                      # TUI
kh base                 # Claude Code direct, base mode
kh kiro rich            # Claude Code + Kiro gateway
```

`gd`, `gp`도 동일.

### TUI runtime-first

```
Select runtime
1. Claude Code
2. Codex CLI
```

Claude branch는 기존 provider/session/mode/permission/chrome/happy 흐름 유지.
Codex branch:
```
Session: New / Resume last / Resume picker / Fork last
Mode: Fast / Base / Plan / Rich / Custom
Safety: Default / Full auto / Never approval / Bypass
```

## 4. Mode → Codex profile mapping

`$CODEX_HOME/config.toml`에 다음 profile 사전 정의 (launcher가 생성):

```toml
model = "gpt-5.5"
model_reasoning_effort = "medium"

[profiles.fast]
model = "gpt-5.5"
model_reasoning_effort = "low"

[profiles.base]
model = "gpt-5.5"
model_reasoning_effort = "medium"

[profiles.plan]
model = "gpt-5.5"
model_reasoning_effort = "xhigh"
sandbox_mode = "read-only"
approval_policy = "on-request"

[profiles.rich]
model = "gpt-5.5"
model_reasoning_effort = "xhigh"
```

Launcher는 `codex -p fast --cd "$HARNESS_DIR"`처럼 profile만 넘기고 model/effort 인자 조립 안 함.

### Session mapping
```
new           → codex --cd "$HARNESS_DIR" -p <mode>
resume last   → codex resume --last --cd ... -p <mode>
resume picker → codex resume --cd ... -p <mode>
fork last     → codex fork --last --cd ... -p <mode>
```

## 5. MCP Strategy — Per-harness CODEX_HOME (Option B, 확정)

**선택 사유**: §8 Option A(`-c` 반복 주입)는 array/env 인자 quoting이 zsh에서 취약. Option C(`~/.codex/config.toml` managed block)는 글로벌 drift 위험. Option B는 `CODEX_HOME` env로 config dir을 통째 격리 → 글로벌 무오염, per-harness session/history 격리, MCP scope 명확.

### CODEX_HOME 위치
```
$HARNESS_DIR/.harness/codex/
  config.toml          # 자동 생성 (model defaults + profiles + mcp_servers)
  AGENTS.md  → ../../CLAUDE.md   (symlink)
  skills     → ~/.codex/skills    (symlink, 글로벌 skill 공유)
  auth.json  → ~/.codex/auth.json (symlink, 로그인 공유)
  sessions/            # Codex 자동 생성 (per-harness 격리)
  history.jsonl        # Codex 자동 생성
```

`.harness/codex/`는 각 하네스 `.gitignore`에 추가. `.harness/`는 향후 다른 어댑터(예: Cursor, Continue)가 들어올 때도 같은 패턴 사용 가능한 namespace.

### 생성 시점
launcher가 `codex` 실행 직전에 `bin/codex-home-prepare.sh "$HARNESS_DIR"` 호출. 멱등 (이미 존재해도 `.mcp.json` 변경 감지 시 재생성).

### `.mcp.json` → TOML 변환
입력 (예: kh):
```json
{ "mcpServers": {
  "atlassian":  { "type": "http", "url": "http://localhost:38100/mcp" },
  "google_workspace": { "command": "bash", "args": ["core/bin/start-google-workspace-mcp.sh"] },
  "jobs-mcp":   { "type": "http", "url": "https://jobs.pathsdog.com/mcp" },
  "context7":   { "command": "npx", "args": ["-y", "@upstash/context7-mcp"] }
}}
```
출력은 §2의 schema 그대로. HTTP는 `url = "..."`만, stdio는 `command` + `args` (+ optional `env` 테이블).

## 6. AGENTS.md 전략

각 하네스 root에 `AGENTS.md → CLAUDE.md` symlink 추가. Codex는 `--cd` 디렉토리에서 AGENTS.md를 읽음. `CLAUDE.md` 내용은 1차에서 그대로 노출, 향후 generic화는 별도 task.

CODEX_HOME 안에도 `AGENTS.md → ../../CLAUDE.md` symlink로 이중 노출 (Codex global agents.md + project agents.md 모두 같은 파일 가리킴).

## 7. Hook 전략 (부분 parity 수용)

| Claude Hook | Codex 매핑 |
|---|---|
| SessionStart | launcher 사전 단계 (codex 실행 전 sh 블록) |
| Stop | `exec` 대신 child + trap (선택, 1차 비대상) |
| Edit 보호 | `--sandbox read-only` (plan) / `workspace-write` (default) / `danger-full-access` (rich) |
| Destructive 차단 | `--ask-for-approval untrusted` |
| PreToolUse / PostToolUse / UserPromptSubmit | **parity 없음 — 1차 미지원, 수용** |

## 8. Skill 전략

`$HARNESS_DIR/.harness/codex/skills → ~/.codex/skills` symlink (글로벌 codex skill 공유). `.claude/skills` 호환은 SKILL.md frontmatter 차이 검증 필요 → 별도 task.

## 9. Commands 전략

`.claude/commands/*.md`는 Claude 전용 슬래시 템플릿. Codex CLI는 동일 시스템 미지원. 1차에서는 미러링하지 않음. 후속에서 TUI command picker가 선택 템플릿을 initial prompt로 주입하는 방식 검토.

## 10. Implementation files

수정 대상 (소스 repo):
```
projects/harness-launcher/bin/aliases.zsh
projects/harness-launcher/bin/launcher.sh
projects/harness-launcher/bin/codex-home-prepare.sh   # NEW
projects/harness-launcher/test/test-launcher-codex-gateway.sh   # RENAME from test-launcher-codex.sh
projects/harness-launcher/test/test-launcher-codex-cli.sh       # NEW
projects/harness-launcher/test/test-codex-home-prepare.sh       # NEW
projects/harness-launcher/test/test-aliases-register.sh         # update completion expectations
projects/harness-launcher/install.sh                            # copy new bin
projects/harness-launcher/README.md                             # document split
```

각 하네스 (kh, gp, gd):
```
AGENTS.md          → CLAUDE.md (NEW symlink)
.gitignore         + .harness/codex/ (NEW)
```

## 11. aliases.zsh 변경

기존 단일 분기:
- 첫 인자 `kiro` → Claude Code via Kiro gateway
- 첫 인자 `codex` → Claude Code via Codex gateway

변경 후:
- 첫 인자 `kiro` → Claude Code via Kiro gateway (변경 없음)
- 첫 인자 `codex-gateway` → Claude Code via Codex gateway (이름만 변경, behavior 동일)
- 첫 인자 `codex` → Codex CLI native (신규)

helper 분리:
- `_harness_launcher_run_claude` (기존 로직 추출)
- `_harness_launcher_run_codex_cli` (신규)

## 12. launcher.sh 변경

STEP -1 (신규): runtime 선택 (Claude Code | Codex CLI).
- Claude → 기존 STEP 0~8 흐름 그대로.
- Codex → STEP C1 (session) → C2 (mode) → C3 (safety) → exec codex.

## 13. Test plan (TDD)

### Rename
- `test-launcher-codex.sh` → `test-launcher-codex-gateway.sh` (의미 보존)

### New: `test-launcher-codex-cli.sh`
검증:
- `kh codex base` 실행 시 `codex` 호출 (claude 아님)
- `--cd "$HARNESS_DIR"` 또는 cwd가 harness root
- `-p <mode>` 매핑 (fast/base/plan/rich)
- `plan` mode → `--sandbox read-only` 또는 profile에 sandbox_mode 포함
- `kh codex resume` → `codex resume`
- `kh codex continue` → `codex resume --last`
- `CODEX_HOME=$HARNESS_DIR/.harness/codex` 환경변수 설정

### New: `test-codex-home-prepare.sh`
검증:
- `.mcp.json` 4종 input → 정확한 TOML output (HTTP/stdio/env 변형)
- AGENTS.md symlink 생성
- auth.json symlink 생성 (소스가 존재할 때)
- skills symlink 생성
- 멱등 (재실행 시 동일 결과)
- `.mcp.json` 수정 후 재실행 시 config.toml 갱신

### Update: `test-aliases-register.sh`
completion shortcuts에 `codex-gateway` 추가, `codex` 설명 변경.

## 14. Rollout 순서 (Recommended First Cut, 수정판)

1. plan doc 저장 (이 파일).
2. test-launcher-codex.sh 리네임 (Task 4).
3. test-launcher-codex-cli.sh 작성 (failing) (Task 5).
4. aliases.zsh 분기 추가 (Task 6) — Task 5 통과시킴.
5. test-codex-home-prepare.sh 작성 (failing) (Task 7a).
6. bin/codex-home-prepare.sh 구현 (Task 7b) — Task 7a 통과시킴.
7. launcher.sh runtime-first 리팩토링 (Task 8) + 통합 테스트.
8. README + completion 갱신 (Task 9).
9. 전체 테스트 + 커밋 + install (Task 10).
10. kh/gp/gd AGENTS.md symlink + .gitignore (Task 11) — 각 하네스에서 auto-deliver.

## 15. Migration / Compatibility

Breaking:
- `kh codex`의 의미가 "Claude Code + Codex gateway"에서 "Codex CLI native"로 변경.

Mitigation:
- 기존 동작은 `kh codex-gateway`로 보존.
- README에 마이그레이션 노트.
- TUI 라벨: "Codex CLI" vs "Codex gateway for Claude Code"로 명확히 분리.

## 16. 기록된 결정 (§18 open questions 해소)

| Question | Decision |
|---|---|
| MCP injection (Option A/B/C) | **Option B**: per-harness CODEX_HOME |
| Hook parity | 부분 parity 수용, tool-level hook 미지원 |
| Codex skill 지원 | `~/.codex/skills` symlink (글로벌 공유), `.claude/skills` 호환은 후속 |
| AGENTS.md symlink | 각 하네스 root + CODEX_HOME 양쪽에 symlink |
| `model_reasoning_effort = "xhigh"` | accept 확인됨 (0.125.0 parse OK) |

## 17. 환경 노트

- Mac mini (penguin): codex 0.114.0 (개발 환경). bash 3.2 (provider-probe.sh 비호환).
- MacBook (gameduo): codex 0.125.0 (검증 환경). bash 5+ 가능.
- 작업 흐름: Mac mini에서 개발/안정화 → MacBook으로 pull/적용.
- Mac mini에 gp/gd 하네스 부재 → 해당 분 AGENTS.md 작업은 MacBook에서 별도.
