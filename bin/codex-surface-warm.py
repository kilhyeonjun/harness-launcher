#!/usr/bin/env python3
"""Lean warm-path validator for manifest-managed Codex homes."""

import json
import hashlib
import os
import re
import sys
import tomllib


SURFACE_FIXED_OUTPUTS = (
    "AGENTS.md",
    "hooks.json",
    "skill-catalog.json",
    "surface.config.toml",
    "fast.config.toml",
    "base.config.toml",
    "plan.config.toml",
    "rich.config.toml",
    os.path.join("skills", ".harness-managed"),
)


def cold():
    raise SystemExit(3)


def load_object(path):
    try:
        with open(path, encoding="utf-8") as stream:
            value = json.load(stream)
    except (OSError, UnicodeDecodeError, json.JSONDecodeError):
        cold()
    if not isinstance(value, dict):
        cold()
    return value


def identity(path):
    try:
        stat = os.stat(path)
    except OSError:
        return None
    return [
        stat.st_dev,
        stat.st_ino,
        stat.st_size,
        stat.st_mtime_ns,
        stat.st_ctime_ns,
        os.path.realpath(path),
    ]


def config_matches(codex_home, catalog):
    try:
        with open(os.path.join(codex_home, "config.toml"), "rb") as stream:
            config = tomllib.load(stream)
    except (OSError, tomllib.TOMLDecodeError):
        return False

    allowed_root_keys = {
        "model",
        "model_reasoning_effort",
        "features",
        "marketplaces",
        "plugins",
        "tui",
        "mcp_servers",
        "skills",
        "hooks",
    }
    if set(config) - allowed_root_keys:
        return False
    hooks = config.get("hooks")
    if hooks is not None and (
        not isinstance(hooks, dict) or set(hooks) - {"state"}
    ):
        return False
    skills_table = config.get("skills")
    if skills_table is not None and (
        not isinstance(skills_table, dict) or set(skills_table) - {"config"}
    ):
        return False
    if config.get("model") != "gpt-5.6-terra":
        return False
    if config.get("model_reasoning_effort") != "medium":
        return False
    if config.get("features") != {
        "apps": False,
        "goals": True,
        "hooks": True,
        "multi_agent": True,
    }:
        return False
    marketplaces = config.get("marketplaces") or {}
    if not isinstance(marketplaces, dict):
        return False
    if marketplaces.get("openai-bundled") != {
        "source_type": "local",
        "source": os.path.join(
            os.path.expanduser("~"),
            ".codex",
            ".tmp",
            "bundled-marketplaces",
            "openai-bundled",
        ),
    }:
        return False
    if config.get("tui") != {
        "status_line": [
            "model-with-reasoning",
            "current-dir",
            "git-branch",
            "run-state",
            "context-remaining",
            "context-used",
        ]
    }:
        return False

    configured_paths = {}
    skill_configs = (config.get("skills") or {}).get("config") or []
    if not isinstance(skill_configs, list):
        return False
    for item in skill_configs:
        if not isinstance(item, dict):
            return False
        path = item.get("path")
        enabled = item.get("enabled")
        if not isinstance(path, str) or not isinstance(enabled, bool):
            return False
        configured_paths.setdefault(path, []).append(enabled)
    disabled_paths = set(catalog.get("disabled_skill_paths") or [])
    for path in disabled_paths:
        if configured_paths.get(path) != [False]:
            return False
    for skill in catalog.get("skills") or []:
        for path in (skill.get("source_path"), skill.get("exposed_path")):
            if path and path not in disabled_paths and path in configured_paths:
                return False

    mcp = catalog.get("mcp") or {}
    enabled_servers = set(mcp.get("enabled") or [])
    definitions = mcp.get("definitions") or {}
    configured_mcp = config.get("mcp_servers") or {}
    if not isinstance(configured_mcp, dict) or set(configured_mcp) != set(definitions):
        return False
    for name, server in configured_mcp.items():
        if not isinstance(server, dict):
            return False
        if server.get("enabled") is not (name in enabled_servers):
            return False

    plugins = config.get("plugins") or {}
    if not isinstance(plugins, dict):
        return False
    bundled_plugins = {
        name: value
        for name, value in plugins.items()
        if isinstance(name, str) and name.endswith("@openai-bundled")
    }
    expected_bundled = {
        "computer-use@openai-bundled": "computer-use" in enabled_servers,
        "chrome@openai-bundled": False,
    }
    if set(bundled_plugins) != set(expected_bundled):
        return False
    for plugin, expected in (
        ("computer-use@openai-bundled", "computer-use" in enabled_servers),
        ("chrome@openai-bundled", False),
    ):
        value = bundled_plugins.get(plugin)
        if not isinstance(value, dict) or value.get("enabled") is not expected:
            return False
    return True


def managed_config_projection_sha256(codex_home):
    try:
        with open(os.path.join(codex_home, "config.toml"), "rb") as stream:
            config = tomllib.load(stream)
        config.pop("hooks", None)
        config.pop("skills", None)
        marketplaces = config.get("marketplaces")
        if isinstance(marketplaces, dict):
            config["marketplaces"] = {
                key: value for key, value in marketplaces.items()
                if key == "openai-bundled"
            }
        plugins = config.get("plugins")
        if isinstance(plugins, dict):
            config["plugins"] = {
                key: value for key, value in plugins.items()
                if isinstance(key, str) and key.endswith("@openai-bundled")
            }
        payload = json.dumps(
            config,
            ensure_ascii=False,
            separators=(",", ":"),
            sort_keys=True,
        ).encode()
    except (OSError, TypeError, tomllib.TOMLDecodeError):
        cold()
    return hashlib.sha256(payload).hexdigest()


def sha256_signature(path):
    try:
        if os.path.islink(path):
            return "symlink:" + os.readlink(path)
        digest = hashlib.sha256()
        with open(path, "rb") as stream:
            for chunk in iter(lambda: stream.read(65536), b""):
                digest.update(chunk)
        return "sha256:" + digest.hexdigest()
    except OSError:
        cold()


def output_signatures(codex_home):
    signatures = {}

    def add(relative, required=True):
        path = os.path.join(codex_home, relative)
        if os.path.islink(path) or os.path.isfile(path):
            signatures[relative] = sha256_signature(path)
        elif required:
            cold()

    for relative in SURFACE_FIXED_OUTPUTS:
        add(relative)

    marker_path = os.path.join(codex_home, "skills", ".harness-managed")
    try:
        with open(marker_path, encoding="utf-8") as stream:
            managed_skills = [line.strip() for line in stream if line.strip()]
    except (OSError, UnicodeDecodeError):
        cold()
    for name in managed_skills:
        if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]*", name):
            cold()
        root = os.path.join(codex_home, "skills", name)
        relative_root = os.path.join("skills", name)
        if os.path.islink(root):
            add(relative_root)
            continue
        if not os.path.isdir(root):
            cold()
        for current, directories, files in os.walk(root, followlinks=False):
            for directory in list(directories):
                candidate = os.path.join(current, directory)
                if os.path.islink(candidate):
                    add(os.path.relpath(candidate, codex_home))
                    directories.remove(directory)
            for filename in files:
                add(os.path.relpath(os.path.join(current, filename), codex_home))

    agent_marker = os.path.join(codex_home, "agents", ".harness-managed")
    managed_agents = []
    if os.path.isfile(agent_marker):
        add(os.path.join("agents", ".harness-managed"))
        try:
            with open(agent_marker, encoding="utf-8") as stream:
                managed_agents = [line.strip() for line in stream if line.strip()]
        except (OSError, UnicodeDecodeError):
            cold()
        for name in managed_agents:
            if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]*\.toml", name):
                cold()
            add(os.path.join("agents", name))
    agents_root = os.path.join(codex_home, "agents")
    try:
        actual_agents = {
            name
            for name in os.listdir(agents_root)
            if name.endswith(".toml")
            and os.path.isfile(os.path.join(agents_root, name))
        }
    except FileNotFoundError:
        actual_agents = set()
    except OSError:
        cold()
    if actual_agents != set(managed_agents):
        cold()
    return dict(sorted(signatures.items()))


def main():
    if len(sys.argv) != 7:
        print(
            "usage: codex-surface-warm.py STAMP CACHE CODEX_HOME MANIFEST SKILL_PROFILE MCP_PROFILE",
            file=sys.stderr,
        )
        return 2
    stamp_path, cache_path, codex_home, manifest_path, skill_profile, mcp_profile = sys.argv[1:]
    stamp = load_object(stamp_path)
    cache = load_object(cache_path)
    manifest = load_object(manifest_path)
    fingerprint = cache.get("fingerprint")
    watch = cache.get("watch")
    directory_entries = cache.get("directory_entries")
    if (
        cache.get("schema_version") != 3
        or not isinstance(fingerprint, dict)
        or not isinstance(watch, dict)
        or not isinstance(directory_entries, dict)
    ):
        cold()
    expected_mcp = mcp_profile or (manifest.get("mcp") or {}).get("default_profile")
    if fingerprint.get("skill_profile") != skill_profile or fingerprint.get("mcp_profile") != expected_mcp:
        cold()
    for key in ("schema_version", "digest", "skill_profile", "mcp_profile"):
        if stamp.get(key) != fingerprint.get(key):
            cold()
    for path, expected in watch.items():
        if identity(path) != expected:
            cold()
    for path, expected in directory_entries.items():
        try:
            actual = sorted(
                name
                for name in os.listdir(path)
                if os.path.isdir(os.path.join(path, name))
            )
        except FileNotFoundError:
            actual = None
        except OSError:
            cold()
        if actual != expected:
            cold()

    required = [
        "AGENTS.md",
        "config.toml",
        "hooks.json",
        "skill-catalog.json",
        "surface.config.toml",
        os.path.join("skills", ".harness-managed"),
        "fast.config.toml",
        "base.config.toml",
        "plan.config.toml",
        "rich.config.toml",
    ]
    if not all(os.path.isfile(os.path.join(codex_home, path)) for path in required):
        cold()
    expected_outputs = stamp.get("output_signatures")
    if not isinstance(expected_outputs, dict):
        cold()
    if output_signatures(codex_home) != expected_outputs:
        cold()
    if managed_config_projection_sha256(codex_home) != stamp.get(
        "config_projection_sha256"
    ):
        cold()
    catalog = load_object(os.path.join(codex_home, "skill-catalog.json"))
    if catalog.get("skill_profile") != fingerprint.get("skill_profile"):
        cold()
    if (catalog.get("mcp") or {}).get("profile") != fingerprint.get("mcp_profile"):
        cold()
    if not config_matches(codex_home, catalog):
        cold()
    skills_root = os.path.abspath(os.path.join(codex_home, "skills"))
    expected_managed = []
    for skill in catalog.get("skills") or []:
        exposed = skill.get("exposed_path", "")
        source = skill.get("source_path", "")
        if not os.path.isfile(exposed) or not os.path.isfile(source):
            cold()
        product_plugin = str(skill.get("source", "")).startswith(
            "codex-product-plugin:"
        )
        if os.path.abspath(source) not in watch and not product_plugin:
            cold()
        if product_plugin:
            try:
                with open(source, "rb") as stream:
                    digest = hashlib.sha256(stream.read()).hexdigest()
            except OSError:
                cold()
            if digest != skill.get("sha256"):
                cold()
        exposed_parent = os.path.abspath(os.path.dirname(exposed))
        try:
            managed = os.path.commonpath((skills_root, exposed_parent)) == skills_root
        except ValueError:
            managed = False
        if managed:
            expected_managed.append(os.path.basename(exposed_parent))
            if os.path.islink(exposed_parent):
                if os.path.realpath(exposed) != os.path.realpath(source):
                    cold()
            elif not os.path.isfile(
                os.path.join(exposed_parent, ".harness-surface-wrapper")
            ):
                cold()
        if skill.get("invocation") == "explicit_only":
            policy_path = os.path.join(exposed_parent, "agents", "openai.yaml")
            try:
                with open(policy_path, encoding="utf-8") as stream:
                    policy = stream.read()
            except (OSError, UnicodeDecodeError):
                cold()
            if not re.search(
                r"(?m)^\s*allow_implicit_invocation\s*:\s*false(?:\s*#.*)?$",
                policy,
            ):
                cold()
    marker_path = os.path.join(skills_root, ".harness-managed")
    try:
        with open(marker_path, encoding="utf-8") as stream:
            managed_names = [line.strip() for line in stream if line.strip()]
    except (OSError, UnicodeDecodeError):
        cold()
    if sorted(managed_names) != sorted(expected_managed):
        cold()
    expected_managed_set = set(expected_managed)
    try:
        skill_entries = os.listdir(skills_root)
    except OSError:
        cold()
    for name in skill_entries:
        if name.startswith(".") or name in expected_managed_set:
            continue
        if os.path.isfile(os.path.join(skills_root, name, "SKILL.md")):
            cold()
    print(json.dumps(fingerprint, sort_keys=True, separators=(",", ":")))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
