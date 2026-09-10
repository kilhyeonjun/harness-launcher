import importlib.util
from pathlib import Path
import unittest
from unittest import mock

SPEC = importlib.util.spec_from_file_location('surface_runner', Path(__file__).with_name('surface_test_runner.py'))
RUNNER = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(RUNNER)


class PartitionTests(unittest.TestCase):
    def test_complete_disjoint_partition_and_future_tests_serial(self):
        names = ['T.first', 'T.second', 'T.future']
        groups = RUNNER.partition(names, [('T.first', 3), ('T.second', 2)], 2)
        self.assertEqual(groups[0], ('serial', ['T.future']))
        assigned = [name for _, group in groups for name in group]
        self.assertCountEqual(assigned, names)
        self.assertEqual(len(assigned), len(set(assigned)))
        self.assertLessEqual(len(groups) - 1, 2)

    def test_jobs_one_retains_original_order_and_test_set(self):
        names = ['T.second', 'T.future', 'T.first']
        self.assertEqual(RUNNER.partition(names, [('T.first', 3)], 1), [('serial', names)])

    def test_missing_duplicate_or_invalid_registry_fails_before_execution(self):
        for names, allowed, jobs in [(['T.a'], [('T.missing', 1)], 2),
                                     (['T.a', 'T.a'], [('T.a', 1)], 2),
                                     (['T.a'], [('T.a', 1), ('T.a', 2)], 2),
                                     (['T.a'], [('T.a', 1)], 3)]:
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
        )
        self.assertEqual(groups[0], ('serial', [safety_case]))
        self.assertCountEqual(
            [name for _, group in groups[1:] for name in group],
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


if __name__ == '__main__':
    unittest.main()
