#!/usr/bin/env python3
"""Bounded subprocess shards for explicitly reviewed private-root tests.

Each allowlisted method uses PrepareIntegrationTests.setUp's private HOME,
repo, CODEX_HOME, compiler counter and lock. These methods change fixture
metadata/configuration only. Publication, signal, auth and revocation tests,
and all future/unlisted tests, remain serial. Weights balance work; they are
approximate prepare counts, never measured timing claims.
"""
import argparse
from concurrent.futures import ThreadPoolExecutor
import importlib
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time
import unittest

ROOT = Path(__file__).resolve().parents[1]
ALLOWLIST = [
    ('PrepareIntegrationTests.test_homebrew_compat_and_opt_entrypoints_generate_identical_hook_paths', 4),
    ('PrepareIntegrationTests.test_missing_default_app_marketplace_uses_valid_cached_marketplace', 2),
    ('PrepareIntegrationTests.test_explicit_marketplace_source_switch_invalidates_warm_home', 3),
    ('PrepareIntegrationTests.test_external_manifest_can_opt_in_computer_use_and_stay_warm', 2),
    ('PrepareIntegrationTests.test_runtime_in_use_marker_changes_stay_warm', 4),
    ('PrepareIntegrationTests.test_in_use_nonregular_and_entry_type_transitions_invalidate', 6),
    ('PrepareIntegrationTests.test_profile_flags_and_warm_fingerprint_invalidation', 13),
    ('PrepareIntegrationTests.test_local_mcp_runtime_policy_renders_and_stays_warm', 3),
    ('PrepareIntegrationTests.test_fixture_environment_removes_inherited_surface_overrides', 2),
    ('PrepareIntegrationTests.test_nonlogin_system_python_path_falls_back_to_homebrew_python', 1),
    ('PrepareIntegrationTests.test_curated_metadata_rewrite_stays_warm_but_new_version_invalidates', 3),
    ('PrepareIntegrationTests.test_astra_profile_survives_warm_prepare_and_repairs_drift', 3),
    ('PrepareIntegrationTests.test_invalid_live_config_fails_preflight_before_staging', 1),
    ('PrepareIntegrationTests.test_hook_commands_shell_quote_special_harness_path', 1),
    ('PrepareIntegrationTests.test_context_management_capability_change_rebuilds_once_then_stays_warm', 3),
    ('PrepareIntegrationTests.test_global_allowlist_definitions_follow_exact_profiles_and_warm_digest', 6),
    ('PrepareIntegrationTests.test_global_allowlist_emits_exact_profile_policies_without_source_drift', 3),
    ('PrepareIntegrationTests.test_selected_global_definition_edits_invalidate_or_fail_closed', 4),
    ('PrepareIntegrationTests.test_warm_path_rejects_conflicting_managed_skill_override', 2),
    ('PrepareIntegrationTests.test_selected_skill_override_is_removed', 2),
    ('PrepareIntegrationTests.test_single_quoted_commented_selected_override_is_removed', 2),
    ('PrepareIntegrationTests.test_external_agents_survive_warm_and_cold_prepare_without_becoming_managed', 4),
    ('PrepareIntegrationTests.test_external_claude_agents_are_not_converted_over_native_definitions', 3),
    ('PrepareIntegrationTests.test_external_agent_prefixes_reject_empty_or_path_patterns', 1),
    ('PrepareIntegrationTests.test_product_plugin_skill_drift_forces_rebuild', 2),
    ('PrepareIntegrationTests.test_warm_path_rejects_rogue_mcp_table', 2),
    ('PrepareIntegrationTests.test_warm_path_rejects_semantic_mcp_table_bypasses', 2),
    ('PrepareIntegrationTests.test_warm_path_repairs_launcher_owned_output_drift', 2),
    ('PrepareIntegrationTests.test_hook_entrypoint_removal_invalidates_warm_surface', 2),
    ('PrepareIntegrationTests.test_warm_path_repairs_launcher_owned_config_semantics', 3),
    ('PrepareIntegrationTests.test_warm_path_repairs_missing_native_task_tracker', 2),
    ('PrepareIntegrationTests.test_warm_path_repairs_disabled_native_task_tracker', 2),
    ('PrepareIntegrationTests.test_warm_path_rebuilds_missing_explicit_policy', 2),
    ('PrepareIntegrationTests.test_symlinked_skill_store_retarget_invalidates', 2),
    ('PrepareIntegrationTests.test_manifest_skill_wins_command_collision_without_source_write', 1),
    ('PrepareIntegrationTests.test_manifest_explicit_command_remains_callable_without_prompt_exposure', 1),
]


def discover():
    sys.path.insert(0, str(ROOT / 'test'))
    module = importlib.import_module('test_codex_surface')
    def flatten(suite):
        for test in suite:
            if isinstance(test, unittest.TestSuite):
                yield from flatten(test)
            else:
                yield test.id().removeprefix('test_codex_surface.')
    return list(flatten(unittest.defaultTestLoader.loadTestsFromModule(module)))


def partition(discovered, allowlist, jobs, selected=None):
    allowed = [name for name, _ in allowlist]
    if jobs not in (1, 2):
        raise ValueError('surface test jobs must be 1 or 2')
    if len(discovered) != len(set(discovered)) or len(allowed) != len(set(allowed)):
        raise ValueError('duplicate test ID in discovery or allowlist')
    if set(allowed) - set(discovered):
        raise ValueError('stale allowlist test IDs: ' + ', '.join(sorted(set(allowed) - set(discovered))))
    names = list(discovered if selected is None else selected)
    if len(names) != len(set(names)) or set(names) - set(discovered):
        raise ValueError('unknown or duplicate selected test ID')
    if jobs == 1:
        return [('serial', names)]
    serial = [name for name in names if name not in allowed]
    shards, weights = [[], []], [0, 0]
    for name, weight in sorted(allowlist, key=lambda item: (-item[1], item[0])):
        if name not in names:
            continue
        index = weights.index(min(weights))
        shards[index].append(name)
        weights[index] += weight
    groups = [('serial', serial)] + [(f'shard-{index + 1}', sorted(shard))
                                     for index, shard in enumerate(shards) if shard]
    assigned = [name for _, group in groups for name in group]
    if len(assigned) != len(names) or set(assigned) != set(names):
        raise ValueError('incomplete surface test partition')
    return groups


def run_group(label, names, full=False):
    # Full jobs=1 invokes exactly the previous canonical unittest command.
    command = [sys.executable, str(ROOT / 'test/test_codex_surface.py'), '-v']
    if not full:
        command += names
    start = time.monotonic()
    tests = []
    with tempfile.TemporaryDirectory(prefix='surface-test-timing.') as directory:
        timing_report = Path(directory) / 'tests.json'
        environment = dict(os.environ)
        environment['HARNESS_UNITTEST_TIMING_REPORT'] = str(timing_report)
        try:
            result = subprocess.run(command, cwd=ROOT, capture_output=True, text=True,
                                    env=environment)
            code, stdout, stderr = result.returncode, result.stdout, result.stderr
            if timing_report.is_file():
                payload = json.loads(timing_report.read_text(encoding='utf-8'))
                tests = payload.get('tests', [])
        except (OSError, json.JSONDecodeError) as error:
            code, stdout, stderr = 127, '', str(error)
    return dict(label=label, test_count=len(names), returncode=code, stdout=stdout,
                stderr=stderr, elapsed_s=time.monotonic() - start, tests=tests)


def execute(groups, run=run_group):
    reports = []
    serial_label, serial = groups[0]
    if serial:
        print(f'==> {serial_label}: {len(serial)} tests', flush=True)
        reports.append(run(serial_label, serial))
    parallel = groups[1:]
    if parallel:
        for label, names in parallel:
            print(f'==> {label}: {len(names)} tests', flush=True)
        with ThreadPoolExecutor(max_workers=2) as pool:
            reports.extend(pool.map(lambda group: run(*group), parallel))
    return reports


def successful(reports):
    return all(report['returncode'] == 0 for report in reports)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--jobs', type=int, choices=(1, 2), default=os.environ.get('HARNESS_SURFACE_TEST_JOBS', '2'))
    parser.add_argument('--test', action='append', help='run a validated subset (repeatable)')
    parser.add_argument('--report', type=Path, help='write group timing/status JSON')
    args = parser.parse_args()
    started = time.monotonic()
    try:
        names = discover()
        groups = partition(names, ALLOWLIST, args.jobs, args.test)
    except ValueError as error:
        parser.error(str(error))
    full = args.jobs == 1 and args.test is None
    reports = execute(groups, run=lambda label, tests: run_group(label, tests, full=full))
    for report in reports:
        print(f"--- {report['label']} ({report['elapsed_s']:.3f}s, exit={report['returncode']}) ---", flush=True)
        print(report['stdout'], end='')
        print(report['stderr'], end='', file=sys.stderr)
    summary = dict(jobs=args.jobs, selected_tests=sum(len(group) for _, group in groups),
                   elapsed_s=time.monotonic() - started, groups=reports)
    if args.report:
        args.report.write_text(json.dumps(summary, indent=2) + '\n')
    print(f"SURFACE_TEST_TOTAL seconds={summary['elapsed_s']:.3f} tests={summary['selected_tests']} jobs={args.jobs}")
    return 0 if successful(reports) else 1


if __name__ == '__main__':
    raise SystemExit(main())
