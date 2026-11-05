"""Exercise manual build modes and validation gates without Xcode or network access."""
import copy
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

import yaml

ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location('ios_build_policy', ROOT / 'scripts/ios-build-policy.py')
policy = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(policy)


class Modes(unittest.TestCase):
    def test_default_is_fresh_native_unit_validation(self):
        value = policy.resolve_policy()
        self.assertEqual(value['mode'], 'unit')
        self.assertTrue(value['run_tests'])
        self.assertEqual(value['scheme'], 'ClipStudio')
        self.assertFalse(value['export_ui'])

    def test_package_has_no_simulator_tests_or_ui(self):
        value = policy.resolve_policy('package')
        self.assertFalse(value['run_tests'])
        self.assertFalse(value['export_ui'])
        self.assertEqual(value['reuse_run'], '')

    def test_full_uses_acceptance_scheme_without_a_second_preflight(self):
        value = policy.resolve_policy('full')
        self.assertTrue(value['run_tests'])
        self.assertTrue(value['export_ui'])
        self.assertEqual(value['scheme'], 'AcceptanceChecks')

    def test_legacy_interface_flag_preserves_full_validation(self):
        self.assertEqual(policy.resolve_policy('unit', True)['mode'], 'full')
        with self.assertRaises(ValueError):
            policy.resolve_policy('package', True)

    def test_reuse_is_explicit_and_only_in_unit_mode(self):
        value = policy.resolve_policy('unit', validated_run='123')
        self.assertFalse(value['run_tests'])
        self.assertEqual(value['reuse_run'], '123')
        for mode in ('package', 'full'):
            with self.assertRaises(ValueError):
                policy.resolve_policy(mode, validated_run='123')

    def test_bad_modes_and_run_ids_cannot_become_shell_outputs(self):
        for mode in ('other', 'unit\nrun_tests=false', '../package'):
            with self.assertRaises(ValueError):
                policy.resolve_policy(mode)
        for run in ('0', '-1', '1/../2', '123\nmode=package', 'a', '1' * 21):
            with self.assertRaises(ValueError):
                policy.resolve_policy(validated_run=run)

    def test_package_never_claims_test_validation_even_with_success_values(self):
        value = policy.validation_record(policy.resolve_policy('package'), 'success', 'success', 'success', 'a' * 40)
        self.assertEqual(value['validation'], 'not_run')
        self.assertFalse(value['tests_passed_this_run'])
        self.assertFalse(value['native_validated'])
        self.assertFalse(value['ui_validated'])
        self.assertTrue(value['package_created'])

    def test_full_and_unit_records_do_not_mix_ui_claims(self):
        for mode in ('unit', 'full'):
            value = policy.validation_record(policy.resolve_policy(mode), 'success', 'skipped', 'success', 'a' * 40)
            self.assertTrue(value['native_validated'])
            self.assertEqual(value['ui_validated'], mode == 'full')
        failed = policy.validation_record(policy.resolve_policy('full'), 'failure', 'skipped', 'skipped', 'a' * 40)
        self.assertFalse(failed['native_validated'])
        self.assertFalse(failed['ui_validated'])
        self.assertEqual(failed['native_step_outcome'], 'failure')

    def test_reused_validation_is_not_reported_as_fresh_tests(self):
        p = policy.resolve_policy(validated_run='123')
        value = policy.validation_record(p, 'skipped', 'success', 'success', 'a' * 40)
        self.assertEqual(value['validation'], 'reused_unit')
        self.assertTrue(value['native_validated'])
        self.assertFalse(value['tests_passed_this_run'])
        self.assertFalse(value['ui_validated'])
        self.assertEqual(value['validation_source_run'], '123')
        self.assertFalse(policy.validation_record(p, 'skipped', 'failure', 'skipped', 'a' * 40)['native_validated'])

    def test_configure_cli_emits_expected_github_outputs(self):
        for mode in ('unit', 'package', 'full'):
            with self.subTest(mode=mode), tempfile.TemporaryDirectory() as directory:
                output = Path(directory) / 'outputs.txt'
                env = dict(os.environ, BUILD_MODE=mode, INTERFACE_CHECKS='false', VALIDATED_RUN='', GITHUB_OUTPUT=str(output))
                result = subprocess.run([sys.executable, '-I', str(ROOT / 'scripts/ios-build-policy.py'), 'configure'],
                                        cwd=directory, env=env, capture_output=True, text=True, check=True)
                values = dict(line.split('=', 1) for line in output.read_text(encoding='utf-8').splitlines())
                self.assertEqual(values['mode'], mode)
                self.assertEqual(values['run_tests'], 'false' if mode == 'package' else 'true')
                self.assertEqual(json.loads(result.stdout)['mode'], mode)


class ValidationSource(unittest.TestCase):
    def setUp(self):
        self.repository = 'fixture-owner/workbench-ios'
        self.run = {'path': policy.WORKFLOW, 'status': 'completed', 'conclusion': 'success',
                    'head_repository': {'full_name': self.repository}, 'head_sha': 'a' * 40}
        self.jobs = [{'name': 'build', 'steps': [{'name': policy.NATIVE_STEP, 'conclusion': 'success'}]}]

    def test_successful_fresh_native_run_qualifies(self):
        self.assertEqual(policy.verified_source(self.run, self.jobs, self.repository), 'a' * 40)

    def test_package_only_and_reused_runs_do_not_qualify(self):
        for status in ('skipped', 'failure', 'cancelled', None):
            jobs = copy.deepcopy(self.jobs); jobs[0]['steps'][0]['conclusion'] = status
            with self.assertRaises(ValueError):
                policy.verified_source(self.run, jobs, self.repository)

    def test_other_repo_workflow_failed_or_incomplete_runs_are_rejected(self):
        changes = ({'head_repository': {'full_name': 'other-owner/workbench-ios'}}, {'head_repository': None},
                   {'path': '.github/workflows/interface.yml'}, {'conclusion': 'failure'}, {'conclusion': 'cancelled'},
                   {'status': 'in_progress'}, {'head_sha': '../unsafe'}, {'head_sha': ''})
        for changeset in changes:
            run = dict(self.run, **changeset)
            with self.subTest(change=changeset), self.assertRaises(ValueError):
                policy.verified_source(run, self.jobs, self.repository)

    def test_missing_or_ambiguous_native_test_step_is_rejected(self):
        for jobs in ([], [{'name': 'build', 'steps': []}], self.jobs * 2, [{'name': 'other', 'steps': self.jobs[0]['steps']}]):
            with self.assertRaises(ValueError):
                policy.verified_source(self.run, jobs, self.repository)


class SourceIdentity(unittest.TestCase):
    def test_product_test_project_and_lockfile_changes_invalidate_reuse(self):
        paths = ['ClipStudio/App.swift', 'Modules/WeiduKit/View.swift', 'Tests/Unit.swift', 'UITests/Flow.swift',
                 'project.yml', 'Package.resolved', 'README.md', 'docs/guide.md', '.github/workflows/ios.yml',
                 '.github/workflows/interface.yml', 'scripts/ios-build-policy.py', 'scripts/test-ios-build-policy.py']
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            env = {key: value for key, value in os.environ.items() if not key.startswith('GIT_')}
            env.update(GIT_CONFIG_NOSYSTEM='1', GIT_CONFIG_GLOBAL=os.devnull, GIT_CONFIG_COUNT='0',
                       GIT_AUTHOR_NAME='Build policy fixture', GIT_AUTHOR_EMAIL='fixture@example.invalid',
                       GIT_COMMITTER_NAME='Build policy fixture', GIT_COMMITTER_EMAIL='fixture@example.invalid')

            def git(*args):
                return subprocess.run(['git', *args], cwd=root, env=env, capture_output=True, text=True, check=True).stdout.strip()

            git('init', '--quiet', '--initial-branch=main', '--template=')
            for name in paths:
                path = root / name; path.parent.mkdir(parents=True, exist_ok=True); path.write_text('baseline\n')
            git('add', '.')
            message = 'Build policy fixture\n\nCo-Authored-By: Claude Fable 5 <noreply@anthropic.com>'
            git('commit', '--quiet', '-m', message)
            baseline = git('rev-parse', 'HEAD')
            for index, name in enumerate(paths):
                with self.subTest(path=name):
                    git('checkout', '--quiet', '-B', 'case-' + str(index), baseline)
                    (root / name).write_text('changed\n')
                    git('add', name); git('commit', '--quiet', '-m', message)
                    commands = policy.source_commands(baseline)
                    subprocess.run(commands[0], cwd=root, env=env, check=True, capture_output=True)
                    result = subprocess.run(commands[1], cwd=root, env=env, capture_output=True)
                    excluded = any(name == path or name.startswith(path + '/') for path in policy.NON_PRODUCT_PATHS)
                    self.assertEqual(result.returncode, 0 if excluded else 1)


class WorkflowWiring(unittest.TestCase):
    def setUp(self):
        self.workflow = yaml.safe_load((ROOT / '.github/workflows/ios.yml').read_text(encoding='utf-8'))
        self.steps = self.workflow['jobs']['build']['steps']
        self.by_id = {step['id']: step for step in self.steps if 'id' in step}

    def test_dispatch_remains_manual_and_defaults_to_unit(self):
        trigger = self.workflow.get('on', self.workflow.get(True))
        self.assertEqual(set(trigger), {'workflow_dispatch'})
        values = trigger['workflow_dispatch']['inputs']['build_mode']
        self.assertEqual(values['default'], 'unit')
        self.assertEqual(set(values['options']), policy.MODES)

    def test_simulator_and_native_steps_use_same_test_gate(self):
        for name in ('Select simulator', 'Boot simulator before tests', policy.NATIVE_STEP):
            step = next(step for step in self.steps if step.get('name') == name)
            self.assertEqual(step['if'], "steps.policy.outputs.run_tests == 'true'")
        self.assertIn('$TEST_SCHEME', self.by_id['native']['run'])
        self.assertEqual(self.by_id['native']['env']['TEST_SCHEME'], '${{ steps.policy.outputs.scheme }}')

    def test_duplicate_preflight_is_removed_but_reader_case_remains_in_full_suite(self):
        self.assertFalse(any('Preflight' in step.get('name', '') for step in self.steps))
        self.assertNotIn('layout-preflight', json.dumps(self.workflow))
        text = (ROOT / 'UITests/InterfaceTests.swift').read_text(encoding='utf-8')
        self.assertIn('func testReaderFirstRowFollowsHeaderOnLaunchSearchAndReturnToTop()', text)
        project = (ROOT / 'project.yml').read_text(encoding='utf-8')
        self.assertIn('AcceptanceChecks:', project)
        self.assertIn('ClipStudioUITests', project)

    def test_release_and_package_stay_required_for_all_modes(self):
        for name in ('Build unsigned iPhone app', 'Package IPA'):
            step = next(step for step in self.steps if step.get('name') == name)
            self.assertNotIn('if', step)
        package = self.by_id['package']['run']
        self.assertIn('CFBundleIdentifier', package)
        self.assertIn('-verify_arch arm64', package)

    def test_summary_and_source_run_gates_remain_wired(self):
        summary = next(step for step in self.steps if step.get('name') == 'Record validation level')
        self.assertIn("steps.policy.outcome == 'success'", summary['if'])
        self.assertEqual(summary['env']['NATIVE_OUTCOME'], '${{ steps.native.outcome }}')
        self.assertIn('validation-summary.json', self.steps[-1]['with']['path'])
        interface = yaml.safe_load((ROOT / '.github/workflows/interface.yml').read_text(encoding='utf-8'))
        step = next(step for step in interface['jobs']['interface']['steps'] if step.get('name') == 'Verify tested product sources')
        self.assertIn('ios-build-policy.py verify-source', step['run'])

    def test_shell_blocks_parse_without_running_xcode(self):
        for filename in ('ios.yml', 'interface.yml'):
            workflow = yaml.safe_load((ROOT / '.github/workflows' / filename).read_text(encoding='utf-8'))
            for job in workflow['jobs'].values():
                for step in job['steps']:
                    if 'run' in step:
                        subprocess.run(['bash', '-n'], input=step['run'], text=True, check=True, capture_output=True)


if __name__ == '__main__':
    unittest.main()
