#!/usr/bin/env python3
"""Freequay: turns the game fixes of umu-protonfixes into compat/protonfixes.txt.

protonfixes runs one Python file per game before Proton starts it. This reads those files without
running them and keeps what also works on macOS: winetricks verbs, Windows version, DLL overrides,
environment variables the game reads, registry values, extra or removed arguments and launcher
replacements. Linux-only steps (esync/fsync, Mesa/NVIDIA/PulseAudio variables, gamescope, CPU
topology) and steps behind conditions are left out and listed in compat/notes.tsv.

Usage: protonfixes.py <umu-protonfixes checkout> <winetricks script>
"""

import ast
import os
import re
import subprocess
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from common import Rules, WINVER, clean  # noqa: E402

ORDER = {'DISABLED': '', 'NATIVE': 'n', 'BUILTIN': 'b', 'NATIVE_BUILTIN': 'n,b', 'BUILTIN_NATIVE': 'b,n'}

# variables only Proton, Linux drivers, gamescope or the Steam Deck read
SKIP_ENV = re.compile(r'^(PROTON_|UMU_|WINE_DISABLE_|WINE_NO_|WINE_BLOCK_|WINEESYNC|WINEFSYNC|WINENTSYNC|'
                      r'__GL_|MESA_|AMD_|RADV_|radeonsi|vk_|ENABLE_GAMESCOPE|GAMESCOPE|PULSE_|SDL_VIDEODRIVER|'
                      r'LC_|LANG|taskset|SteamDeck|SteamAppId|SteamGameId|DXVK_ENABLE_NVAPI|DXVK_NVAPI|VKD3D_)')

# Proton switches with a counterpart here
PROTON_ENV = {
    ('PROTON_USE_WINED3D', '1'): ['backend=wined3d'],
    ('PROTON_USE_WINED3D11', '1'): ['backend=wined3d'],
    ('PROTON_NO_D3D11', '1'): ['dll=d3d11='],
    ('PROTON_NO_D3D10', '1'): ['dll=d3d10=', 'dll=d3d10_1=', 'dll=d3d10core='],
    ('PROTON_FORCE_LARGE_ADDRESS_AWARE', '1'): ['env=WINE_LARGE_ADDRESS_AWARE=1'],
}

# winetricks settings that wined3d also takes from WINE_D3D_CONFIG, per program
D3D_SETTINGS = {'renderer': 'renderer', 'csmt': 'csmt', 'videomemorysize': 'VideoMemorySize',
                'orm': 'OffscreenRenderingMode', 'strictdrawordering': 'StrictDrawOrdering'}

LINUX_ONLY = {
    'disable_esync': 'disable esync (on macOS msync applies to the whole bottle)',
    'disable_fsync': 'disable fsync (Linux only)',
    'disable_ntsync': 'disable ntsync (Linux only)',
    'disable_nvapi': 'disable NVAPI (no NVIDIA GPU)',
    'set_cpu_topology_limit': "limit CPU cores (WINE_CPU_TOPOLOGY is missing in CrossOver's Wine)",
    'set_cpu_topology_nosmt': "limit CPU cores (WINE_CPU_TOPOLOGY is missing in CrossOver's Wine)",
    'set_cpu_topology': "limit CPU cores (WINE_CPU_TOPOLOGY is missing in CrossOver's Wine)",
    'patch_libcuda': 'patch libcuda (NVIDIA)',
    'set_game_drive': "Proton's game drive",
    'create_dos_device': 'extra drive',
    'install_eac_runtime': 'Easy Anti-Cheat for Proton',
    'install_battleye_runtime': 'BattlEye for Proton',
    'set_ini_options': "entry in a game's config file",
    'set_xml_options': "entry in a game's config file",
    'import_saves_folder': 'saves from another Proton prefix',
    'create_dosbox_conf': 'DOSBox settings',
}
QUERIES = {'checkinstalled', 'get_game_install_path', 'protonprefix', 'protondir', 'protonmain', 'get_resolution',
           'get_steam_account_id', 'which', 'is_custom_verb', 'get_game_exe_name', 'is_smt_enabled', 'get_cpu_count'}


def winetricks_verbs(path):
    out = set()
    with open(path, encoding='utf-8', errors='replace') as f:
        for line in f:
            m = re.match(r'w_metadata\s+(\S+)\s+(\S+)', line)
            if m:
                out.add(m.group(1))
    return out


def regex_literal(text):
    """a replace_command pattern as plain text, or None if it is a real regex"""
    text = text.rstrip('$')
    text = text.replace('\\.', '.').replace('\\\\', '\\')
    if re.search(r'[\\^$*+?()\[\]{}|]', text):
        return None
    return text


class Fix:
    def __init__(self, key, rules, verbs, consts):
        self.key, self.rules, self.verbs, self.consts = key, rules, verbs, dict(consts)
        self.args, self.dxvk = [], []

    def value(self, node):
        if isinstance(node, ast.Constant):
            return node.value
        if isinstance(node, ast.Name) and node.id in self.consts:
            return self.consts[node.id]
        if isinstance(node, ast.Attribute) and isinstance(node.value, ast.Attribute) and node.value.attr == 'OverrideOrder':
            return ORDER.get(node.attr)
        if isinstance(node, ast.Attribute) and isinstance(node.value, ast.Name) and node.value.id == 'OverrideOrder':
            return ORDER.get(node.attr)
        if isinstance(node, ast.JoinedStr) or isinstance(node, ast.BinOp):
            return None
        return None

    def skip(self, what):
        self.rules.note(self.key, 'not taken: ' + what)

    def env(self, name, value):
        if (name, value) in PROTON_ENV:
            for d in PROTON_ENV[(name, value)]:
                self.rules.add(self.key, d)
        elif name == 'WINEDLLOVERRIDES':
            for part in value.split(';'):
                if '=' in part:
                    dlls, order = part.split('=', 1)
                    for dll in dlls.split(','):
                        if dll.strip():
                            self.rules.add(self.key, f'dll={dll.strip()}={order.strip()}')
        elif SKIP_ENV.match(name):
            self.skip(f'variable {name}={value} (Proton or Linux)')
        else:
            self.rules.add(self.key, f'env={name}={clean(value)}')

    def call(self, node):
        func = node.func
        if not (isinstance(func, ast.Attribute) and isinstance(func.value, ast.Name) and func.value.id == 'util'):
            return
        name, args = func.attr, [self.value(a) for a in node.args]
        kw = {k.arg: self.value(k.value) for k in node.keywords}
        if any(a is None for a in args) and name not in QUERIES and name not in LINUX_ONLY:
            self.skip(f'{name}({ast.unparse(node)[len("util." + name) + 1:-1]}) with computed values')
            return
        if name == 'protontricks':
            self.verb(args[0])
        elif name == 'winedll_override':
            self.rules.add(self.key, f'dll={args[0]}={args[1]}')
        elif name == 'wineexe_override':
            self.rules.add(self.key, f'dll={args[0]}.exe={args[1]}')
        elif name == 'set_environment':
            self.env(args[0], str(args[1]))
        elif name == 'del_environment':
            if SKIP_ENV.match(args[0]):
                self.skip(f'delete variable {args[0]}')
            else:
                self.rules.add(self.key, f'env={args[0]}=')
        elif name == 'regedit_add':
            folder = args[0]
            rest = args[1:4] if len(args) >= 4 else [kw.get('name'), kw.get('typ'), kw.get('value')]
            if 'winebus' in folder.lower():
                self.skip('winebus setting (Linux controllers)')
            elif all(r is not None for r in rest):
                self.rules.add(self.key, 'reg=' + '|'.join([folder] + [clean(r) for r in rest]))
            else:
                self.rules.add(self.key, 'reg=' + folder)
        elif name == 'append_argument':
            self.args.append(clean(args[0]))
        elif name == 'replace_command':
            orig, repl = regex_literal(args[0]), args[1]
            if orig and orig.lower().endswith('.exe') and repl.lower().endswith('.exe'):
                self.rules.add(self.key, f'exe={orig}>{repl.lstrip("./") if repl.startswith("./") else repl}')
            elif orig and repl == '' and orig[:1] in '-+/':
                self.rules.add(self.key, f'argdel={orig}')
            else:
                self.skip(f'replacement {args[0]!r} -> {args[1]!r}')
        elif name == 'set_dxvk_option':
            self.dxvk.append(f'{args[0]} = {args[1]}')
        elif name in LINUX_ONLY:
            self.skip(LINUX_ONLY[name])
        elif name in QUERIES:
            pass
        else:
            self.skip(name)

    def verb(self, verb):
        if verb in WINVER:
            self.rules.add(self.key, f'winver={verb}')
        elif '=' in verb:
            setting, value = verb.split('=', 1)
            if setting in D3D_SETTINGS:
                self.rules.add(self.key, f'env=WINE_D3D_CONFIG={D3D_SETTINGS[setting]}={value}')
            else:
                self.skip(f'winetricks setting {verb}')
        elif verb in self.verbs:
            self.rules.add(self.key, f'verb={verb}')
        else:
            self.skip(f'protonfixes verb of its own: {verb}')

    def body(self, stmts):
        for st in stmts:
            if isinstance(st, ast.Expr) and isinstance(st.value, ast.Call):
                self.call(st.value)
            elif isinstance(st, ast.If):
                test = st.test
                inner = test.operand if isinstance(test, ast.UnaryOp) and isinstance(test.op, ast.Not) else test
                if isinstance(inner, ast.Call) and isinstance(inner.func, ast.Attribute) and \
                        inner.func.attr in ('checkinstalled', 'protontricks'):
                    if inner.func.attr == 'protontricks':
                        self.call(inner)
                    self.body(st.body)
                else:
                    self.skip('steps under the condition ' + clean(ast.unparse(st.test))[:80])
            elif isinstance(st, (ast.Try,)):
                self.body(st.body)
            elif isinstance(st, ast.Assign) and len(st.targets) == 1 and isinstance(st.targets[0], ast.Name) \
                    and isinstance(st.value, ast.Constant):
                self.consts[st.targets[0].id] = st.value.value
            elif isinstance(st, (ast.For, ast.While, ast.With)):
                self.skip('loops and file changes')
            elif isinstance(st, ast.Expr) and isinstance(st.value, ast.Constant):
                pass  # docstring
            elif isinstance(st, (ast.Assign, ast.AnnAssign, ast.AugAssign, ast.Return)):
                pass
            else:
                self.skip('steps without a counterpart (' + type(st).__name__ + ')')

    def finish(self):
        if self.args:
            self.rules.add(self.key, 'args=' + ' '.join(self.args))
        if self.dxvk:
            self.rules.add(self.key, 'env=DXVK_CONFIG=' + '; '.join(self.dxvk))


def main():
    src, winetricks = sys.argv[1], sys.argv[2]
    verbs = winetricks_verbs(winetricks)
    rules = Rules()
    stats = {'files': 0, 'rules': 0}
    store = os.path.join(src, 'gamefixes-steam')
    for fn in sorted(os.listdir(store)):
        if not re.fullmatch(r'\d+\.py', fn):
            continue
        appid = fn[:-3]
        key = 'steam:' + appid
        path = os.path.realpath(os.path.join(store, fn))
        tree = ast.parse(open(path, encoding='utf-8').read())
        stats['files'] += 1
        doc = ast.get_docstring(tree) or ''
        m = re.match(r'(?:Game fix(?:es)? for|Fix for)\s+(.+?)(?:[:.]\s|$)', doc.splitlines()[0] if doc else '')
        if m:
            rules.title(appid, m.group(1).strip().rstrip('.'))
        consts = {t.id: n.value.value for n in tree.body if isinstance(n, ast.Assign) and isinstance(n.value, ast.Constant)
                  for t in n.targets if isinstance(t, ast.Name)}
        main_fn = next((n for n in tree.body if isinstance(n, ast.FunctionDef) and n.name == 'main'), None)
        if not main_fn:
            continue
        fix = Fix(key, rules, verbs, consts)
        fix.body(main_fn.body)
        fix.finish()
        mdoc = ast.get_docstring(main_fn)
        if mdoc and key in rules.rules:
            rules.note(key, 'protonfixes: ' + mdoc.splitlines()[0])
    commit = subprocess.run(['git', '-C', src, 'log', '-1', '--format=%h %cs'], capture_output=True, text=True).stdout.strip()
    path = rules.write('protonfixes', [
        'Freequay: rules from umu-protonfixes (github.com/Open-Wine-Components/umu-protonfixes),',
        f'as of {commit}, license BSD-2-Clause (Copyright 2018 Chris Simons and contributors).',
        'Generated by scripts/compat/protonfixes.py, do not edit by hand; what was left out is in notes.tsv.',
    ])
    stats['rules'] = sum(1 for k in rules.rules if rules.rules[k])
    print(f'{path}: {stats["rules"]} games with rules from {stats["files"]} fixes')


if __name__ == '__main__':
    main()
