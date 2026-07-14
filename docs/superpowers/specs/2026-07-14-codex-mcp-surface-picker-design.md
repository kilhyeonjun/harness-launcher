# Codex MCP Surface Picker Design

## Goal

Let a user choose the exact Codex MCP surface from the launcher's interactive
flow, without changing the default surface or breaking existing command-line
forms.

## Scope

The interactive Codex path will offer two surfaces before it prepares the
project-scoped Codex home:

- `default`: the existing minimal surface. This remains the default when the
  user cancels, does not make a selection, or uses existing non-work commands.
- `work`: the manifest's work MCP profile, which exposes the approved work
  integrations such as Slack where the registered project defines them.

The existing `<prefix> codex work` command remains the non-interactive shortcut
for the `work` surface and continues to use the base Codex model profile.

## Design

The TUI's native Codex branch will select an MCP surface independently from the
Codex model profile. The chosen value is exported as
`HARNESS_CODEX_MCP_PROFILE` immediately before the Codex home preparation
step. That makes the generated configuration and the launched Codex process
use the same exact manifest profile.

The picker is skipped for paths that already have an explicit surface command
or are raw Codex subcommands. This preserves `codex work`, `codex exec ...`,
resume commands, and every existing CLI contract.

## Error Handling

If the user cancels the picker or the picker utility is unavailable, the
launcher uses `default`; it must never silently choose `work`. A failed Codex
home preparation still stops the launch before Codex starts.

## Verification

TUI tests will prove that choosing `work` exports it before preparation and
Codex execution, that choosing/cancelling to `default` leaves the variable
unset, and that the command-line work shortcut remains unchanged. The focused
launcher test suite will run after the change.
