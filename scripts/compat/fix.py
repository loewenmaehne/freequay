#!/usr/bin/env python3
"""Freequay: applies the setup directives of the rules to a bottle (freequay fix).

ntdll applies backend, env, dll, args and exe at every start. These directives change the bottle
once:
    verb=<winetricks verb>            installed with winetricks
    reg=<key>|<name>|<type>|<value>   registry value; only <key> creates the key
    winver=<version>                  Windows version for the game's programs
Proton gives every game its own prefix, here all games share the bottle. So the DLL overrides a
winetricks verb sets for the whole prefix move to the programs of the game that asked for it
(HKCU\\Software\\Wine\\AppDefaults\\<program.exe>\\DllOverrides), and so does the Windows version.
Done steps are listed in <bottle>/freequay-fixes.txt, with the overrides each verb set, so a second
game asking for an installed verb gets the same overrides.

Usage: fix.py <bottle dir> <wine binary> <winetricks script> <rule files, colon-separated>
              [--list] [steam:<id>|exe:<name.exe> ...]
Without keys: every Steam game installed in the bottle.
"""

import os
import re
import subprocess
import sys
import tempfile

SKIP_DIRS = re.compile(r'(^|/)(_?commonredist|redist|redistributables|__installer|directx|vcredist|support|'
                       r'installers?)(/|$)', re.I)


def read_rules(files):
    """setup directives per key: verbs and regs in order, the first winver"""
    rules = {}
    for path in files:
        if not os.path.exists(path):
            continue
        with open(path, encoding='utf-8') as f:
            for line in f:
                if line.startswith('#') or '\t' not in line:
                    continue
                key, *dirs = line.rstrip('\n').split('\t')
                r = rules.setdefault(key, {'verb': [], 'reg': [], 'winver': None})
                for d in dirs:
                    name, _, value = d.partition('=')
                    if name in ('verb', 'reg') and value not in r[name]:
                        r[name].append(value)
                    elif name == 'winver' and not r['winver']:
                        r['winver'] = value
    return rules


def vdf_values(path, name):
    with open(path, encoding='utf-8', errors='replace') as f:
        return re.findall(r'"' + name + r'"\s+"([^"]*)"', f.read())


def steam_games(bottle):
    """{appid: (title, game dir)} of the Steam games installed in the bottle"""
    steam = os.path.join(bottle, 'drive_c', 'Program Files (x86)', 'Steam')
    libs = [steam]
    vdf = os.path.join(steam, 'steamapps', 'libraryfolders.vdf')
    if os.path.exists(vdf):
        for p in vdf_values(vdf, 'path'):
            p = p.replace('\\\\', '\\')
            if re.match(r'[A-Za-z]:\\', p):
                unix = os.path.join(bottle, 'dosdevices', p[0].lower() + ':', *p[3:].split('\\'))
                if os.path.isdir(unix) and os.path.realpath(unix) not in map(os.path.realpath, libs):
                    libs.append(unix)
    games = {}
    for lib in libs:
        apps = os.path.join(lib, 'steamapps')
        for fn in os.listdir(apps) if os.path.isdir(apps) else []:
            m = re.fullmatch(r'appmanifest_(\d+)\.acf', fn)
            if not m:
                continue
            path = os.path.join(apps, fn)
            name = (vdf_values(path, 'name') or [''])[0]
            installdir = (vdf_values(path, 'installdir') or [''])[0]
            if installdir:
                games[m.group(1)] = (name, os.path.join(apps, 'common', installdir))
    return games


def game_programs(game_dir):
    out = []
    for root, dirs, files in os.walk(game_dir):
        rel = os.path.relpath(root, game_dir)
        if SKIP_DIRS.search(rel):
            dirs[:] = []
            continue
        out += [f for f in files if f.lower().endswith('.exe')]
    return sorted(set(out), key=str.lower)[:64]


class Bottle:
    def __init__(self, path, wine, winetricks):
        self.path, self.wine, self.winetricks = path, wine, winetricks
        self.wineserver = os.path.join(os.path.dirname(wine), 'wineserver')
        # macOS drops DYLD_* when it starts a system binary (python3 from /usr/bin, sh); the
        # launcher passes the library path for FreeType and GnuTLS as FREEQUAY_LIBRARY_PATH
        self.env = dict(os.environ, WINEPREFIX=path, WINEDEBUG='-all')
        if os.environ.get('FREEQUAY_LIBRARY_PATH'):
            self.env['DYLD_FALLBACK_LIBRARY_PATH'] = os.environ['FREEQUAY_LIBRARY_PATH']
        self.done_file = os.path.join(path, 'freequay-fixes.txt')
        self.done = set()
        self.verb_overrides = {}
        if os.path.exists(self.done_file):
            with open(self.done_file, encoding='utf-8') as f:
                for line in f:
                    parts = line.rstrip('\n').split('\t')
                    if parts[0].startswith('verb:') and len(parts) == 2:
                        self.verb_overrides[parts[0][5:]] = dict(
                            o.split('=', 1) for o in parts[1].split(';') if '=' in o)
                    elif len(parts) == 2:
                        self.done.add((parts[0], parts[1]))

    def record(self, *fields):
        with open(self.done_file, 'a', encoding='utf-8') as f:
            f.write('\t'.join(fields) + '\n')

    def reg(self, *args):
        subprocess.run([self.wine, 'reg'] + list(args), env=self.env, stdout=subprocess.DEVNULL,
                       stderr=subprocess.DEVNULL, check=False)

    def overrides(self):
        """the bottle-wide DLL overrides"""
        with tempfile.TemporaryDirectory() as tmp:
            out = os.path.join(tmp, 'o.reg')
            self.reg('export', 'HKCU\\Software\\Wine\\DllOverrides', 'Z:' + out.replace('/', '\\'), '/y')
            if not os.path.exists(out):
                return {}
            raw = open(out, 'rb').read()
        text = raw.decode('utf-16') if raw[:2] in (b'\xff\xfe', b'\xfe\xff') else raw.decode('utf-8', 'replace')
        return dict(re.findall(r'^"([^"]+)"="([^"]*)"', text, re.M))

    def set_app_overrides(self, programs, overrides):
        for exe in programs:
            for dll, value in overrides.items():
                self.reg('add', f'HKCU\\Software\\Wine\\AppDefaults\\{exe}\\DllOverrides', '/v', dll, '/d', value, '/f')

    def verb(self, verb, programs):
        if verb not in self.verb_overrides:
            before = self.overrides()
            cache = os.path.join(os.path.dirname(self.winetricks), 'winetricks-cache')
            print(f'    winetricks {verb}', flush=True)
            with tempfile.TemporaryDirectory() as tmp:
                # winetricks runs under /bin/sh, which loses DYLD_*; a wrapper sets it again for wine
                wrapper = os.path.join(tmp, 'wine')
                with open(wrapper, 'w') as f:
                    f.write('#!/bin/zsh\nexport DYLD_FALLBACK_LIBRARY_PATH="%s"\nexec "%s" "$@"\n'
                            % (self.env.get('DYLD_FALLBACK_LIBRARY_PATH', ''), self.wine))
                os.chmod(wrapper, 0o755)
                env = dict(self.env, WINE=wrapper, WINESERVER=self.wineserver, W_CACHE=cache,
                           WINETRICKS_LATEST_VERSION_CHECK='disabled')
                r = subprocess.run(['sh', self.winetricks, '-q', verb], env=env, capture_output=True, text=True)
            subprocess.run([self.wineserver, '-w'], env=self.env, check=False)
            if r.returncode:
                print('    failed:\n' + '\n'.join(r.stdout.splitlines()[-5:] + r.stderr.splitlines()[-5:]))
                return False
            after = self.overrides()
            new = {k: v for k, v in after.items() if before.get(k) != v}
            # back to the bottle-wide state before the verb; the game's programs get the new ones
            for dll in new:
                if dll in before:
                    self.reg('add', 'HKCU\\Software\\Wine\\DllOverrides', '/v', dll, '/d', before[dll], '/f')
                else:
                    self.reg('delete', 'HKCU\\Software\\Wine\\DllOverrides', '/v', dll, '/f')
            self.verb_overrides[verb] = new
            self.record('verb:' + verb, ';'.join(f'{k}={v}' for k, v in new.items()))
        self.set_app_overrides(programs, self.verb_overrides[verb])
        return True


def main():
    bottle, wine, winetricks, files = sys.argv[1:5]
    args = sys.argv[5:]
    list_only = '--list' in args
    keys = [a for a in args if a != '--list']
    rules = read_rules(files.split(':'))
    games = steam_games(bottle)
    if not keys:
        keys = ['steam:' + appid for appid in sorted(games, key=int)]
    b = Bottle(bottle, wine, winetricks)
    for key in keys:
        r = rules.get(key)
        if not r or not (r['verb'] or r['reg'] or r['winver']):
            continue
        if key.startswith('steam:'):
            title, game_dir = games.get(key[6:], ('', ''))
            programs = game_programs(game_dir) if game_dir else []
        else:
            title, programs = key[4:], [key[4:].split('\\')[-1]]
        steps = [('verb', v) for v in r['verb']] + [('reg', v) for v in r['reg']] + \
                ([('winver', r['winver'])] if r['winver'] else [])
        todo = [(k, v) for k, v in steps if (key, f'{k}={v}') not in b.done]
        if not todo:
            continue
        print(f'{key} {title}: ' + ', '.join(f'{k}={v}' for k, v in todo))
        if list_only:
            continue
        if not programs and any(k in ('verb', 'winver') for k, _ in todo):
            print('    no programs of the game found, skipped')
            continue
        for kind, value in todo:
            ok = True
            if kind == 'verb':
                ok = b.verb(value, programs)
            elif kind == 'reg':
                parts = value.split('|')
                if len(parts) == 4:
                    b.reg('add', parts[0], '/v', parts[1], '/t', parts[2], '/d', parts[3], '/f')
                else:
                    b.reg('add', parts[0], '/f')
            elif kind == 'winver':
                for exe in programs:
                    b.reg('add', f'HKCU\\Software\\Wine\\AppDefaults\\{exe}', '/v', 'Version', '/d', value, '/f')
            if ok:
                b.record(key, f'{kind}={value}')


if __name__ == '__main__':
    main()
