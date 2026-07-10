# Pull request

## Problem

<!-- What problem does this change solve? Link an issue when one exists. -->

## Behavior

<!-- Describe the user-visible behavior and any compatibility or security implications. -->

## Verification

<!-- List exact commands and manual checks. -->

- [ ] `./test/run-all.sh`
- [ ] Bash syntax checks
- [ ] Zsh syntax checks
- [ ] Manual smoke test, if behavior changed

## Checklist

- [ ] The diff is scoped to one problem.
- [ ] New behavior has a regression test.
- [ ] README/docs match the implementation.
- [ ] Public files contain no credentials, private URLs, account identifiers, or personal paths.
- [ ] Runtime-home, auth, MCP, plugin, and sandbox boundaries remain explicit.
- [ ] Breaking changes include a migration note.
