## OMP Native Features

Vibe and advisor are off by default; never assume a feature is enabled or turn it on yourself.
When a task clearly fits one, propose the exact command with a one-line reason and its cost, then ask:

- `/vibe` — several independent workstreams that can run in parallel (cost: extra agent sessions and tokens).
- `/advisor on` — a high-risk change: security, data loss, public contracts, or architecture (cost: a second model reviews each turn).
- `/review` — before delivering a non-trivial diff (cost: one review pass).

Run the command only after the user agrees.
