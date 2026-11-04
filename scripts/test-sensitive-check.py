"""Offline regressions for the publication guard; no real credentials or network calls."""
import importlib.util
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

spec = importlib.util.spec_from_file_location('sensitive_check', Path(__file__).with_name('check-sensitive.py'))
check = importlib.util.module_from_spec(spec)
spec.loader.exec_module(check)


class SensitiveCheckTests(unittest.TestCase):
    def test_provider_token_is_rejected_even_in_tests(self):
        value = 'ghp_' + 'A' * 36
        self.assertIn((1, 'github-token'), check.findings_for('Tests/Example.swift', value))

    def test_private_key_header_is_rejected(self):
        value = '-----BEGIN ' + 'OPENSSH PRIVATE KEY-----'
        self.assertIn((1, 'private-key'), check.findings_for('config.txt', value))

    def test_real_looking_credential_assignment_is_rejected(self):
        payload = 'password' + ' = "' + 'opaque-credential-123456' + '"'
        self.assertIn((1, 'credential-literal'), check.findings_for('settings.py', payload))

    def test_fixture_literals_are_allowed_but_signatures_are_not(self):
        payload = 'token' + ': "fixture-token"'
        self.assertEqual(check.findings_for('Tests/ClientTests.swift', payload), [])
        self.assertIn((1, 'credential-literal'), check.findings_for('Client.swift', payload))

    def test_fixed_protocol_vectors_are_allowed(self):
        payload = 'dek_hex' + ': "' + '01' * 32 + '"'
        self.assertEqual(check.findings_for('Tests/filerelay-v1.json', payload), [])
        self.assertIn((1, 'credential-literal'), check.findings_for('production.json', payload))

    def test_unquoted_environment_credentials_need_placeholders(self):
        payload = 'SERVICE_TOKEN' + '=opaque-credential-123456'
        self.assertIn((1, 'credential-literal'), check.findings_for('.env.example', payload))
        self.assertEqual(check.findings_for('Client.swift', '    token = api.token'), [])
        for placeholder in ['your_token_here', '${SERVICE_TOKEN}', '<insert-token>', 'replace_with_token']:
            self.assertEqual(check.findings_for('.env.example', 'SERVICE_TOKEN' + '=' + placeholder), [])

    def test_example_url_rejection_fixture_is_allowed(self):
        value = 'https://' + 'user:secret@example.com'
        self.assertEqual(check.findings_for('Tests/CryptoTests.swift', value), [])
        self.assertIn((1, 'credential-in-url'), check.findings_for('Client.swift', value))

    def test_deployment_defaults_are_not_bundled(self):
        payload = 'var server = "https://' + 'service.example.net"'
        self.assertEqual(check.findings_for('Client.swift', payload), [])
        self.assertIn((1, 'deployment-default'), check.findings_for('Client.swift', payload.replace('example.net', 'invalid-domain.test')))
        self.assertEqual(check.findings_for('Client.swift', 'var server = ""'), [])

    def test_private_network_address_is_not_a_deployment_example(self):
        payload = 'https://' + '192.168.1.20:8443'
        self.assertIn((1, 'private-network-address'), check.findings_for('Client.swift', payload))
        self.assertEqual(check.findings_for('Tests/MediaTests.swift', 'http://127.0.0.1:8765/rss'), [])

    def test_sensitive_names_and_safe_environment_templates(self):
        for path in ['.env', '.env.local', 'Config/distribution.p12', 'Config/auth.p8', 'backup.sqlite', 'id_ed25519']:
            self.assertTrue(check.sensitive_path(path), path)
        for path in ['.env.example', '.env.sample', '.env.template', 'Tests/clip-v1.json', 'ClipStudio/Keychain.swift']:
            self.assertFalse(check.sensitive_path(path), path)

    def test_scan_includes_new_files_but_does_not_print_values(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            subprocess.run(['git', 'init', '-q', str(root)], check=True)
            value = 'github_pat_' + 'A' * 60
            (root / 'new.swift').write_text(value, encoding='utf-8')
            paths, failures = check.scan(root)
            self.assertIn('new.swift', paths)
            self.assertIn(('new.swift', 1, 'github-token'), failures)
            result = subprocess.run([sys.executable, '-I', str(Path(__file__).with_name('check-sensitive.py')), '--root', str(root)], capture_output=True, text=True)
            self.assertEqual(result.returncode, 1)
            self.assertIn('new.swift:1: github-token (value withheld)', result.stdout)
            self.assertNotIn(value, result.stdout + result.stderr)

    def test_tracked_credentials_are_checked_even_when_later_ignored(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            subprocess.run(['git', 'init', '-q', str(root)], check=True)
            (root / '.env').write_text('local placeholder', encoding='utf-8')
            subprocess.run(['git', '-C', str(root), 'add', '.env'], check=True)
            (root / '.gitignore').write_text('.env\n', encoding='utf-8')
            paths, failures = check.scan(root)
            self.assertIn('.env', paths)
            self.assertIn(('.env', 1, 'sensitive-file'), failures)

    def test_ignored_local_credentials_are_not_read(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            subprocess.run(['git', 'init', '-q', str(root)], check=True)
            (root / '.gitignore').write_text('.env\n', encoding='utf-8')
            (root / '.env').write_text('local placeholder', encoding='utf-8')
            paths, failures = check.scan(root)
            self.assertNotIn('.env', paths)
            self.assertEqual(failures, [])


if __name__ == '__main__':
    unittest.main()
