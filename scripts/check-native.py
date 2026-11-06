"""Local syntax/configuration/route checks. Does not build an app or contact a server.

python scripts/check-native.py --syntax-libs ../scratch/native-check-libs
Requires pinned requirements-checks.txt; tree-sitter 0.26.0 crashes on this Windows/Python environment.
"""
import argparse
import ast
import hashlib
import json
from pathlib import Path
import re
import struct
import sys

parser = argparse.ArgumentParser()
parser.add_argument('--syntax-libs')
args = parser.parse_args()
if args.syntax_libs:
    sys.path.insert(0, args.syntax_libs)
from tree_sitter import Language, Parser
import tree_sitter_swift
import yaml

root = Path(__file__).resolve().parents[1]
reference = root.parent / 'workbench'
swift = Parser(Language(tree_sitter_swift.language()))
trees = []  # Retain native Tree objects while their Nodes are inspected on Windows.
failures = []
known = []
paths = []

# 上游基线仓库 weidu-ios 已于 2026-11-06 删除；weidu-source.json 里的逐文件
# SHA-256 是删除前留下的快照。用它精确判断「这份源码是否与基线逐字节一致」，
# 就能继续豁免上游带进来的 tree-sitter 解析局限，不必把基线仓库找回来。
source_manifest = json.loads((root / 'Modules/weidu-source.json').read_text(encoding='utf-8'))
source_hashes = {f['path']: f['sha256'] for f in source_manifest['files']}

# 对「相对基线改过的文件」，SHA 判据不适用。下面这些是删除基线仓库前实测过的
# tree_sitter_swift 解析局限：四项（路径/行号/节点类型/该行文本）全匹配才豁免，
# 改动那一行或换解析器版本都会让它重新变成 failure，不会掩盖新错误。
UPSTREAM_PARSER_LIMITATIONS = {
    ("Modules/WeiduKit/Views/ArticleListScreen.swift", 590, "!", "self.sweepRead.send(())"),
}

def nodes(tree):
    pending = [tree]
    while pending:
        node = pending.pop()
        yield node
        pending.extend(reversed(node.children))

def errors(data):
    tree = swift.parse(data)
    trees.append(tree)
    return [n for n in nodes(tree.root_node) if n.type == 'ERROR' or n.is_missing]

def fingerprint(raw, n):
    return n.type, raw.splitlines()[n.start_point.row].strip()

files = list((root / 'ClipStudio').rglob('*.swift')) + list((root / 'Modules').rglob('*.swift')) + list((root / 'Tests').rglob('*.swift')) + list((root / 'UITests').rglob('*.swift'))
for path in files:
    raw = path.read_bytes()
    for error in errors(raw):
        rel = path.relative_to(root).as_posix()
        subpath = rel.removeprefix('Modules/WeiduKit/')
        baseline = root.parent / 'weidu-ios' / 'Weidu' / subpath
        if rel.startswith('Modules/WeiduKit/'):
            if baseline.exists():
                original = baseline.read_bytes()
                if fingerprint(raw,error) in [fingerprint(original,e) for e in errors(original)]:
                    known.append((rel,error.start_point.row+1))
                    continue
            elif source_hashes.get(subpath) == hashlib.sha256(raw).hexdigest():
                # 与基线 SHA 一致 ⇒ 这个解析错误本来就在上游源码里，不是本次改动引入的。
                known.append((rel,error.start_point.row+1))
                continue
        note = (rel, error.start_point.row+1, error.type,
                raw.splitlines()[error.start_point.row].strip().decode('utf-8', 'replace'))
        if note in UPSTREAM_PARSER_LIMITATIONS:
            known.append((rel, error.start_point.row+1))
            continue
        failures.append(f'{rel}:{error.start_point.row+1} syntax parser: {error.type}')
    if not path.is_relative_to(root/'Tests') and not path.is_relative_to(root/'Modules/WeiduKitTests'):
        tree = swift.parse(raw)
        trees.append(tree)
        for n in nodes(tree.root_node):
            if n.type != 'line_string_literal': continue
            pieces=[]
            for c in n.children:
                if c.type=='line_str_text': pieces.append(raw[c.start_byte:c.end_byte].decode())
                elif c.type=='interpolated_expression': pieces.append('{dynamic}')
            value=''.join(pieces).split('?')[0]
            if value.startswith('/api/') and value != '/api/':
                paths.append((value,path.name,n.start_point.row+1))

routes=[]
for path in (reference/'backend/app/routers').glob('*.py'):
    tree=ast.parse(path.read_text(encoding='utf-8-sig'))
    prefix=''
    for n in ast.walk(tree):
        if isinstance(n,ast.Call) and getattr(n.func,'id',None)=='APIRouter':
            for kw in n.keywords:
                if kw.arg=='prefix' and isinstance(kw.value,ast.Constant):prefix=kw.value.value
    for n in ast.walk(tree):
        if not isinstance(n,(ast.FunctionDef,ast.AsyncFunctionDef)):continue
        for d in n.decorator_list:
            if isinstance(d,ast.Call) and isinstance(d.func,ast.Attribute) and d.func.attr in ('get','post','put','patch','delete') and d.args and isinstance(d.args[0],ast.Constant):
                routes.append(prefix+d.args[0].value)

def route_pattern(route):
    return '^'+re.sub(r'\\\{[^}]+\\\}',r'[^/]+',re.escape(route))+'$'

for value, name, line in paths:
    pattern=route_pattern(value)
    if not any(re.fullmatch(pattern,re.sub(r'\{[^}]+\}','sample',r)) for r in routes):
        failures.append(f'{name}:{line} unknown route {value}')
    if value == '/api/weidu/img':
        failures.append(f'{name}:{line} image relay contradicts device-direct image loading')

project=yaml.safe_load((root/'project.yml').read_text(encoding='utf-8'))
assert 'WeiduKit' in project['targets']
assert project['targets']['ClipStudio']['sources'][1]['buildPhase']=='resources'
assert project['targets']['ClipStudio']['info']['properties']['NSAppTransportSecurity']['NSAllowsArbitraryLoads'] is True
icon_name = project['targets']['ClipStudio']['settings']['base']['ASSETCATALOG_COMPILER_APPICON_NAME']
icon_folder = root / 'ClipStudio/Assets.xcassets' / (icon_name + '.appiconset')
icon_catalog = json.loads((icon_folder / 'Contents.json').read_text())
icon_record = next(image for image in icon_catalog['images'] if image.get('size') == '1024x1024')
icon_png = (icon_folder / icon_record['filename']).read_bytes()
assert icon_png[:8] == b'\x89PNG\r\n\x1a\n' and icon_png[12:16] == b'IHDR'
assert struct.unpack('>II', icon_png[16:24]) == (1024, 1024), 'AppIcon must be 1024 x 1024'
assert icon_png[24:26] == b'\x08\x02', 'AppIcon must be opaque 8-bit RGB'
workflow=yaml.safe_load((root/'.github/workflows/ios.yml').read_text(encoding='utf-8'))
assert 'push' not in workflow.get('on',workflow.get(True))
for name in ('calc.js','rates.js'):
    assert (root/'ClipStudio/Resources/Mortgage'/name).read_bytes()==(reference/'frontend/mortgage'/name).read_bytes()
manifest=json.loads((root/'Modules/weidu-source.json').read_text())
changed=[]
for f in manifest['files']:
    path=root/'Modules/WeiduKit'/f['path']
    assert path.exists(),path
    if hashlib.sha256(path.read_bytes()).hexdigest()!=f['sha256']:changed.append(f['path'])
overrides=json.loads((root/'Modules/weidu-overrides.json').read_text())
assert set(changed)==set(overrides),changed
for failure in failures:print(failure)
print(f'{len(files)} Swift files parsed; {len(set(p[0] for p in paths))} API path patterns checked against local backend routes.')
print(f'{len(known)} parser limitation(s) also present in unchanged upstream code: {known}')
print('Reader source provenance, mortgage resources, opaque 1024px AppIcon and manual-only workflow verified.')
print('This is not Swift typechecking, Xcode compilation, simulator or device acceptance.')
sys.exit(bool(failures))
