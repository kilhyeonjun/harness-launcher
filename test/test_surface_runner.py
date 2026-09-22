import importlib.util
import json
from pathlib import Path
import subprocess
import threading
import unittest
from unittest import mock

SPEC = importlib.util.spec_from_file_location('surface_runner', Path(__file__).with_name('surface_test_runner.py'))
RUNNER = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(RUNNER)


class PartitionTests(unittest.TestCase):
    def test_complete_disjoint_partition_and_future_tests_serial(self):
        names = ['T.first', 'T.second', 'T.future']
        groups = RUNNER.partition(names, [('T.first', 3), ('T.second', 2)], 2)
        self.assertEqual(groups[0], ('future-serial', ['T.future']))
        assigned = [name for _, group in groups for name in group]
        self.assertCountEqual(assigned, names)
        self.assertEqual(len(assigned), len(set(assigned)))
        self.assertLessEqual(len(groups) - 2, 2)

    def test_jobs_one_retains_original_order_and_test_set(self):
        names = ['T.second', 'T.future', 'T.first']
        self.assertEqual(RUNNER.partition(names, [('T.first', 3)], 1), [('serial', names)])

    def test_three_jobs_keep_future_tests_serial_and_assign_each_reviewed_case_once(self):
        names = ['T.first', 'T.second', 'T.third', 'T.future']
        groups = RUNNER.partition(
            names, [('T.first', 3), ('T.second', 2), ('T.third', 1)], 3
        )
        self.assertEqual(groups[0], ('future-serial', ['T.future']))
        self.assertEqual(len(groups[2:]), 3)
        self.assertCountEqual(
            [name for _, group in groups for name in group], names
        )

    def test_three_reviewed_shards_can_run_at_the_same_time(self):
        gate = threading.Barrier(3)

        def run(label, names):
            if label != 'serial':
                gate.wait(timeout=2)
            return dict(label=label, returncode=0, elapsed_s=0, stdout='', stderr='')

        groups = [('serial', ['T.future'])] + [
            (f'shard-{index}', [f'T.{index}']) for index in range(1, 4)
        ]
        reports = RUNNER.execute(groups, run=run)
        self.assertEqual(len(reports), 4)
        self.assertTrue(RUNNER.successful(reports))

    def test_reviewed_serial_overlaps_shards_but_future_tests_finish_first(self):
        names = ['T.safety', 'T.private1', 'T.private2', 'T.private3', 'T.future']
        groups = RUNNER.partition(
            names,
            [('T.private1', 3), ('T.private2', 2), ('T.private3', 1)],
            3,
            reviewed_serial=['T.safety'],
        )
        self.assertEqual(groups[0], ('future-serial', ['T.future']))
        self.assertEqual(groups[1], ('reviewed-serial', ['T.safety']))
        gate = threading.Barrier(4)
        finished_future = False

        def run(label, selected):
            nonlocal finished_future
            if label == 'future-serial':
                finished_future = True
            else:
                self.assertTrue(finished_future)
                gate.wait(timeout=2)
            return dict(label=label, returncode=0, elapsed_s=0, stdout='', stderr='')

        reports = RUNNER.execute(groups, run=run)
        self.assertEqual(len(reports), 5)
        self.assertTrue(RUNNER.successful(reports))

    def test_future_serial_failure_does_not_start_reviewed_groups(self):
        calls = []

        def run(label, selected):
            calls.append(label)
            return dict(label=label, returncode=7, elapsed_s=0, stdout='', stderr='')

        reports = RUNNER.execute(
            [('future-serial', ['T.future']), ('reviewed-serial', ['T.safety']),
             ('shard-1', ['T.private'])], run=run
        )
        self.assertEqual(calls, ['future-serial'])
        self.assertFalse(RUNNER.successful(reports))

    def test_future_gate_is_found_by_role_even_if_groups_are_reordered(self):
        calls = []

        def run(label, selected):
            calls.append(label)
            return dict(label=label, returncode=5 if label == 'future-serial' else 0,
                        elapsed_s=0, stdout='', stderr='')

        reports = RUNNER.execute(
            [('shard-1', ['T.private']), ('future-serial', ['T.future']),
             ('reviewed-serial', ['T.safety'])], run=run
        )
        self.assertEqual(calls, ['future-serial'])
        self.assertFalse(RUNNER.successful(reports))

    def test_report_distinguishes_planned_from_executed_after_gate_failure(self):
        groups = [('future-serial', ['T.future']), ('reviewed-serial', ['T.safety']),
                  ('shard-1', ['T.private'])]
        reports = [dict(label='future-serial', test_count=1, returncode=5,
                        elapsed_s=0.2, stdout='', stderr='')]
        summary = RUNNER.make_summary(3, groups, reports, 0.2)
        self.assertEqual(summary['planned_tests'], 3)
        self.assertEqual(summary['executed_tests'], 1)

    def test_reviewed_serial_registry_rejects_stale_duplicate_and_overlap(self):
        for reviewed in (['T.missing'], ['T.safety', 'T.safety'], ['T.private']):
            with self.subTest(reviewed=reviewed), self.assertRaises(ValueError):
                RUNNER.partition(
                    ['T.safety', 'T.private'], [('T.private', 1)], 3,
                    reviewed_serial=reviewed,
                )

    def test_missing_duplicate_or_invalid_registry_fails_before_execution(self):
        for names, allowed, jobs in [(['T.a'], [('T.missing', 1)], 2),
                                     (['T.a', 'T.a'], [('T.a', 1)], 2),
                                     (['T.a'], [('T.a', 1), ('T.a', 2)], 2),
                                     (['T.a'], [('T.a', 1)], 4)]:
            with self.subTest(names=names, allowed=allowed, jobs=jobs), self.assertRaises(ValueError):
                RUNNER.partition(names, allowed, jobs)

    def test_unselected_tests_are_not_added_to_benchmark_subset(self):
        groups = RUNNER.partition(['T.a', 'T.b', 'T.future'], [('T.a', 1), ('T.b', 2)], 2,
                                  selected=['T.a', 'T.future'])
        self.assertCountEqual([name for _, group in groups for name in group], ['T.a', 'T.future'])

    def test_reviewed_private_fixture_cases_leave_only_safety_case_serial(self):
        reviewed = [
            'PrepareIntegrationTests.test_global_allowlist_definitions_follow_exact_profiles_and_warm_digest',
            'PrepareIntegrationTests.test_selected_global_definition_edits_invalidate_or_fail_closed',
            'PrepareIntegrationTests.test_external_agents_survive_warm_and_cold_prepare_without_becoming_managed',
            'PrepareIntegrationTests.test_warm_path_repairs_launcher_owned_config_semantics',
            'PrepareIntegrationTests.test_manifest_skill_wins_command_collision_without_source_write',
        ]
        safety_case = 'PrepareIntegrationTests.test_candidate_failure_and_signal_preserve_managed_and_runtime_state'
        groups = RUNNER.partition(
            RUNNER.discover(),
            RUNNER.ALLOWLIST,
            2,
            selected=reviewed + [safety_case],
            reviewed_serial=[safety_case],
        )
        self.assertEqual(groups[0], ('future-serial', []))
        self.assertEqual(groups[1], ('reviewed-serial', [safety_case]))
        self.assertCountEqual(
            [name for _, group in groups[2:] for name in group],
            reviewed,
        )

    def test_all_serial_completes_before_parallel_children_start_and_failures_propagate(self):
        finished_serial = False
        calls = []
        def run(label, names):
            nonlocal finished_serial
            if label == 'serial':
                finished_serial = True
            else:
                self.assertTrue(finished_serial)
            calls.append(label)
            return dict(label=label, returncode={'serial': 0, 'shard-1': -15, 'shard-2': 3}[label],
                        elapsed_s=0, stdout='', stderr='fixture failure')
        groups = [('serial', ['T.serial']), ('shard-1', ['T.a']), ('shard-2', ['T.b'])]
        reports = RUNNER.execute(groups, run=run)
        self.assertEqual([report['label'] for report in reports], ['serial', 'shard-1', 'shard-2'])
        self.assertCountEqual(calls, ['serial', 'shard-1', 'shard-2'])
        self.assertFalse(RUNNER.successful(reports))

    def test_launch_failure_is_a_failed_report(self):
        with mock.patch.object(RUNNER.subprocess, 'run', side_effect=FileNotFoundError('missing interpreter')):
            report = RUNNER.run_group('serial', ['T.fixture'])
        self.assertNotEqual(report['returncode'], 0)
        self.assertIn('missing interpreter', report['stderr'])

    def test_group_report_includes_each_real_test_wall_time(self):
        expected = [{"id": "T.fixture", "elapsed_s": 0.125}]

        def completed(command, **kwargs):
            timing_path = kwargs.get('env', {}).get('HARNESS_UNITTEST_TIMING_REPORT')
            if timing_path:
                Path(timing_path).write_text(
                    json.dumps({"schema_version": 1, "tests": expected}),
                    encoding='utf-8',
                )
            return subprocess.CompletedProcess(command, 0, stdout='ok\n', stderr='')

        with mock.patch.object(RUNNER.subprocess, 'run', side_effect=completed):
            report = RUNNER.run_group('shard-1', ['T.fixture'])
        self.assertEqual(report.get('tests'), expected)

    def test_bad_timing_json_preserves_child_failure_output(self):
        def completed(command, **kwargs):
            Path(kwargs['env']['HARNESS_UNITTEST_TIMING_REPORT']).write_text('{bad json')
            return subprocess.CompletedProcess(command, 23, stdout='ORIGINAL OUT\n',
                                               stderr='ORIGINAL FAILURE\n')

        with mock.patch.object(RUNNER.subprocess, 'run', side_effect=completed):
            report = RUNNER.run_group('serial', ['T.fixture'])
        self.assertEqual(report['returncode'], 23)
        self.assertIn('ORIGINAL FAILURE', report['stderr'])
        self.assertIn('ORIGINAL OUT', report['stdout'])
        self.assertFalse(report['timing_complete'])
        self.assertIsNone(report['executed_count'])
        self.assertIn('timing report', report['timing_error'])

    def test_missing_timing_json_does_not_report_success_or_zero_executed(self):
        def completed(command, **kwargs):
            return subprocess.CompletedProcess(command, 0, stdout='child ran\n', stderr='')

        with mock.patch.object(RUNNER.subprocess, 'run', side_effect=completed):
            report = RUNNER.run_group('serial', ['T.fixture'])
        self.assertNotEqual(report['returncode'], 0)
        self.assertEqual(report['stdout'], 'child ran\n')
        self.assertFalse(report['timing_complete'])
        self.assertIsNone(report['executed_count'])
        self.assertIsNone(RUNNER.make_summary(2, [('serial', ['T.fixture'])],
                                              [report], 0.1)['executed_tests'])


if __name__ == '__main__':
    unittest.main()
