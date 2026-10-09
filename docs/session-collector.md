# Optional native response collection

A profile may opt in with `config/ssot-session-hooks.json`:

```json
{"enabled": true}
```

Only this exact object with a boolean true enables the integration. Missing,
malformed or unknown-key files disable it; process environment is ignored.
Other runtime integrations keep their existing launcher.env opt-ins.

Claude launch settings and generated Codex hooks append UserPromptSubmit and
Stop callbacks after existing hooks. They invoke the optional host callback
`$HOME/.local/share/harness-service/kh-dev/bin/harness-session-hook` with
`--runtime claude` or `--runtime codex`. Both callbacks discard output and errors
and always exit successfully, including when the host callback is absent.
They never block continuation or change permissions. Codex's normal hook trust
still applies; changed opt-ins invalidate the warm home fingerprint.

The host callback owns collection policy, private durable delivery and
authentication. It must bind the native session to the intended profile using
the launch record; the launcher does not forward transcripts or credentials.
The callback path is intentionally optional, so a host without the service
does not gain a server connection. Enable only in the profile and host where
session collection is intended. Native MCP registration is separate and uses
the profile's existing exact server definitions.

Remove the JSON file or set enabled to false to disable future callbacks, then
regenerate the Codex home and refresh native hook trust. Already running,
pinned sessions retain their original hooks. No hook is added to other profiles
by installing this launcher release.
