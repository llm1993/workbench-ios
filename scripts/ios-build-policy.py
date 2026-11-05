"""Resolve manual iOS build modes and verify reusable native validation."""
import argparse
import json
import os
from pathlib import Path
import re
import subprocess
import urllib.error
import urllib.request

MODES = {'unit', 'package', 'full'}
NATIVE_STEP = 'Compile and test native workspace modules'
WORKFLOW = '.github/workflows/ios.yml'
NON_PRODUCT_PATHS = (
    '.github/workflows/ios.yml', '.github/workflows/interface.yml',
    'README.md', 'docs', 'scripts/ios-build-policy.py', 'scripts/test-ios-build-policy.py',
)


def resolve_policy(mode='unit', legacy_ui=False, validated_run=''):
    mode = mode or 'unit'
    if mode not in MODES:
        raise ValueError('Unknown build mode; use unit, package or full')
    if legacy_ui:
        if mode == 'package':
            raise ValueError('Package-only mode cannot enable UI checks')
        mode = 'full'
    validated_run = validated_run.strip()
    if validated_run and not re.fullmatch(r'[1-9][0-9]{0,19}', validated_run):
        raise ValueError('Validation run must be a positive numeric run ID')
    if validated_run and mode != 'unit':
        raise ValueError('Validation reuse is only supported in unit mode; full must run fresh and package does not claim validation')
    return {
        'mode': mode,
        'scheme': 'AcceptanceChecks' if mode == 'full' else 'ClipStudio',
        'run_tests': mode != 'package' and not validated_run,
        'export_ui': mode == 'full',
        'reuse_run': validated_run,
    }


def verified_source(run, jobs, repository):
    if not re.fullmatch(r'[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+', repository):
        raise ValueError('Invalid repository identity')
    if run.get('path') != WORKFLOW:
        raise ValueError('Unexpected validation workflow')
    if (run.get('head_repository') or {}).get('full_name', '').casefold() != repository.casefold():
        raise ValueError('Validation must originate from this repository')
    if run.get('status') != 'completed' or run.get('conclusion') != 'success':
        raise ValueError('Validation run must have completed successfully')
    tests = [step for job in jobs if job.get('name') == 'build'
             for step in job.get('steps', []) if step.get('name') == NATIVE_STEP]
    if len(tests) != 1 or tests[0].get('conclusion') != 'success':
        raise ValueError('Source run must execute and pass native tests; package-only and reused runs do not qualify')
    sha = run.get('head_sha', '')
    if not re.fullmatch(r'[0-9a-f]{40}', sha):
        raise ValueError('Invalid tested source commit')
    return sha


def source_commands(sha):
    return [
        ['git', 'merge-base', '--is-ancestor', sha, 'HEAD'],
        ['git', 'diff', '--exit-code', sha, 'HEAD', '--', '.',
         *[':!' + path for path in NON_PRODUCT_PATHS]],
    ]


def validation_record(policy, native, reused, packaged, sha):
    fresh = policy['mode'] != 'package' and not policy['reuse_run'] and native == 'success'
    reused_ok = policy['mode'] == 'unit' and bool(policy['reuse_run']) and reused == 'success'
    level = 'not_run' if policy['mode'] == 'package' else (
        'reused_unit' if reused_ok else ('full' if fresh and policy['mode'] == 'full' else ('unit' if fresh else 'not_passed')))
    return {
        'source_commit': sha, 'mode': policy['mode'], 'validation': level,
        'tests_passed_this_run': fresh, 'native_step_outcome': native or 'not_run',
        'native_validated': fresh or reused_ok,
        'ui_validated': fresh and policy['mode'] == 'full',
        'validation_source_run': policy['reuse_run'] if reused_ok else None,
        'package_created': packaged == 'success',
    }


def output(values):
    target = os.environ.get('GITHUB_OUTPUT')
    if target:
        with open(target, 'a', encoding='utf-8') as stream:
            for key, value in values.items():
                if isinstance(value, bool):
                    value = str(value).lower()
                stream.write(f'{key}={value}\n')


def configured_policy():
    legacy = os.environ.get('INTERFACE_CHECKS', 'false').lower()
    if legacy not in ('', 'true', 'false'):
        raise ValueError('Invalid legacy interface_checks value')
    return resolve_policy(os.environ.get('BUILD_MODE', 'unit'), legacy == 'true', os.environ.get('VALIDATED_RUN', ''))


def verify_remote(run_id):
    if not re.fullmatch(r'[1-9][0-9]{0,19}', run_id):
        raise ValueError('Source run must be a positive numeric run ID')
    repository = os.environ['GITHUB_REPOSITORY']
    if not re.fullmatch(r'[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+', repository):
        raise ValueError('Invalid repository identity')
    base = 'https://api.github.com/repos/' + repository
    headers = {'Authorization': 'Bearer ' + os.environ['GH_TOKEN'], 'Accept': 'application/vnd.github+json'}

    def get(path):
        with urllib.request.urlopen(urllib.request.Request(base + path, headers=headers), timeout=30) as response:
            return json.load(response)

    run = get('/actions/runs/' + run_id)
    jobs = get('/actions/runs/' + run_id + '/jobs?per_page=100&filter=latest')['jobs']
    sha = verified_source(run, jobs, repository)
    for command in source_commands(sha):
        subprocess.run(command, check=True)
    output({'source_sha': sha})
    print('Native validation passed for matching product, tests and project sources:', sha)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('command', choices=('configure', 'verify-source', 'summarize'))
    parser.add_argument('--run')
    args = parser.parse_args()
    if args.command == 'verify-source':
        verify_remote(args.run or '')
        return
    policy = configured_policy()
    if args.command == 'configure':
        output(policy)
        print(json.dumps(policy, ensure_ascii=False))
        return
    record = validation_record(policy, os.environ.get('NATIVE_OUTCOME', ''), os.environ.get('REUSE_OUTCOME', ''),
                               os.environ.get('PACKAGE_OUTCOME', ''), os.environ.get('GITHUB_SHA', ''))
    Path('validation-summary.json').write_text(json.dumps(record, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')
    labels = {'unit': '日常验证：原生单测 + Release', 'package': '快速打包：未运行测试', 'full': '完整验收：原生单测 + 全量 UI + Release'}
    text = '\n'.join((
        '## ' + labels[policy['mode']],
        '- 源码：`' + record['source_commit'] + '`',
        '- 本轮原生测试执行并通过：' + ('是' if record['tests_passed_this_run'] else '否'),
        '- 本轮 UI 验证通过：' + ('是' if record['ui_validated'] else '否'),
        '- 验证级别：`' + record['validation'] + '`',
        '- IPA 打包成功：' + ('是' if record['package_created'] else '否'),
        '- 快速打包不作为原生验证凭据；如有复用，验证来源另记在 JSON 中。', '',
    ))
    if os.environ.get('GITHUB_STEP_SUMMARY'):
        with open(os.environ['GITHUB_STEP_SUMMARY'], 'a', encoding='utf-8') as stream:
            stream.write(text)
    print(json.dumps(record, ensure_ascii=False))


if __name__ == '__main__':
    try:
        main()
    except (ValueError, KeyError, subprocess.CalledProcessError, urllib.error.URLError) as error:
        raise SystemExit('Build policy rejected the request: ' + (str(error) if isinstance(error, ValueError) else type(error).__name__)) from None
