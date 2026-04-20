# harness-launcher

Universal launcher for kilhyeonjun-harness / gameduo-*-harness repos.

## Install

```bash
brew tap kilhyeonjun/tap
brew install harness-launcher
```

## Usage

Each harness declares its identity in `config/launcher.env`:

```shell
HARNESS_NAME="kilhyeonjun harness"
HARNESS_PREFIX="kh"
```

Register it in your shell:

```zsh
source "$(brew --prefix)/share/harness-launcher/aliases.zsh"
harness_register "$HOME/kilhyeonjun-harness"
harness_register "$HOME/gameduo-personal-harness"
harness_register "$HOME/gameduo-platform-harness"
```

This creates `kh`, `gd`, `gp` functions with tab completion.

If `happy` is installed, the interactive launcher path (`kh`, `gd`, `gp` with no shortcut args) asks whether to route the session through Happy for mobile control. Shortcut invocations like `kh base` or `gd codex rich` continue to launch Claude directly with no extra prompt.
