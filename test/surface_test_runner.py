#!/usr/bin/env python3
"""Bounded subprocess shards for explicitly reviewed private-root tests.

Each allowlisted method uses PrepareIntegrationTests.setUp's private HOME,
repo, CODEX_HOME, compiler counter and lock. These methods change fixture
metadata/configuration only. Future/unlisted tests finish before parallel work.
Reviewed publication, signal, auth and revocation tests stay serial with each
other in one subprocess, but may overlap private-fixture shards. Weights balance
work; they are approximate prepare counts, never measured timing claims.
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
    ('PrepareIntegrationTests.test_opt_in_profiles_survive_warm_prepare_and_repair_drift', 3),
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

# Exact reviewed serial set: no new test can overlap shards without a review.
# These cases retain their original order and one-process safety boundary.
REVIEWED_SERIAL = [
    'CoordinationTimeoutTests.test_coordination_timeout_accepts_bounded_integer_override',
    'CoordinationTimeoutTests.test_coordination_timeout_defaults_to_30_seconds',
    'CoordinationTimeoutTests.test_coordination_timeout_rejects_non_integer_or_out_of_range_override',
    'PrepareIntegrationTests.test_apps_allowlist_changes_rebuild_once_and_revoke_permissions',
    'PrepareIntegrationTests.test_candidate_failure_and_signal_preserve_managed_and_runtime_state',
    'PrepareIntegrationTests.test_concurrent_auth_create_wins_post_publish_repair',
    'PrepareIntegrationTests.test_concurrent_runtime_config_write_is_merged_before_publish',
    'PrepareIntegrationTests.test_existing_auth_file_is_never_overwritten_on_warm_prepare',
    'PrepareIntegrationTests.test_external_agent_allowlist_does_not_preserve_other_files_or_symlinks',
    'PrepareIntegrationTests.test_external_agent_broken_and_directory_symlinks_force_quarantine',
    'PrepareIntegrationTests.test_failure_after_first_of_two_quarantines_restores_both_conflicts',
    'PrepareIntegrationTests.test_fresh_home_gets_auth_symlink_without_managing_auth',
    'PrepareIntegrationTests.test_legacy_command_marker_cannot_escape_skills_directory',
    'PrepareIntegrationTests.test_local_publish_failure_rolls_back_global_marketplace',
    'PrepareIntegrationTests.test_new_unapproved_plugin_invalidates_and_is_disabled',
    'PrepareIntegrationTests.test_new_unlisted_codex_only_skill_invalidates_empty_default_profile',
    'PrepareIntegrationTests.test_outer_terminate_after_first_of_two_quarantines_rolls_back_transaction',
    'PrepareIntegrationTests.test_poisoned_agent_marker_quarantines_unowned_agent_and_next_prepare_is_warm',
    'PrepareIntegrationTests.test_poisoned_managed_marker_quarantines_unowned_skill',
    'PrepareIntegrationTests.test_preflight_failure_preserves_every_managed_output',
    'PrepareIntegrationTests.test_publish_failure_rolls_back_every_managed_output',
    'PrepareIntegrationTests.test_quarantine_destination_race_preserves_concurrent_entry',
    'PrepareIntegrationTests.test_signal_after_global_exchange_rolls_back_global_marketplace',
    'PrepareIntegrationTests.test_success_publishes_managed_outputs_without_touching_runtime_state',
    'PrepareIntegrationTests.test_unowned_generated_skill_is_quarantined_and_next_prepare_is_warm',
    'ResolverTests.test_design_profile_is_exact_and_missing_source_fails',
    'ResolverTests.test_divergent_duplicate_requires_manifest_choice',
    'ResolverTests.test_enabled_without_definition_is_dropped_not_fatal',
    'ResolverTests.test_exact_mcp_profiles_validate_required_servers',
    'ResolverTests.test_exact_resolution_explicit_policy_and_managed_pruning',
    'ResolverTests.test_global_allowlist_duplicate_with_each_json_source_fails',
    'ResolverTests.test_global_allowlist_duplicate_with_product_source_fails',
    'ResolverTests.test_identical_selected_duplicates_follow_source_precedence',
    'ResolverTests.test_mcp_profile_policies_reject_invalid_shapes_and_membership',
    'ResolverTests.test_mcp_profile_runtime_policy_is_preserved_in_catalog',
    'ResolverTests.test_product_managed_mcp_policy_without_emitted_definition_fails',
    'SurfaceInspectionTests.test_inspection_distinguishes_metadata_trust_and_managed_settings',
    'SurfaceInspectionTests.test_missing_profile_never_falls_back_and_malformed_config_is_redacted',
    'SurfaceInspectionTests.test_profile_overlay_is_read_only_and_omits_secrets',
    'SurfaceInspectionTests.test_stamp_consistency_detects_changed_and_deleted_outputs',
    'WarmIdentityTests.test_directory_enumeration_failure_requests_cold_rebuild',
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


def partition(discovered, allowlist, jobs, selected=None, reviewed_serial=()):
    allowed = [name for name, _ in allowlist]
    reviewed = list(reviewed_serial)
    if jobs not in (1, 2, 3):
        raise ValueError('surface test jobs must be 1, 2 or 3')
    if (len(discovered) != len(set(discovered)) or len(allowed) != len(set(allowed))
            or len(reviewed) != len(set(reviewed))):
        raise ValueError('duplicate test ID in discovery or registry')
    missing = (set(allowed) | set(reviewed)) - set(discovered)
    if missing:
        raise ValueError('stale registry test IDs: ' + ', '.join(sorted(missing)))
    overlap = set(allowed) & set(reviewed)
    if overlap:
        raise ValueError('test IDs in both reviewed registries: ' + ', '.join(sorted(overlap)))
    names = list(discovered if selected is None else selected)
    if len(names) != len(set(names)) or set(names) - set(discovered):
        raise ValueError('unknown or duplicate selected test ID')
    if jobs == 1:
        return [('serial', names)]
    future = [name for name in names if name not in allowed and name not in reviewed]
    serial = [name for name in names if name in reviewed]
    shards, weights = [[] for _ in range(jobs)], [0] * jobs
    for name, weight in sorted(allowlist, key=lambda item: (-item[1], item[0])):
        if name not in names:
            continue
        index = weights.index(min(weights))
        shards[index].append(name)
        weights[index] += weight
    groups = [('future-serial', future), ('reviewed-serial', serial)] + [
        (f'shard-{index + 1}', sorted(shard))
        for index, shard in enumerate(shards) if shard
    ]
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
    timing_error = None
    timing_complete = False
    with tempfile.TemporaryDirectory(prefix='surface-test-timing.') as directory:
        timing_report = Path(directory) / 'tests.json'
        environment = dict(os.environ)
        environment['HARNESS_UNITTEST_TIMING_REPORT'] = str(timing_report)
        try:
            result = subprocess.run(command, cwd=ROOT, capture_output=True, text=True,
                                    env=environment)
            code, stdout, stderr = result.returncode, result.stdout, result.stderr
        except OSError as error:
            code, stdout, stderr = 127, '', str(error)
        try:
            if not timing_report.is_file():
                raise ValueError('timing report missing')
            else:
                payload = json.loads(timing_report.read_text(encoding='utf-8'))
                if not isinstance(payload, dict) or payload.get('schema_version') != 1 or not isinstance(payload.get('tests'), list):
                    raise ValueError('timing report has invalid schema')
                tests = payload['tests']
                timing_complete = True
        except (OSError, ValueError) as error:
            timing_error = f'timing report unavailable: {error}'
            stderr += ('\n' if stderr and not stderr.endswith('\n') else '') + timing_error + '\n'
            if code == 0:
                code = 127
    return dict(label=label, test_count=len(names),
                executed_count=len(tests) if timing_complete else None,
                returncode=code, stdout=stdout, stderr=stderr,
                elapsed_s=time.monotonic() - start, tests=tests,
                timing_complete=timing_complete, timing_error=timing_error)


def execute(groups, run=run_group):
    reports = []
    gate = next((group for group in groups if group[0] in ('serial', 'future-serial')), None)
    if gate and gate[1]:
        print(f'==> {gate[0]}: {len(gate[1])} tests', flush=True)
        reports.append(run(*gate))
        if gate[0] == 'future-serial' and not successful(reports):
            return reports
    parallel = [(label, names) for label, names in groups
                if label not in ('serial', 'future-serial') and names]
    if parallel:
        for label, names in parallel:
            print(f'==> {label}: {len(names)} tests', flush=True)
        with ThreadPoolExecutor(max_workers=len(parallel)) as pool:
            reports.extend(pool.map(lambda group: run(*group), parallel))
    return reports


def successful(reports):
    return all(report['returncode'] == 0 for report in reports)


def make_summary(jobs, groups, reports, elapsed_s):
    planned = sum(len(group) for _, group in groups)
    counts = [report.get('executed_count', report.get('test_count')) for report in reports]
    executed = None if None in counts else sum(counts)
    return dict(jobs=jobs, selected_tests=planned, planned_tests=planned,
                executed_tests=executed, elapsed_s=elapsed_s, groups=reports)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--jobs', type=int, choices=(1, 2, 3), default=os.environ.get('HARNESS_SURFACE_TEST_JOBS', '3'), help='private shards (plus one reviewed-serial subprocess)')
    parser.add_argument('--test', action='append', help='run a validated subset (repeatable)')
    parser.add_argument('--report', type=Path, help='write group timing/status JSON')
    args = parser.parse_args()
    started = time.monotonic()
    try:
        names = discover()
        groups = partition(names, ALLOWLIST, args.jobs, args.test, REVIEWED_SERIAL)
    except ValueError as error:
        parser.error(str(error))
    full = args.jobs == 1 and args.test is None
    reports = execute(groups, run=lambda label, tests: run_group(label, tests, full=full))
    for report in reports:
        print(f"--- {report['label']} ({report['elapsed_s']:.3f}s, exit={report['returncode']}) ---", flush=True)
        print(report['stdout'], end='')
        print(report['stderr'], end='', file=sys.stderr)
    summary = make_summary(args.jobs, groups, reports, time.monotonic() - started)
    if args.report:
        args.report.write_text(json.dumps(summary, indent=2) + '\n')
    executed = 'unknown' if summary['executed_tests'] is None else summary['executed_tests']
    print(f"SURFACE_TEST_TOTAL seconds={summary['elapsed_s']:.3f} tests={executed} planned={summary['planned_tests']} jobs={args.jobs}")
    return 0 if successful(reports) else 1


if __name__ == '__main__':
    raise SystemExit(main())
