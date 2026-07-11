# Codex surface manifests

Projects with many skills or MCP servers can opt into an exact runtime surface by adding `config/codex-surface.json`. The launcher validates schema version `1`, expands host paths locally, and generates the project-scoped Codex home. Projects without a manifest keep the legacy merge behavior.

## Contract

Every membership list is an allowlist and every `unlisted` policy must be `"disabled"`. Portable paths may use `${HOME}`, `${REPO_ROOT}`, and `${CODEX_HOME}`; committed absolute home paths are unnecessary.

```json
{
  "schema_version": 1,
  "repo": "example",
  "skills": {
    "source_precedence": ["codex-product", "repo-claude", "claude-plugin", "global-agents", "codex-only"],
    "preserve_product_managed": true,
    "disabled_roots": [".agents/skills", "${HOME}/.codex/superpowers/skills"],
    "duplicate_choices": {
      "project:*": "repo-claude",
      "skill-creator": "codex-product",
      "superpowers:*": "claude-plugin:superpowers@superpowers-marketplace"
    },
    "project": {
      "root": ".claude/skills",
      "implicit": ["build"],
      "explicit_only": ["release"],
      "unlisted": "disabled"
    },
    "commands": {
      "root": ".claude/commands",
      "explicit_only": ["daily-pipeline"],
      "unlisted": "disabled"
    },
    "global_agents": {
      "root": "${HOME}/.agents/skills",
      "implicit": [],
      "explicit_only": ["dogfood"],
      "unlisted": "disabled"
    },
    "claude_plugins": {
      "root": "${HOME}/.claude/plugins/cache",
      "unlisted_packages": "disabled",
      "packages": [{
        "id": "superpowers@superpowers-marketplace",
        "implicit": ["brainstorming"],
        "explicit_only": [],
        "unlisted": "disabled"
      }]
    },
    "codex_only": {
      "root": ".codex-only/repos/taste-skill/skills",
      "namespace": "taste-skill",
      "unlisted": "disabled",
      "profiles": {"default": [], "design": ["taste-skill:minimalist-ui"]}
    }
  },
  "mcp": {
    "definition_sources": [".mcp.json", "mcp.local.json", "codex-product"],
    "default_profile": "default",
    "mode": "exact",
    "required_in_all_profiles": ["harness-rag"],
    "profiles": {
      "default": {"enabled": ["harness-rag"]},
      "work": {"enabled": ["computer-use", "harness-rag", "jira"]}
    }
  }
}
```

Membership accepts either a skill directory name or the effective `name` in `SKILL.md`. An optional `codex_only.namespace` prefixes unqualified frontmatter names while leaving already-qualified names intact, so a package can expose stable names such as `taste-skill:minimalist-ui` without rewriting its source. Claude plugin versions are resolved from the newest installed cache entry. If two routes have different `SKILL.md` hashes, generation fails unless `duplicate_choices` selects the exact source. Identical duplicates collapse to the manifest-selected route.

`implicit` skills remain model-visible. `explicit_only` skills receive a generated `agents/openai.yaml` with `allow_implicit_invocation: false`, so `$skill` invocation still works without spending startup description budget. Non-canonical and disabled routes receive exact `[[skills.config]]` entries with their resolved `SKILL.md` path. Manifest-selected paths cannot be overridden by stale runtime `skills.config` entries. Unexpected skill directories inside the generated home are moved intact to `.surface-quarantine/skills/` before the exact surface is rebuilt; source stores are never changed.

`skills.commands.explicit_only` is the fail-closed allowlist for portable `.claude/commands/<name>.md` wrappers. Commands stay explicitly callable without entering the prompt. If a command and canonical project skill have the same name, the project skill wins; the resolver never writes command output through the project-skill symlink.

## Profiles

The default profiles come from the manifest. Select another profile for one launch:

```bash
HARNESS_CODEX_MCP_PROFILE=work wh codex base
HARNESS_CODEX_SKILL_PROFILE=design wh codex rich
```

An unknown profile, a missing profile-only skill, a missing non-product MCP definition, or a profile that omits `required_in_all_profiles` fails before Codex starts. Every MCP definition is rendered with an explicit `enabled = true` or `false`; `computer-use` is the currently recognized product-managed MCP name. When enabled, its bundled plugin skill is reconciled into `skill-catalog.json` after plugin materialization so work-profile prompt audits remain exact.

## Generated state and warm launches

The generated home adds:

```text
skill-catalog.json       selected source paths, hashes, invocation policy, MCP set
surface.config.toml      exact disabled skill paths
.surface-success.json    atomic successful-input fingerprint
.surface-fingerprint-cache.json  source identities and warm watch snapshot
```

The cold fingerprint covers the manifest, relevant launcher code, Claude source/rules/skills/agents/commands, MCP definitions, every installed plugin package's latest skill metadata, and bundled marketplace identity. Skill scripts, references, tests, docs, and assets remain source-linked and do not need regeneration. A lean warm probe validates cached file identities, explicit-only policy files, the semantic TOML skill/MCP/plugin/config policy, managed skill inventory, watched directory topology, bundled product-skill digests, and hashes of launcher-owned outputs such as `AGENTS.md` and `hooks.json`. New unapproved plugins, poisoned markers, hidden MCP tables, and generated-home drift therefore force full resolution without rescanning plugin payloads. Auth contents, sessions, hook trust state, and generated output mtimes do not invalidate it. A missing managed skill link also forces a rebuild. The previous success stamp is removed before mutation, so an interrupted or failed rebuild cannot advertise a warm success.

Do not edit generated files. Change the manifest or source and run the launcher again.
