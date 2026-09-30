# herdr web ui

[herdr web ui](https://github.com/devswha/herdr-web-ui) is a herdr plugin: a browser client with chat, a live terminal, approval cards, and a file browser for every agent pane. `harness-herdr-web` installs it **local-only, behind a token**, and checks that it stays that way.

Supported: the pinned release `v0.3.34` (commit `efd017b1a42c`) on macOS, with herdr 0.9.1 and Bun 1.4 or later.

## Why a wrapper

Agent panes on a harness host usually run with automatic approval, so anything that can type into a pane can run commands as you. Upstream serves local callers without authentication when `HERDR_WEB_TOKEN` is unset. The wrapper therefore always sets a token of at least 32 characters, which upstream then requires from local callers too.

**A machine where Tailscale reports a login is not supported** until a later reviewed release. `check` and `install` fail there, whether Tailscale is running or stopped.

The token does not protect against local agents or processes running as you: they can read the env file.

## Commands

```bash
harness-herdr-web install    # gate, configure, install the pinned release, start it, then check
harness-herdr-web check      # OK/WARN/FAIL report; exit 1 on FAIL
harness-herdr-web configure  # enforce the managed keys and file modes
harness-herdr-web token --copy   # put the token on the clipboard for the first browser login
```

Open `http://127.0.0.1:7317` (or your `PORT`) and paste the token when asked. The session cookie is scoped to `127.0.0.1`, so every local port receives it. `pbcopy` also syncs through Universal Clipboard.

`install` refuses before installing anything in two cases: Tailscale reports a login for this machine, or `bun --version` is below 1.4 (fix with `bun upgrade`). herdr runs plugin commands with its own `PATH`, so `bun` must be reachable from the herdr server as well. If the build fails, check `herdr plugin log devswha.herdr-web-ui`. `install --ref <tag>` installs another ref and warns that the ref is unreviewed.

## Managed configuration

The plugin reads `$(herdr plugin config-dir devswha.herdr-web-ui)/env` and then `.env`; values in `.env` win. `configure` writes only `env`:

| Key | Value |
| --- | --- |
| `HERDR_WEB_TOKEN` | Kept if it has at least 32 characters, otherwise replaced with 64 hex characters (never printed) |
| `HOST` | `127.0.0.1` |
| `HERDR_WEB_AUTO_UPDATE` | `0`. Upstream only auto-installs on `1`. |

`configure` also has these rules:

- It keeps other lines as they are, and replaces duplicate managed keys with one line.
- It sets the directory to `0700` and the files to `0600`.
- It refuses to write when:
  - a path is a symlink or is not owned by you;
  - `env` has an `export <managed key>` line (upstream reads `export HOST` as a different key);
  - `.env` sets a managed key.

After `configure` changes a running server's settings, restart the plugin:

```bash
herdr plugin action invoke devswha.herdr-web-ui.stop
herdr plugin action invoke devswha.herdr-web-ui.start
```

## What `check` verifies

- The effective token (from `env`, then `.env`) exists and has at least 32 characters.
- The effective `HOST` is `127.0.0.1`, `HERDR_WEB_AUTO_UPDATE` is not `1`, and the directory and files have their modes and are not symlinks.
- Tailscale does not report a login for this machine. The CLI is looked up on `PATH` or in `/Applications/Tailscale.app`. Whether the backend is running or stopped makes no difference.
- The installed checkout is the pinned commit. A different commit gives a WARN.
- `GET /api/health?scope=bridge` on the running server, sent without credentials, returns `auth.authenticated: false`. A server that accepts it, a missing `auth`, or a timeout gives a FAIL. A refused connection gives a WARN (not running).
- An in-app update that is running a different revision gives a WARN. The in-app updater still offers new releases in Settings; installing one there leaves the reviewed build.

## Do not

- Run upstream's `install.sh` or `bun scripts/plugin.ts phone`. Both run `tailscale serve --bg --yes`.
- Expose the port with `tailscale serve`, Funnel, a LAN bind, or a reverse proxy.
- Set `HERDR_WEB_AUTO_UPDATE=1`.

To remove the plugin:

```bash
herdr plugin action invoke devswha.herdr-web-ui.stop
herdr plugin uninstall devswha.herdr-web-ui
```
