#!/usr/bin/env python3
"""Resolve a portable Codex surface manifest into one deterministic runtime view.

The resolver intentionally owns only launcher-managed links, wrappers, catalog,
and disable entries. It never deletes a source skill or an unmarked runtime
entry. Host-specific paths are expanded at generation time and never written
back to the portable manifest.
"""

from __future__ import annotations

import argparse
from dataclasses import dataclass
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import sys
import tempfile
import time
from typing import Iterable


SCHEMA_VERSION = 1
PRODUCT_MCP_SERVERS = {"computer-use"}
TOKEN_PATTERN = re.compile(r"\$\{(HOME|REPO_ROOT|CODEX_HOME)\}")


class SurfaceError(RuntimeError):
    pass


@dataclass(frozen=True)
class Candidate:
    name: str
    path: Path
    source: str
    selector: str
    digest: str
    directory_key: str


@dataclass(frozen=True)
class Selected:
    candidate: Candidate
    invocation: str


def fail(message: str) -> None:
    raise SurfaceError(message)


def load_json(path: Path) -> dict:
    try:
        with path.open(encoding="utf-8") as stream:
            value = json.load(stream)
    except FileNotFoundError:
        fail(f"surface manifest not found: {path}")
    except json.JSONDecodeError as error:
        fail(f"invalid JSON in {path}: {error}")
    if not isinstance(value, dict):
        fail(f"surface manifest must be a JSON object: {path}")
    return value


def expand_path(raw: str, *, home: Path, repo_root: Path, codex_home: Path) -> Path:
    if not isinstance(raw, str) or not raw:
        fail(f"surface path must be a non-empty string, got {raw!r}")
    values = {
        "HOME": str(home),
        "REPO_ROOT": str(repo_root),
        "CODEX_HOME": str(codex_home),
    }
    expanded = TOKEN_PATTERN.sub(lambda match: values[match.group(1)], raw)
    if "${" in expanded:
        fail(f"unsupported or incomplete host token in path: {raw}")
    path = Path(expanded).expanduser()
    if not path.is_absolute():
        path = repo_root / path
    return Path(os.path.abspath(path))


def frontmatter_name(path: Path) -> str:
    try:
        with path.open(encoding="utf-8") as stream:
            first = stream.readline().rstrip("\n")
            if first.strip() != "---":
                fail(f"SKILL.md is missing YAML frontmatter: {path}")
            for raw in stream:
                line = raw.rstrip("\n")
                if line.strip() == "---":
                    break
                if line.startswith("name:"):
                    name = line.partition(":")[2].strip().strip('"').strip("'")
                    if name:
                        return name
    except UnicodeDecodeError:
        fail(f"SKILL.md is not valid UTF-8: {path}")
    fail(f"SKILL.md is missing a non-empty frontmatter name: {path}")


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(65536), b""):
            digest.update(chunk)
    return digest.hexdigest()


def scan_skill_root(
    root: Path, source: str, selector: str, *, namespace: str | None = None
) -> list[Candidate]:
    if not root.is_dir():
        return []
    candidates = []
    paths = []
    if (root / "SKILL.md").is_file():
        paths.append(root / "SKILL.md")
    # `Path.rglob` deliberately does not descend into symlinked directories on
    # current Python. User skill stores commonly expose every entry as a
    # symlink, so inspect each conventional immediate skill directory instead.
    for entry in sorted(root.iterdir()):
        path = entry / "SKILL.md"
        if entry.is_dir() and path.is_file():
            paths.append(path)
    for path in paths:
        declared_name = frontmatter_name(path)
        name = (
            declared_name
            if not namespace or ":" in declared_name
            else f"{namespace}:{declared_name}"
        )
        resolved = path.resolve()
        candidates.append(
            Candidate(
                name=name,
                path=resolved,
                source=source,
                selector=selector,
                digest=sha256(resolved),
                directory_key=path.parent.name,
            )
        )
    return candidates


def scan_disabled_tree(root: Path) -> list[Candidate]:
    if not root.is_dir():
        return []
    candidates = []
    seen_paths = set()
    for current, directories, files in os.walk(root, followlinks=True):
        real_current = os.path.realpath(current)
        if real_current in seen_paths:
            directories[:] = []
            continue
        seen_paths.add(real_current)
        if "SKILL.md" not in files:
            continue
        path = Path(current) / "SKILL.md"
        resolved = path.resolve()
        candidates.append(
            Candidate(
                name=frontmatter_name(resolved),
                path=resolved,
                source="manifest-disabled",
                selector="manifest-disabled",
                digest=sha256(resolved),
                directory_key=path.parent.name,
            )
        )
    return candidates


def natural_key(value: str) -> tuple:
    return tuple(int(part) if part.isdigit() else part.lower() for part in re.split(r"(\d+)", value))


def newest_plugin_root(cache: Path, package_id: str) -> Path | None:
    if "@" not in package_id:
        fail(f"Claude plugin id must be plugin@marketplace: {package_id}")
    plugin, marketplace = package_id.rsplit("@", 1)
    package_root = cache / marketplace / plugin
    latest = package_root / "latest"
    if latest.is_dir():
        return Path(os.path.abspath(latest.resolve()))
    versions = [entry for entry in package_root.iterdir()] if package_root.is_dir() else []
    versions = [entry for entry in versions if entry.is_dir() and entry.name != "latest"]
    if not versions:
        return None
    return sorted(versions, key=lambda path: natural_key(path.name))[-1]


def scan_plugin_root(root: Path, package_id: str) -> list[Candidate]:
    candidates: list[Candidate] = []
    namespace = package_id.rsplit("@", 1)[0]
    root_skill = root / "SKILL.md"
    if root_skill.is_file():
        declared_name = frontmatter_name(root_skill)
        name = declared_name if ":" in declared_name else f"{namespace}:{declared_name}"
        resolved = root_skill.resolve()
        candidates.append(
            Candidate(name, resolved, "claude-plugin", f"claude-plugin:{package_id}", sha256(resolved), root.name)
        )
    skills_root = root / "skills"
    candidates.extend(
        scan_skill_root(
            skills_root,
            "claude-plugin",
            f"claude-plugin:{package_id}",
            namespace=namespace,
        )
    )
    return candidates


def validate_manifest(manifest: dict) -> None:
    if manifest.get("schema_version") != SCHEMA_VERSION:
        fail(f"unsupported schema_version {manifest.get('schema_version')!r}; expected {SCHEMA_VERSION}")
    if not isinstance(manifest.get("repo"), str) or not manifest["repo"]:
        fail("manifest repo must be a non-empty string")
    skills = manifest.get("skills")
    if not isinstance(skills, dict):
        fail("manifest skills must be an object")
    if skills.get("preserve_product_managed") is not True:
        fail("skills.preserve_product_managed must be true")
    precedence = skills.get("source_precedence")
    allowed_precedence = {
        "codex-product",
        "repo-claude",
        "claude-plugin",
        "global-agents",
        "codex-only",
    }
    if not isinstance(precedence, list) or set(precedence) != allowed_precedence or len(precedence) != len(allowed_precedence):
        fail(f"skills.source_precedence must list each supported source exactly once: {sorted(allowed_precedence)}")
    for section_name in ("project", "global_agents"):
        section = skills.get(section_name)
        if not isinstance(section, dict):
            fail(f"skills.{section_name} must be an object")
        if section.get("unlisted") != "disabled":
            fail(f"skills.{section_name}.unlisted must be 'disabled'")
        for key in ("implicit", "explicit_only"):
            if not isinstance(section.get(key), list):
                fail(f"skills.{section_name}.{key} must be an array")
            overlap = set(section.get("implicit", [])) & set(section.get("explicit_only", []))
            if overlap:
                fail(f"skills.{section_name} classifies entries twice: {sorted(overlap)}")
    plugins = skills.get("claude_plugins")
    if not isinstance(plugins, dict) or plugins.get("unlisted_packages") != "disabled":
        fail("skills.claude_plugins.unlisted_packages must be 'disabled'")
    if not isinstance(plugins.get("packages"), list):
        fail("skills.claude_plugins.packages must be an array")
    package_ids = set()
    for package in plugins["packages"]:
        if not isinstance(package, dict) or not isinstance(package.get("id"), str):
            fail("every Claude plugin package needs an id")
        if package["id"] in package_ids:
            fail(f"duplicate Claude plugin package id: {package['id']}")
        package_ids.add(package["id"])
        if package.get("unlisted") != "disabled":
            fail(f"Claude plugin {package['id']} must set unlisted='disabled'")
        overlap = set(package.get("implicit", [])) & set(package.get("explicit_only", []))
        if overlap:
            fail(f"Claude plugin {package['id']} classifies entries twice: {sorted(overlap)}")
    codex_only = skills.get("codex_only")
    if not isinstance(codex_only, dict) or codex_only.get("unlisted") != "disabled":
        fail("skills.codex_only.unlisted must be 'disabled'")
    if not isinstance(codex_only.get("profiles"), dict):
        fail("skills.codex_only.profiles must be an object")

    mcp = manifest.get("mcp")
    if not isinstance(mcp, dict) or mcp.get("mode") != "exact":
        fail("mcp.mode must be 'exact'")
    profiles = mcp.get("profiles")
    if not isinstance(profiles, dict) or not profiles:
        fail("mcp.profiles must be a non-empty object")
    default_profile = mcp.get("default_profile")
    if default_profile not in profiles:
        fail(f"mcp.default_profile is not declared: {default_profile!r}")
    required = set(mcp.get("required_in_all_profiles") or [])
    for name, profile in profiles.items():
        if not isinstance(profile, dict) or not isinstance(profile.get("enabled"), list):
            fail(f"mcp profile {name!r} needs an enabled array")
        missing = required - set(profile["enabled"])
        if missing:
            fail(f"mcp.required_in_all_profiles missing from profile {name!r}: {sorted(missing)}")


def find_requested(candidates: Iterable[Candidate], requested: str, label: str) -> Candidate:
    matches = [candidate for candidate in candidates if requested in {candidate.name, candidate.directory_key}]
    if not matches:
        fail(f"configured skill {requested!r} was not found in {label}")
    if len(matches) > 1:
        paths = ", ".join(str(match.path) for match in matches)
        fail(f"configured skill {requested!r} is ambiguous in {label}: {paths}")
    return matches[0]


def duplicate_choice(name: str, selected: Candidate, choices: dict) -> str | None:
    if name in choices:
        return choices[name]
    if name.startswith("superpowers:") and "superpowers:*" in choices:
        return choices["superpowers:*"]
    if selected.source == "repo-claude" and "project:*" in choices:
        return choices["project:*"]
    return None


def precedence_class(candidate: Candidate) -> str:
    if candidate.selector.startswith("claude-plugin:"):
        return "claude-plugin"
    return candidate.selector


def collect_candidates(manifest: dict, *, home: Path, repo_root: Path, codex_home: Path):
    skills = manifest["skills"]
    by_source: dict[str, list[Candidate]] = {}
    all_candidates: list[Candidate] = []

    def add(key: str, values: list[Candidate]):
        by_source[key] = values
        all_candidates.extend(values)

    project_root = expand_path(skills["project"]["root"], home=home, repo_root=repo_root, codex_home=codex_home)
    add("repo-claude", scan_skill_root(project_root, "repo-claude", "repo-claude"))
    repo_agents = repo_root / ".agents" / "skills"
    add("repo-agents", scan_skill_root(repo_agents, "repo-agents", "repo-agents"))
    global_root = expand_path(skills["global_agents"]["root"], home=home, repo_root=repo_root, codex_home=codex_home)
    add("global-agents", scan_skill_root(global_root, "global-agents", "global-agents"))

    plugin_cache = expand_path(skills["claude_plugins"]["root"], home=home, repo_root=repo_root, codex_home=codex_home)
    approved_plugins: dict[str, list[Candidate]] = {}
    for package in skills["claude_plugins"]["packages"]:
        root = newest_plugin_root(plugin_cache, package["id"])
        candidates = [] if root is None else scan_plugin_root(root, package["id"])
        approved_plugins[package["id"]] = candidates
        add(f"claude-plugin:{package['id']}", candidates)

    # Inventory unapproved latest plugin packages too. They are classified as
    # disabled and exact-path disabled in the rendered surface; they are never
    # linked into the generated Codex home.
    approved_ids = set(approved_plugins)
    if plugin_cache.is_dir():
        for marketplace in sorted(plugin_cache.iterdir()):
            if not marketplace.is_dir():
                continue
            for plugin in sorted(marketplace.iterdir()):
                if not plugin.is_dir():
                    continue
                package_id = f"{plugin.name}@{marketplace.name}"
                if package_id in approved_ids:
                    continue
                root = newest_plugin_root(plugin_cache, package_id)
                if root is not None:
                    add(f"claude-plugin:{package_id}", scan_plugin_root(root, package_id))

    codex_only_root = expand_path(skills["codex_only"]["root"], home=home, repo_root=repo_root, codex_home=codex_home)
    add("codex-only", scan_skill_root(codex_only_root, "codex-only", "codex-only"))
    native_superpowers = home / ".codex" / "superpowers" / "skills"
    add(
        "native-codex-superpowers",
        scan_skill_root(
            native_superpowers,
            "native-codex-superpowers",
            "native-codex-superpowers",
            namespace="superpowers",
        ),
    )

    curated_root = codex_home / "plugins" / "cache" / "openai-curated-remote" / "superpowers"
    curated: list[Candidate] = []
    if curated_root.is_dir():
        for path in sorted(curated_root.rglob("SKILL.md")):
            if path.is_file():
                declared_name = frontmatter_name(path)
                name = (
                    declared_name
                    if ":" in declared_name
                    else f"superpowers:{declared_name}"
                )
                resolved = path.resolve()
                curated.append(Candidate(name, resolved, "codex-curated-superpowers", "codex-curated-superpowers", sha256(resolved), path.parent.name))
    add("codex-curated-superpowers", curated)

    system_root = home / ".codex" / "skills" / ".system"
    add("codex-product", scan_skill_root(system_root, "codex-product", "codex-product"))
    disabled_candidates = []
    for raw in skills.get("disabled_roots") or []:
        root = expand_path(raw, home=home, repo_root=repo_root, codex_home=codex_home)
        disabled_candidates.extend(scan_disabled_tree(root))
    add("manifest-disabled", disabled_candidates)
    return by_source, all_candidates


def choose_skills(manifest: dict, *, skill_profile: str, by_source: dict[str, list[Candidate]], all_candidates: list[Candidate]) -> list[Selected]:
    skills = manifest["skills"]
    selected: list[Selected] = []

    # Product-managed skills are preserved as a unit. Their names still take
    # part in duplicate validation so a user/global copy cannot win by scan order.
    selected.extend(Selected(candidate, "implicit") for candidate in by_source.get("codex-product", []))

    for section_name, source in (("project", "repo-claude"), ("global_agents", "global-agents")):
        section = skills[section_name]
        for invocation, key in (("implicit", "implicit"), ("explicit_only", "explicit_only")):
            for requested in section[key]:
                selected.append(Selected(find_requested(by_source[source], requested, f"skills.{section_name}"), invocation))

    for package in skills["claude_plugins"]["packages"]:
        source = f"claude-plugin:{package['id']}"
        for invocation, key in (("implicit", "implicit"), ("explicit_only", "explicit_only")):
            for requested in package.get(key, []):
                selected.append(Selected(find_requested(by_source[source], requested, f"Claude plugin {package['id']}"), invocation))

    profiles = skills["codex_only"]["profiles"]
    if skill_profile not in profiles:
        fail(f"unknown Codex skill profile {skill_profile!r}; expected one of {sorted(profiles)}")
    for requested in profiles[skill_profile]:
        selected.append(Selected(find_requested(by_source["codex-only"], requested, f"Codex-only profile {skill_profile}"), "implicit"))

    grouped: dict[str, list[Selected]] = {}
    for item in selected:
        grouped.setdefault(item.candidate.name, []).append(item)

    precedence = {source: index for index, source in enumerate(skills["source_precedence"])}
    choices = skills.get("duplicate_choices") or {}
    by_name: dict[str, Selected] = {}
    for name, items in grouped.items():
        unique = {(item.candidate.path, item.invocation): item for item in items}
        items = list(unique.values())
        if len(items) == 1:
            by_name[name] = items[0]
            continue
        digests = {item.candidate.digest for item in items}
        provisional = min(items, key=lambda item: precedence[precedence_class(item.candidate)])
        choice = duplicate_choice(name, provisional.candidate, choices)
        if len(digests) > 1 and not choice:
            paths = ", ".join(str(item.candidate.path) for item in items)
            fail(f"divergent duplicate skill {name!r} requires an explicit duplicate_choices entry: {paths}")
        if choice:
            matching = [item for item in items if item.candidate.selector == choice]
            if len(matching) != 1:
                fail(f"duplicate choice for {name!r} does not select exactly one manifest route: {choice!r}")
            by_name[name] = matching[0]
        else:
            by_name[name] = provisional

    candidates_by_name: dict[str, list[Candidate]] = {}
    for candidate in all_candidates:
        candidates_by_name.setdefault(candidate.name, []).append(candidate)
    for name, item in sorted(by_name.items()):
        routes = candidates_by_name.get(name, [])
        digests = {route.digest for route in routes}
        if len(routes) > 1 and len(digests) > 1:
            choice = duplicate_choice(name, item.candidate, choices)
            if not choice:
                paths = ", ".join(str(route.path) for route in routes)
                fail(f"divergent duplicate skill {name!r} requires an explicit duplicate_choices entry: {paths}")
            if choice != item.candidate.selector:
                fail(
                    f"duplicate choice for {name!r} selects {choice!r}, but manifest membership selected "
                    f"{item.candidate.selector!r}"
                )
            if not any(route.selector == choice for route in routes):
                fail(f"duplicate choice for {name!r} points to missing source {choice!r}")
    return [by_name[name] for name in sorted(by_name)]


def managed_destination(skills_dir: Path, candidate: Candidate) -> Path:
    # Keep Claude-plugin sibling directory names intact: several skills use
    # `../other-skill/...` references. The rewritten frontmatter carries the
    # effective plugin namespace while the directory topology stays usable.
    raw_name = candidate.directory_key if candidate.source == "claude-plugin" else candidate.name
    slug = re.sub(r"[^A-Za-z0-9._-]+", "__", raw_name).strip("._-") or "skill"
    return skills_dir / slug


def remove_managed_entry(path: Path) -> None:
    if path.is_symlink():
        path.unlink()
        return
    if path.is_dir() and (path / ".harness-surface-wrapper").is_file():
        shutil.rmtree(path)


def atomic_write(path: Path, content: str, mode: int | None = None) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    if path.is_file():
        try:
            if path.read_text(encoding="utf-8") == content:
                return
        except UnicodeDecodeError:
            pass
    descriptor, temporary = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8") as stream:
            stream.write(content)
            stream.flush()
            os.fsync(stream.fileno())
        if mode is not None:
            os.chmod(temporary, mode)
        os.replace(temporary, path)
    finally:
        try:
            os.unlink(temporary)
        except FileNotFoundError:
            pass


def explicit_policy_yaml(source: Path) -> str:
    if not source.is_file():
        return (
            "# Generated by codex-surface.py — explicit invocation remains available.\n"
            "policy:\n"
            "  allow_implicit_invocation: false\n"
        )
    lines = source.read_text(encoding="utf-8").splitlines()
    output = []
    in_policy = False
    policy_found = False
    invocation_found = False
    for line in lines:
        top_level = bool(line) and not line[0].isspace() and not line.startswith("#")
        if top_level and in_policy:
            if not invocation_found:
                output.append("  allow_implicit_invocation: false")
            in_policy = False
        if re.match(r"^policy\s*:\s*(?:#.*)?$", line):
            policy_found = True
            in_policy = True
            invocation_found = False
            output.append(line)
            continue
        if in_policy and re.match(r"^\s+allow_implicit_invocation\s*:", line):
            indentation = line[: len(line) - len(line.lstrip())] or "  "
            output.append(f"{indentation}allow_implicit_invocation: false")
            invocation_found = True
            continue
        output.append(line)
    if in_policy and not invocation_found:
        output.append("  allow_implicit_invocation: false")
    if not policy_found:
        if output and output[-1] != "":
            output.append("")
        output.extend(["policy:", "  allow_implicit_invocation: false"])
    return "\n".join(output) + "\n"


def rewrite_skill_name(content: str, effective_name: str) -> str:
    lines = content.splitlines(keepends=True)
    in_frontmatter = False
    for index, line in enumerate(lines):
        if index == 0 and line.strip() == "---":
            in_frontmatter = True
            continue
        if in_frontmatter and line.strip() == "---":
            break
        if in_frontmatter and re.match(r"^name\s*:", line):
            newline = "\n" if line.endswith("\n") else ""
            lines[index] = f"name: {effective_name}{newline}"
            return "".join(lines)
    fail(f"cannot rewrite missing skill name to {effective_name!r}")


def make_skill_wrapper(
    destination: Path,
    source_skill: Path,
    effective_name: str,
    *,
    explicit_only: bool,
) -> None:
    source_dir = source_skill.parent
    destination.mkdir(parents=True)
    (destination / ".harness-surface-wrapper").write_text("schema=1\n", encoding="utf-8")
    for entry in source_dir.iterdir():
        if entry.name == "agents":
            continue
        if entry.name == "SKILL.md":
            # Codex resolves symlink targets when matching exact disable paths.
            # A real wrapper copy keeps an explicitly callable route distinct
            # from the disabled globally discovered source path.
            content = entry.read_text(encoding="utf-8")
            if frontmatter_name(entry) != effective_name:
                content = rewrite_skill_name(content, effective_name)
            (destination / entry.name).write_text(content, encoding="utf-8")
        else:
            (destination / entry.name).symlink_to(entry, target_is_directory=entry.is_dir())
    source_agents = source_dir / "agents"
    if explicit_only:
        agents = destination / "agents"
        agents.mkdir()
        (agents / "openai.yaml").write_text(
            explicit_policy_yaml(source_agents / "openai.yaml"), encoding="utf-8"
        )
    elif source_agents.is_dir():
        (destination / "agents").symlink_to(source_agents, target_is_directory=True)


def materialize(selected: list[Selected], *, codex_home: Path, all_candidates: list[Candidate]) -> tuple[list[dict], list[Path]]:
    skills_dir = codex_home / "skills"
    skills_dir.mkdir(parents=True, exist_ok=True)
    marker = skills_dir / ".harness-managed"
    previous = []
    if marker.is_file():
        previous = [line.strip() for line in marker.read_text(encoding="utf-8").splitlines() if line.strip()]
    for name in previous:
        remove_managed_entry(skills_dir / name)

    catalog_entries = []
    managed_names = []
    selected_by_name = {item.candidate.name: item for item in selected}
    destinations = [
        managed_destination(skills_dir, item.candidate)
        for item in selected
        if item.candidate.source != "codex-product"
    ]
    if len(set(destinations)) != len(destinations):
        collisions = sorted(
            {path.name for path in destinations if destinations.count(path) > 1}
        )
        fail(f"selected skills collide on generated directory names: {collisions}")

    for item in selected:
        candidate = item.candidate
        if candidate.source == "codex-product":
            catalog_entries.append(
                {
                    "name": candidate.name,
                    "invocation": item.invocation,
                    "source": candidate.selector,
                    "source_path": str(candidate.path),
                    "exposed_path": str(candidate.path),
                    "sha256": candidate.digest,
                }
            )
            continue
        destination = managed_destination(skills_dir, candidate)
        if destination.exists() or destination.is_symlink():
            remove_managed_entry(destination)
        if destination.exists() or destination.is_symlink():
            fail(f"refusing to replace unowned Codex skill entry: {destination}")
        needs_wrapper = item.invocation == "explicit_only" or candidate.source == "claude-plugin"
        if needs_wrapper:
            make_skill_wrapper(
                destination,
                candidate.path,
                candidate.name,
                explicit_only=item.invocation == "explicit_only",
            )
            exposed = destination / "SKILL.md"
        else:
            destination.symlink_to(candidate.path.parent, target_is_directory=True)
            exposed = destination / "SKILL.md"
        managed_names.append(destination.name)
        catalog_entries.append(
            {
                "name": candidate.name,
                "invocation": item.invocation,
                "source": candidate.selector,
                "source_path": str(candidate.path),
                "exposed_path": str(exposed),
                "sha256": candidate.digest,
            }
        )

    atomic_write(marker, "".join(f"{name}\n" for name in sorted(managed_names)))

    disabled_paths = []
    for candidate in all_candidates:
        selected_item = selected_by_name.get(candidate.name)
        if selected_item and candidate.path == selected_item.candidate.path:
            disable_selected_source = (
                candidate.source == "claude-plugin"
                or (
                    candidate.source == "global-agents"
                    and selected_item.invocation == "explicit_only"
                )
            )
            if candidate.source != "repo-agents" and not disable_selected_source:
                continue
        # Exact disable entries prevent standard repo/user discovery, stale
        # plugin routes, and non-canonical duplicates without deleting them.
        disabled_paths.append(candidate.path)
    return catalog_entries, sorted(set(disabled_paths), key=str)


def resolve_mcp(manifest: dict, *, profile: str, home: Path, repo_root: Path, codex_home: Path) -> dict:
    mcp = manifest["mcp"]
    if profile not in mcp["profiles"]:
        fail(f"unknown MCP profile {profile!r}; expected one of {sorted(mcp['profiles'])}")
    servers = set()
    owners = {}
    definition_sources = list(mcp.get("definition_sources") or [])
    for supported in (".mcp.json", ".mcp.local.json", "mcp.local.json"):
        if (repo_root / supported).is_file() and supported not in definition_sources:
            definition_sources.append(supported)
    for raw in definition_sources:
        if raw == "codex-product":
            continue
        path = expand_path(raw, home=home, repo_root=repo_root, codex_home=codex_home)
        if not path.is_file():
            continue
        data = load_json(path)
        definitions = data.get("mcpServers") or {}
        if not isinstance(definitions, dict):
            fail(f"mcpServers must be an object in {path}")
        for name in definitions:
            if name in servers:
                fail(f"duplicate MCP server {name!r} in {owners[name]} and {path}")
            servers.add(name)
            owners[name] = str(path)
    enabled = set(mcp["profiles"][profile]["enabled"])
    unresolved = enabled - servers
    invalid = unresolved - PRODUCT_MCP_SERVERS
    if invalid:
        fail(f"MCP profile {profile!r} enables servers with no definition: {sorted(invalid)}")
    return {
        "profile": profile,
        "enabled": sorted(enabled),
        "disabled": sorted(servers - enabled),
        "product_managed": sorted(unresolved),
        "definitions": {name: owners[name] for name in sorted(owners)},
    }


def render_surface_config(disabled_paths: list[Path]) -> str:
    lines = [
        "# Generated by codex-surface.py — do not edit manually.",
        "# Exact non-canonical routes are disabled without deleting their sources.",
    ]
    for path in disabled_paths:
        lines.extend(
            [
                "",
                "[[skills.config]]",
                "# launcher-managed-surface",
                f"path = {json.dumps(str(path))}",
                "enabled = false",
            ]
        )
    return "\n".join(lines) + "\n"


def add_tree_signature(digest, root: Path, label: str) -> None:
    """Hash source identity without depending on generated runtime mtimes."""
    digest.update(f"TREE\0{label}\0".encode())
    if not root.exists() and not root.is_symlink():
        digest.update(b"MISSING\0")
        return
    paths = [root]
    if root.is_dir():
        paths.extend(sorted(root.rglob("*")))
    for path in paths:
        try:
            relative = "." if path == root else str(path.relative_to(root))
            stat = path.lstat()
        except FileNotFoundError:
            digest.update(f"VANISHED\0{path}\0".encode())
            continue
        digest.update(f"{relative}\0{stat.st_mode}\0{stat.st_size}\0".encode())
        if path.is_symlink():
            digest.update(f"LINK\0{os.readlink(path)}\0".encode())
        elif path.is_file():
            # Source contents, not generated mtimes, define the runtime view.
            # Large bundled binaries use size+mtime to keep warm launch cheap;
            # manifests, skills, configs, and scripts are content hashed.
            if stat.st_size <= 1024 * 1024:
                digest.update(bytes.fromhex(sha256(path)))
            else:
                digest.update(f"LARGE\0{stat.st_mtime_ns}\0".encode())


def fingerprint_payload(args: argparse.Namespace) -> dict:
    manifest_path = Path(os.path.abspath(args.manifest))
    repo_root = Path(os.path.abspath(args.repo_root))
    codex_home = Path(os.path.abspath(args.codex_home))
    home = Path(os.path.abspath(args.home))
    manifest = load_json(manifest_path)
    validate_manifest(manifest)
    skill_profile = args.skill_profile or "default"
    if skill_profile not in manifest["skills"]["codex_only"]["profiles"]:
        fail(f"unknown Codex skill profile {skill_profile!r}")
    mcp_profile = args.mcp_profile or manifest["mcp"]["default_profile"]
    if mcp_profile not in manifest["mcp"]["profiles"]:
        fail(f"unknown MCP profile {mcp_profile!r}")

    roots: list[tuple[str, Path]] = [
        ("manifest", manifest_path),
        ("claude-source", repo_root / ".claude" / "source"),
        ("claude-rules", repo_root / ".claude" / "rules"),
        ("claude-settings", repo_root / ".claude" / "settings.json"),
        ("claude-commands", repo_root / ".claude" / "commands"),
        ("claude-agents", repo_root / ".claude" / "agents"),
        ("repo-agents", repo_root / ".agents" / "skills"),
        ("claude-md", repo_root / "CLAUDE.md"),
        ("compiler", repo_root / "core" / "scripts" / "harness_compile.py"),
    ]
    skills = manifest["skills"]
    roots.extend(
        [
            (
                "project-skills",
                expand_path(skills["project"]["root"], home=home, repo_root=repo_root, codex_home=codex_home),
            ),
            (
                "global-agent-skills",
                expand_path(skills["global_agents"]["root"], home=home, repo_root=repo_root, codex_home=codex_home),
            ),
            ("native-superpowers", home / ".codex" / "superpowers" / "skills"),
            ("codex-product-skills", home / ".codex" / "skills" / ".system"),
            # Generated curated plugin *contents* may add a new duplicate route;
            # hash content/paths but intentionally not directory mtimes.
            (
                "generated-curated-superpowers",
                codex_home / "plugins" / "cache" / "openai-curated-remote" / "superpowers",
            ),
        ]
    )
    for index, raw in enumerate(skills.get("disabled_roots") or []):
        roots.append(
            (
                f"disabled-root:{index}",
                expand_path(raw, home=home, repo_root=repo_root, codex_home=codex_home),
            )
        )
    if manifest["skills"]["codex_only"]["profiles"][skill_profile]:
        roots.append(
            (
                "codex-only-profile",
                expand_path(skills["codex_only"]["root"], home=home, repo_root=repo_root, codex_home=codex_home),
            )
        )
    plugin_cache = expand_path(skills["claude_plugins"]["root"], home=home, repo_root=repo_root, codex_home=codex_home)
    for package in skills["claude_plugins"]["packages"]:
        plugin_root = newest_plugin_root(plugin_cache, package["id"])
        roots.append((f"claude-plugin:{package['id']}", plugin_root or plugin_cache / "__missing__" / package["id"]))
    mcp_sources = list(manifest["mcp"].get("definition_sources") or [])
    for supported in (".mcp.json", ".mcp.local.json", "mcp.local.json"):
        if (repo_root / supported).is_file() and supported not in mcp_sources:
            mcp_sources.append(supported)
    for raw in mcp_sources:
        if raw != "codex-product":
            roots.append((f"mcp:{raw}", expand_path(raw, home=home, repo_root=repo_root, codex_home=codex_home)))
    for index, raw in enumerate(args.launcher_file or []):
        roots.append((f"launcher:{index}", Path(os.path.abspath(raw))))
    if args.bundled_marketplace:
        roots.append(("bundled-marketplace", Path(os.path.abspath(args.bundled_marketplace))))

    digest = hashlib.sha256()
    digest.update(f"surface-fingerprint-v1\0{skill_profile}\0{mcp_profile}\0".encode())
    seen_roots = set()
    for label, root in roots:
        root_key = os.path.abspath(root)
        if root_key in seen_roots:
            continue
        seen_roots.add(root_key)
        add_tree_signature(digest, root, label)
    return {
        "schema_version": SCHEMA_VERSION,
        "digest": digest.hexdigest(),
        "skill_profile": skill_profile,
        "mcp_profile": mcp_profile,
    }


def fingerprint(args: argparse.Namespace) -> None:
    print(json.dumps(fingerprint_payload(args), sort_keys=True, separators=(",", ":")))


def load_inline_json(raw: str, label: str) -> dict:
    try:
        value = json.loads(raw)
    except json.JSONDecodeError as error:
        fail(f"invalid {label} JSON: {error}")
    if not isinstance(value, dict):
        fail(f"{label} must be a JSON object")
    return value


def runtime_config_matches(codex_home: Path, catalog: dict) -> bool:
    try:
        text = (codex_home / "config.toml").read_text(encoding="utf-8")
    except (OSError, UnicodeDecodeError):
        return False

    configured_paths: dict[str, list[bool]] = {}
    for match in re.finditer(r"(?ms)^\[\[skills\.config\]\]\s*\n(.*?)(?=^\[|\Z)", text):
        block = match.group(1)
        path_match = re.search(r'^path\s*=\s*("(?:[^"\\]|\\.)*")\s*$', block, re.MULTILINE)
        enabled_match = re.search(r"^enabled\s*=\s*(true|false)\s*$", block, re.MULTILINE)
        if not path_match or not enabled_match:
            continue
        try:
            path = json.loads(path_match.group(1))
        except json.JSONDecodeError:
            return False
        configured_paths.setdefault(path, []).append(enabled_match.group(1) == "true")
    for path in catalog.get("disabled_skill_paths") or []:
        if configured_paths.get(path) != [False]:
            return False

    mcp = catalog.get("mcp") or {}
    enabled_servers = set(mcp.get("enabled") or [])
    for name in (mcp.get("definitions") or {}):
        header = re.escape(f"[mcp_servers.{name}]")
        match = re.search(rf"(?ms)^{header}\s*\n(.*?)(?=^\[|\Z)", text)
        if not match:
            return False
        enabled_match = re.search(r"^enabled\s*=\s*(true|false)\s*$", match.group(1), re.MULTILINE)
        if not enabled_match or (enabled_match.group(1) == "true") != (name in enabled_servers):
            return False

    for plugin, expected in (
        ("computer-use", "computer-use" in enabled_servers),
        ("chrome", False),
    ):
        header = re.escape(f'[plugins."{plugin}@openai-bundled"]')
        match = re.search(rf"(?ms)^{header}\s*\n(.*?)(?=^\[|\Z)", text)
        if not match:
            return False
        enabled_match = re.search(r"^enabled\s*=\s*(true|false)\s*$", match.group(1), re.MULTILINE)
        if not enabled_match or (enabled_match.group(1) == "true") != expected:
            return False
    return True


def is_warm(stamp_path: Path, codex_home: Path, expected: dict) -> bool:
    if not stamp_path.is_file():
        return False
    try:
        stamp = load_json(stamp_path)
    except SurfaceError:
        return False
    if any(stamp.get(key) != expected.get(key) for key in ("schema_version", "digest", "skill_profile", "mcp_profile")):
        return False
    required = [
        codex_home / "config.toml",
        codex_home / "hooks.json",
        codex_home / "skill-catalog.json",
        codex_home / "surface.config.toml",
        codex_home / "skills" / ".harness-managed",
        codex_home / "fast.config.toml",
        codex_home / "base.config.toml",
        codex_home / "plan.config.toml",
        codex_home / "rich.config.toml",
    ]
    if not all(path.is_file() for path in required):
        return False
    try:
        catalog = load_json(codex_home / "skill-catalog.json")
    except SurfaceError:
        return False
    if catalog.get("skill_profile") != expected.get("skill_profile"):
        return False
    if (catalog.get("mcp") or {}).get("profile") != expected.get("mcp_profile"):
        return False
    if not runtime_config_matches(codex_home, catalog):
        return False
    for skill in catalog.get("skills") or []:
        exposed = Path(skill.get("exposed_path", ""))
        source = Path(skill.get("source_path", ""))
        if not exposed.is_file() or not source.is_file():
            return False
        try:
            if sha256(source) != skill.get("sha256"):
                return False
        except OSError:
            return False
    return True


def warm_check(args: argparse.Namespace) -> None:
    expected = load_inline_json(args.fingerprint_json, "fingerprint")
    if not is_warm(Path(args.stamp), Path(os.path.abspath(args.codex_home)), expected):
        raise SystemExit(1)


def warm_probe(args: argparse.Namespace) -> None:
    payload = fingerprint_payload(args)
    print(json.dumps(payload, sort_keys=True, separators=(",", ":")))
    if not is_warm(Path(args.stamp), Path(os.path.abspath(args.codex_home)), payload):
        raise SystemExit(3)


def write_stamp(args: argparse.Namespace) -> None:
    payload = load_inline_json(args.fingerprint_json, "fingerprint")
    if set(payload) != {"schema_version", "digest", "skill_profile", "mcp_profile"}:
        fail("fingerprint payload has unexpected fields")
    payload["completed_unix"] = int(time.time())
    atomic_write(Path(args.stamp), json.dumps(payload, indent=2, sort_keys=True) + "\n")


def resolve(args: argparse.Namespace) -> None:
    manifest_path = Path(os.path.abspath(args.manifest))
    repo_root = Path(os.path.abspath(args.repo_root))
    codex_home = Path(os.path.abspath(args.codex_home))
    home = Path(os.path.abspath(args.home))
    manifest = load_json(manifest_path)
    validate_manifest(manifest)
    skill_profile = args.skill_profile or "default"
    mcp_profile = args.mcp_profile or manifest["mcp"]["default_profile"]
    by_source, all_candidates = collect_candidates(
        manifest, home=home, repo_root=repo_root, codex_home=codex_home
    )
    selected = choose_skills(
        manifest,
        skill_profile=skill_profile,
        by_source=by_source,
        all_candidates=all_candidates,
    )
    catalog_entries, disabled_paths = materialize(
        selected, codex_home=codex_home, all_candidates=all_candidates
    )
    mcp = resolve_mcp(
        manifest,
        profile=mcp_profile,
        home=home,
        repo_root=repo_root,
        codex_home=codex_home,
    )
    catalog = {
        "schema_version": SCHEMA_VERSION,
        "repo": manifest["repo"],
        "skill_profile": skill_profile,
        "skills": catalog_entries,
        "disabled_skill_paths": [str(path) for path in disabled_paths],
        "mcp": mcp,
    }
    atomic_write(
        codex_home / "skill-catalog.json",
        json.dumps(catalog, indent=2, sort_keys=True) + "\n",
    )
    atomic_write(codex_home / "surface.config.toml", render_surface_config(disabled_paths))


def parser() -> argparse.ArgumentParser:
    result = argparse.ArgumentParser(description=__doc__)
    subcommands = result.add_subparsers(dest="command", required=True)
    resolve_parser = subcommands.add_parser("resolve", help="resolve and materialize a surface manifest")
    resolve_parser.add_argument("--manifest", required=True)
    resolve_parser.add_argument("--repo-root", required=True)
    resolve_parser.add_argument("--codex-home", required=True)
    resolve_parser.add_argument("--home", default=str(Path.home()))
    resolve_parser.add_argument("--skill-profile")
    resolve_parser.add_argument("--mcp-profile")
    resolve_parser.set_defaults(function=resolve)

    fingerprint_parser = subcommands.add_parser("fingerprint", help="calculate the launcher-owned input fingerprint")
    fingerprint_parser.add_argument("--manifest", required=True)
    fingerprint_parser.add_argument("--repo-root", required=True)
    fingerprint_parser.add_argument("--codex-home", required=True)
    fingerprint_parser.add_argument("--home", default=str(Path.home()))
    fingerprint_parser.add_argument("--skill-profile")
    fingerprint_parser.add_argument("--mcp-profile")
    fingerprint_parser.add_argument("--launcher-file", action="append")
    fingerprint_parser.add_argument("--bundled-marketplace")
    fingerprint_parser.set_defaults(function=fingerprint)

    probe_parser = subcommands.add_parser("warm-probe", help="fingerprint inputs and check the success stamp once")
    probe_parser.add_argument("--manifest", required=True)
    probe_parser.add_argument("--repo-root", required=True)
    probe_parser.add_argument("--codex-home", required=True)
    probe_parser.add_argument("--home", default=str(Path.home()))
    probe_parser.add_argument("--skill-profile")
    probe_parser.add_argument("--mcp-profile")
    probe_parser.add_argument("--launcher-file", action="append")
    probe_parser.add_argument("--bundled-marketplace")
    probe_parser.add_argument("--stamp", required=True)
    probe_parser.set_defaults(function=warm_probe)

    check_parser = subcommands.add_parser("warm-check", help="verify a successful warm runtime surface")
    check_parser.add_argument("--stamp", required=True)
    check_parser.add_argument("--codex-home", required=True)
    check_parser.add_argument("--fingerprint-json", required=True)
    check_parser.set_defaults(function=warm_check)

    stamp_parser = subcommands.add_parser("write-stamp", help="atomically record a successful preparation")
    stamp_parser.add_argument("--stamp", required=True)
    stamp_parser.add_argument("--fingerprint-json", required=True)
    stamp_parser.set_defaults(function=write_stamp)
    return result


def main() -> int:
    try:
        args = parser().parse_args()
        args.function(args)
        return 0
    except SurfaceError as error:
        print(f"ERROR: {error}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
