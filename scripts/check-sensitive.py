"""Check tracked and non-ignored source files without printing credential values."""
import argparse
import ipaddress
from pathlib import Path, PurePosixPath
import re
import subprocess
import sys
from urllib.parse import urlsplit

SIGNATURES = {
    'private-key': re.compile(r'-----BEGIN (?:RSA |EC |DSA |OPENSSH |ENCRYPTED )?PRIVATE KEY-----'),
    'github-token': re.compile(r'\b(?:gh[pousr]_[A-Za-z0-9]{30,}|github_pat_[A-Za-z0-9_]{50,})\b'),
    'cloud-access-key': re.compile(r'\b(?:AKIA|ASIA)[A-Z0-9]{16}\b'),
    'google-api-key': re.compile(r'\bAIza[A-Za-z0-9_-]{30,}\b'),
    'provider-secret': re.compile(r'\bsk-(?:ant-api\d+-)?[A-Za-z0-9_-]{35,}\b'),
    'slack-token': re.compile(r'\bxox[baprs]-[A-Za-z0-9-]{20,}\b'),
    'jwt-literal': re.compile(r'\beyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\b'),
}
ASSIGNMENT = re.compile(r'''(?i)\b(password|passphrase|decomposed_passphrase|token|access_token|api[_-]?key|client[_-]?secret|private[_-]?key|encryption_key|dek_hex|secret)\b\s*["']?\s*[:=]\s*["']([^"'\r\n\\]{8,500})["']''')
ENV_ASSIGNMENT = re.compile(r'''(?i)^\s*(?:export\s+)?[A-Z0-9_]*(?:PASSWORD|SECRET|TOKEN|API_KEY|PRIVATE_KEY)\s*=\s*([^\s#"']{8,})''')
URL = re.compile(r'''https?://[^\s<>"'\\]+''')
SERVER_DEFAULT = re.compile(r'''\b(?:let|var)\s+(?:server|defaultServer|serverURL|baseURL)\s*=\s*["'](https?://[^"']+)["']''')
PRIVATE_NETWORKS = [ipaddress.ip_network(value) for value in ('10.0.0.0/8', '172.16.0.0/12', '192.168.0.0/16')]
VECTOR_FILES = {'Tests/clip-v1.json', 'Tests/filerelay-v1.json'}
PRIVATE_SUFFIXES = {'.pem', '.key', '.p8', '.p12', '.pfx', '.mobileprovision', '.provisionprofile', '.jks', '.keystore', '.db', '.sqlite', '.sqlite3'}


def sensitive_path(path):
    name = PurePosixPath(path).name.lower()
    if name in {'.env.example', '.env.sample', '.env.template'}:
        return False
    return (name == '.env' or name.startswith('.env.') or
            PurePosixPath(name).suffix in PRIVATE_SUFFIXES or
            name in {'id_rsa', 'id_ed25519', 'credentials.json', 'secrets.xcconfig'} or name.endswith('.local.xcconfig'))


def fixture_context(path):
    return 'Tests/' in path or 'Preview' in path or path == 'scripts/make-fixture.py'


def example_host(host):
    return host in {'example.com', 'example.org', 'example.net'} or host.endswith(('.example.com', '.example.org', '.example.net', '.invalid'))


def findings_for(path, text):
    results = set()
    for number, line in enumerate(text.splitlines(), 1):
        for kind, pattern in SIGNATURES.items():
            if pattern.search(line):
                results.add((number, kind))
        for match in ASSIGNMENT.finditer(line):
            value = match.group(2).lower()
            fixture = fixture_context(path) and any(marker in value for marker in ('test', 'fixture', 'preview', 'example', 'dummy', 'mock', 'current', 'stale', 'old', 'new'))
            if path not in VECTOR_FILES and not fixture:
                results.add((number, 'credential-literal'))
        environment = ENV_ASSIGNMENT.match(line)
        if environment and PurePosixPath(path).name.startswith('.env'):
            value = environment.group(1).lower()
            placeholder = value.startswith(('${', '$(', '<', 'your_', 'replace_', 'example_', 'change_me', 'changeme'))
            if not placeholder:
                results.add((number, 'credential-literal'))
        for match in URL.finditer(line):
            try:
                address = urlsplit(match.group())
                host = address.hostname or ''
            except ValueError:
                results.add((number, 'malformed-url-needs-review'))
                continue
            if address.username and address.password and not (fixture_context(path) and example_host(host)):
                results.add((number, 'credential-in-url'))
            try:
                ip = ipaddress.ip_address(host)
            except ValueError:
                continue
            if any(ip.version == network.version and ip in network for network in PRIVATE_NETWORKS):
                results.add((number, 'private-network-address'))
        for match in SERVER_DEFAULT.finditer(line):
            try:
                host = urlsplit(match.group(1)).hostname or ''
            except ValueError:
                host = ''
            if not example_host(host):
                results.add((number, 'deployment-default'))
    return sorted(results)


def source_files(root):
    result = subprocess.run(['git', '-C', str(root), 'ls-files', '--cached', '--others', '--exclude-standard', '-z'], capture_output=True, check=True)
    return sorted(set(path.decode('utf-8') for path in result.stdout.split(b'\0') if path))


def scan(root):
    failures = []
    paths = source_files(root)
    for relative in paths:
        path = root / relative
        if sensitive_path(relative):
            failures.append((relative, 1, 'sensitive-file'))
        if path.is_symlink():
            failures.append((relative, 1, 'symbolic-link-needs-review'))
            continue
        if not path.is_file():
            continue
        if path.stat().st_size > 5 * 1024 * 1024:
            failures.append((relative, 1, 'large-file-needs-review'))
            continue
        raw = path.read_bytes()
        if raw.startswith((b'\xff\xfe', b'\xfe\xff')):
            text = raw.decode('utf-16', errors='replace')
        elif b'\0' in raw[:8192]:
            continue
        else:
            text = raw.decode('utf-8', errors='replace')
        failures.extend((relative, line, kind) for line, kind in findings_for(relative, text))
    return paths, failures


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root', type=Path, default=Path(__file__).resolve().parents[1])
    args = parser.parse_args()
    try:
        paths, failures = scan(args.root.resolve())
    except (OSError, UnicodeError, subprocess.CalledProcessError) as error:
        print('Sensitive-information check could not read the repository: ' + type(error).__name__, file=sys.stderr)
        return 2
    for path, line, kind in failures:
        print(f'{path}:{line}: {kind} (value withheld)')
    print(f'{len(paths)} source files checked; {len(failures)} finding(s). Credential values are never printed.')
    print('This check covers current source, not Git history, Actions artifacts or all forms of personal information.')
    return bool(failures)


if __name__ == '__main__':
    sys.exit(main())
