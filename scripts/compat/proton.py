#!/usr/bin/env python3
"""Freequay: turns the per-game settings in Valve's Proton launcher script into compat/proton.txt.

The script `proton` (github.com/ValveSoftware/Proton) switches settings per Steam app ID: compat
flags in default_compat_config(), environment variables and DLL overrides in its session setup.
Most flags drive Proton's own Wine patches or Linux drivers; this keeps the ones CrossOver's Wine
or the game itself understands and notes the rest.

Usage: proton.py <proton script> [<version note>]
"""

import ast
import os
import re
import subprocess
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from common import Rules  # noqa: E402

FLAGS = {
    'heapzeromemory': ['env=WINE_HEAP_ZERO_MEMORY=1'],
    'fnad3d11': ['env=FNA3D_FORCE_DRIVER=D3D11'],
    'nod3d11': ['dll=d3d11='],
    'nod3d10': ['dll=d3d10=', 'dll=d3d10_1=', 'dll=d3d10core='],
    'wined3d': ['backend=wined3d'],
    'wined3d11': ['backend=wined3d'],
}
FLAG_NOTES = {
    'nomfdxgiman': 'Proton flag nomfdxgiman (Media Foundation)',
    'noopwr': 'Proton flag noopwr (Vulkan on Wayland)',
    'noforcelgadd': 'no forced Large Address Aware (Freequay does not force it anyway)',
    'hidevggpu': 'hide the Steam Deck GPU',
    'hideintelgpu': 'hide Intel GPUs',
    'hidenvgpu': 'hide NVIDIA GPUs',
    'hideapu': 'hide AMD APUs',
    'heapdelayfree': "delayed heap frees (missing in CrossOver's Wine)",
    'heaptopdown': "top-down heap allocation (missing in CrossOver's Wine)",
    'nofsync': 'disable fsync (Linux only)',
    'noesync': 'disable esync (on macOS msync applies to the whole bottle)',
    'disablenvapi': 'disable NVAPI (no NVIDIA GPU)',
    'forcenvapi': 'force NVAPI (no NVIDIA GPU)',
    'noxalia': 'Proton flag noxalia',
    'nohardwarescheduling': 'Proton flag nohardwarescheduling',
    'gamedrive': "Proton's game drive",
}
# variables CrossOver's Wine or the game reads; the others belong to Proton or Linux
KEEP_ENV = {'WINE_HEAP_ZERO_MEMORY', 'OPENSSL_ia32cap', 'WINE_MONO_HIDETYPES', 'FNA3D_FORCE_DRIVER',
            'WINE_LARGE_ADDRESS_AWARE'}


def appids(test):
    """Steam app IDs a condition compares against"""
    out = []
    for node in ast.walk(test):
        if isinstance(node, ast.Compare) and len(node.ops) == 1:
            left = ast.unparse(node.left)
            if not re.search(r'appid|SteamGameId|SteamAppId', left):
                continue
            right = node.comparators[0]
            if isinstance(node.ops[0], ast.In) and isinstance(right, (ast.List, ast.Tuple, ast.Set)):
                out += [e.value for e in right.elts if isinstance(e, ast.Constant) and str(e.value).isdigit()]
            elif isinstance(node.ops[0], ast.Eq) and isinstance(right, ast.Constant) and str(right.value).isdigit():
                out.append(right.value)
    return out


def effects(body):
    """(kind, name, value) for ret.add(), self.env[...] = and dlloverrides[...] = in a block"""
    for node in ast.walk(ast.Module(body=body, type_ignores=[])):
        if isinstance(node, ast.Call) and isinstance(node.func, ast.Attribute):
            target = ast.unparse(node.func.value)
            if node.func.attr == 'add' and target == 'ret' and isinstance(node.args[0], ast.Constant):
                yield 'flag', node.args[0].value, None
            elif node.func.attr == 'setdefault' and target.endswith('env') and len(node.args) == 2 and \
                    all(isinstance(a, ast.Constant) for a in node.args):
                yield 'env', node.args[0].value, node.args[1].value
        elif isinstance(node, ast.Assign) and len(node.targets) == 1 and isinstance(node.targets[0], ast.Subscript):
            sub = node.targets[0]
            target = ast.unparse(sub.value)
            if not (isinstance(sub.slice, ast.Constant) and isinstance(node.value, ast.Constant)):
                continue
            if target.endswith('.env'):
                yield 'env', sub.slice.value, node.value.value
            elif target.endswith('dlloverrides'):
                yield 'dll', sub.slice.value, node.value.value


def main():
    path = sys.argv[1]
    source = open(path, encoding='utf-8').read()
    tree = ast.parse(source)
    rules = Rules()
    for m in re.finditer(r'"(\d+)",?\s*#\s*(.+)', source):
        title = re.sub(r'\s*-\s*CW bug.*$', '', m.group(2), flags=re.I).strip()
        if title and not title.lower().startswith(('affected', 'cw ', 'just ')):
            rules.title(m.group(1), title)
    for node in ast.walk(tree):
        if not isinstance(node, ast.If):
            continue
        ids = appids(node.test)
        if not ids:
            continue
        for kind, name, value in effects(node.body):
            for appid in ids:
                key = 'steam:' + appid
                if kind == 'flag':
                    if name in FLAGS:
                        for d in FLAGS[name]:
                            rules.add(key, d)
                    else:
                        rules.note(key, 'not taken: ' + FLAG_NOTES.get(name, 'Proton flag ' + name))
                elif kind == 'env':
                    if name in KEEP_ENV:
                        rules.add(key, f'env={name}={value}')
                    else:
                        rules.note(key, f'not taken: variable {name}={value} (Proton or Linux)')
                elif kind == 'dll':
                    rules.add(key, f'dll={name}={"" if value == "d" else value}')
    commit = sys.argv[2] if len(sys.argv) > 2 else subprocess.run(
        ['git', '-C', os.path.dirname(path), 'log', '-1', '--format=%h %cs'], capture_output=True, text=True).stdout.strip()
    out = rules.write('proton', [
        "Freequay: rules from Valve's Proton (github.com/ValveSoftware/Proton, file proton),",
        f'as of {commit or os.path.basename(path)}, license BSD-3-Clause (Copyright Valve Corporation).',
        'Generated by scripts/compat/proton.py, do not edit by hand; what was left out is in notes.tsv.',
    ])
    print(f'{out}: {sum(1 for v in rules.rules.values() if v)} games with rules')


if __name__ == '__main__':
    main()
