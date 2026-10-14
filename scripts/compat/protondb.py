#!/usr/bin/env python3
"""Freequay: turns the ProtonDB reports into compat/protondb.txt.

ProtonDB (protondb.com) publishes all player reports as an open data export under the ODbL
(github.com/bdefore/protondb-data). Each report says whether a game runs under Proton on Linux
and often which launch options the player used. A switch becomes a rule when working reports
since 2023 agree on it: at least 3 of them and a quarter of all working reports for the game
for the switches below, at least 5 and 40 % for other game arguments. Kept are only switches
that also matter on macOS: game arguments (Direct3D 11 renderer, skipping launchers and intros,
game specific ones), DLL overrides outside the graphics stack and Large Address Aware. Linux
players picking wined3d or turning off Direct3D 11 react to DXVK on Linux; that and a summary
per game go to compat/notes.tsv, titles to compat/titles.tsv.

Usage: protondb.py <reports_*.tar.gz> [<version note>]
"""

import collections
import json
import os
import re
import sys
import tarfile

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from common import Rules  # noqa: E402

SINCE = 1672531200  # 2023-01-01
KNOWN_ARGS = re.compile(
    r'^-{1,2}(dx11|d3d11|use-d3d11|force-d3d11|directx11|dx9|d3d9|force-d3d9|'
    r'skip-?launcher|launcher-skip|skip_launcher|no-?launcher|nolauncher|'
    r'skip-?intro|intro-skip|nointro|no-intro|nosplash|no-splash|novid|nostartupmovies|skip-?startscreen|'
    r'nomovies|no-movies|nologos?|no-logos?|useallavailablecores)$|^\+com_skip\w+', re.I)
DENY_ARGS = re.compile(
    r'^-{1,2}(vulkan|force-vulkan|dx12|d3d12|force-d3d12|dx-12|opengl|force-opengl|force-glcore\w*|gl|'
    r'windowed|window|fullscreen|full|borderless|noborder|popupwindow|w|h|width|height|screen-\w+|refresh|freq|'
    r'monitor|adapter|high|threads|preload|maxfps|fps\w*|console|dev|log\w*|debug|condebug|sdlaudiodriver|'
    r'use-angle|force-grab-cursor|enable-avpro-in-proton|disable-gpu\w*|in-process-gpu|nosteamcontroller|'
    r'novsync|vsync|lang\w*|language|nojoy|nohltv|vrmode|dxlevel|safe\w*|autoconfig|'
    r'game|mod|modpath|provider|offline|applaunch|login|password|user\w*|steam)$|^\+(fps_max|exec|set|cl_\w+|mat_\w+)', re.I)
GRAPHICS_DLLS = re.compile(r'^(d3d\w*|dxgi|dxvk\w*|nvapi\w*|nvngx\w*|vulkan-1|opengl32|atiadl\w*|amd_ags\w*|dxcore)$', re.I)
QUOTES = '"\'\u201c\u201d\u201e\u2018\u2019\u00ab\u00bb'
SHELL_STOP = re.compile(r'^(\||;|&&|\|\||&|#)$')
WRAPPERS = {'gamemoderun', 'mangohud', 'gamescope', 'prime-run', 'obs-gamecapture', 'strangle', 'env', 'taskset',
            'nice', 'sh', 'bash', 'eval', 'exec', 'proton'}


def reports(path):
    """stream the objects of the JSON array in the export without loading it at once"""
    dec = json.JSONDecoder()
    with tarfile.open(path) as tar:
        member = next(m for m in tar if m.name.endswith('.json'))
        f = tar.extractfile(member)
        buf, started = '', False
        while True:
            chunk = f.read(1 << 20)
            if chunk:
                buf += chunk.decode('utf-8')
            i, n = 0, len(buf)
            while True:
                while i < n and buf[i] in ' \t\r\n,':
                    i += 1
                if not started and i < n and buf[i] == '[':
                    started, i = True, i + 1
                    continue
                if i >= n or buf[i] == ']':
                    break
                try:
                    obj, end = dec.raw_decode(buf, i)
                except json.JSONDecodeError:
                    break
                yield obj
                i = end
            buf = buf[i:]
            if not chunk:
                return


def parse_options(text):
    """(environment dict, argument units) of a Steam launch options string"""
    env, args = {}, []
    low = text.lower()
    if '%command%' in low:
        idx = low.index('%command%')
        pre, post = text[:idx], text[idx + 9:]
    else:
        pre, post = '', text
    for name, value in re.findall(r'(?:^|\s)([A-Za-z_][A-Za-z0-9_]*)=("[^"]*"|\'[^\']*\'|\S*)', pre + ' ' + post):
        env[name] = value.strip(QUOTES)
    tokens = [t for t in re.split(r'\s+', post.strip()) if t]
    i = 0
    while i < len(tokens):
        t = tokens[i]
        if SHELL_STOP.match(t) or t.lower() in WRAPPERS:
            break
        if re.fullmatch(r'[A-Za-z_][A-Za-z0-9_]*=\S*', t):
            i += 1
            continue
        if re.fullmatch(r'[-+/][A-Za-z][\w:.-]*', t):
            unit = t
            if i + 1 < len(tokens) and re.fullmatch(r'[\w.:]+', tokens[i + 1]) and not tokens[i + 1].startswith(('-', '+')):
                unit += ' ' + tokens[i + 1]
                i += 1
            args.append(unit)
        i += 1
    return env, args


def main():
    path = sys.argv[1]
    note = sys.argv[2] if len(sys.argv) > 2 else os.path.basename(path)
    works = collections.Counter()
    total = collections.Counter()
    counts = collections.defaultdict(collections.Counter)
    titles = {}
    for r in reports(path):
        app = r.get('app', {})
        appid = str(app.get('steam', {}).get('appId', ''))
        resp = r.get('responses', {})
        if not appid.isdigit() or r.get('timestamp', 0) < SINCE or resp.get('variant') == 'native':
            continue
        if app.get('title'):
            titles[appid] = app['title']
        total[appid] += 1
        if resp.get('verdict') != 'yes':
            continue
        works[appid] += 1
        seen = set()
        flags = resp.get('launchFlagsUsed') or {}
        if isinstance(flags, dict):
            for flag, used in flags.items():
                if used:
                    seen.add('flag:' + flag)
        opts = resp.get('launchOptions')
        if isinstance(opts, str) and opts.strip():
            env, args = parse_options(opts)
            for name, value in env.items():
                if name == 'WINEDLLOVERRIDES':
                    for part in value.split(';'):
                        if '=' in part:
                            dlls, order = part.split('=', 1)
                            order = order.strip(QUOTES + ' ').lower()
                            if not re.fullmatch(r'[nbd]?(,[nbd])?', order):
                                continue
                            for dll in dlls.split(','):
                                dll = re.sub(r'\.dll$', '', dll.strip(QUOTES + ' ').lower())
                                if re.fullmatch(r'[\w.-]+', dll) and not GRAPHICS_DLLS.match(dll):
                                    seen.add(f'dll:{dll}={"" if order == "d" else order}')
                else:
                    seen.add(f'env:{name}={value}')
            for unit in args:
                seen.add('arg:' + unit)
        for item in seen:
            counts[appid][item] += 1

    rules = Rules()
    stats = collections.Counter()
    for appid, n_works in works.items():
        key = 'steam:' + appid
        c = counts[appid]

        def agreed(item, minimum=3, share=0.25):
            return c[item] >= minimum and c[item] >= share * n_works

        args = []
        for item in sorted(c, key=lambda i: -c[i]):
            kind, _, value = item.partition(':')
            if kind == 'arg':
                flag = value.split()[0]
                if DENY_ARGS.match(flag):
                    continue
                if (KNOWN_ARGS.match(flag) and agreed(item)) or agreed(item, 5, 0.4):
                    if flag.lower() not in [a.split()[0].lower() for a in args]:
                        args.append(value)
            elif kind == 'dll' and agreed(item):
                # the most used order for this DLL; items come sorted by count
                if not any(d.split('=')[1] == value.split('=')[0] for d in rules.rules.get(key, []) if d.startswith('dll=')):
                    rules.add(key, 'dll=' + value)
                    stats['dll'] += 1
        if args:
            rules.add(key, 'args=' + ' '.join(args))
            stats['args'] += 1
        if agreed('flag:largeAddressAware') or agreed('env:PROTON_FORCE_LARGE_ADDRESS_AWARE=1'):
            rules.add(key, 'env=WINE_LARGE_ADDRESS_AWARE=1')
            stats['laa'] += 1
        wined3d = max(c['flag:useWineD3d11'], c['env:PROTON_USE_WINED3D=1'], c['env:PROTON_USE_WINED3D11=1'])
        if wined3d >= 3 and wined3d >= 0.25 * n_works:
            rules.note(key, f'ProtonDB: {wined3d} of {n_works} working reports use wined3d instead of DXVK')
        nod3d11 = max(c['flag:disableD3d11'], c['env:PROTON_NO_D3D11=1'])
        if nod3d11 >= 3 and nod3d11 >= 0.25 * n_works:
            rules.note(key, f'ProtonDB: {nod3d11} of {n_works} working reports turn off Direct3D 11')
        if total[appid] >= 5:
            rules.note(key, f'ProtonDB since 2023: {total[appid]} reports, {round(100 * n_works / total[appid])} % working')
    for appid, title in titles.items():
        rules.title(appid, title)
    out = rules.write('protondb', [
        'Freequay: rules from the reports on ProtonDB (protondb.com), open data export',
        f'github.com/bdefore/protondb-data, as of {note}, license ODbL 1.0 (database) and DbCL 1.0 (contents);',
        'this file and the protondb rows of notes.tsv are under the ODbL 1.0.',
        'Only switches that working reports since 2023 agree on; selection in scripts/compat/protondb.py.',
    ])
    print(f'{out}: {sum(1 for v in rules.rules.values() if v)} games with rules ({stats["args"]} launch options, '
          f'{stats["dll"]} DLL overrides, {stats["laa"]} Large Address Aware) from {len(works)} games with reports')


if __name__ == '__main__':
    main()
