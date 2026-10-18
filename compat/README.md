# Rules per program

The open counterpart of CrossOver's closed compatibility database: text files with settings per game or program. ntdll reads them whenever a program starts (`patches/0005-ntdll-compat-rules-per-program.patch`), before the main executable or any DLL is loaded. Changes therefore apply at the next program start; Steam does not need a restart.

## Order

`freequay` passes the files in this order; for every setting the first file that has it wins:

1. `compat.txt` in the bottle: your own rules (`freequay app`, `freequay rule`)
2. `manual.txt`: tested in Freequay
3. `applegamingwiki.txt` in `~/Library/Application Support/freequay/compat`: reports from Mac players on CrossOver
4. `protonfixes.txt`, `proton.txt`, `protondb.txt`: fixes and reports from the Linux world
5. `dxvk.txt`: DXVK options per game

`scripts/compat/update.sh` generates files 4 and 5; do not edit them by hand, your own rules belong in the bottle or in `manual.txt`. `notes.tsv` (notes, also on what was left out) and `titles.tsv` (Steam app ID and title) are only read by `freequay info`.

AppleGamingWiki's content is under CC BY-NC-SA 3.0, which allows no commercial use, so Freequay does not ship rules taken from it. `scripts/compat/applegamingwiki` (built from `applegamingwiki.swift` by `scripts/build-app.sh`) looks up the installed Steam games one by one, each at most once a week, and makes file 3 on your Mac, with a `notes.tsv` and `titles.tsv` of its own next to it; `applegamingwiki/` beside them keeps the pages and the date of each lookup. `freequay run <bottle> steam:<ID>` looks up the game before it starts, `freequay run` and `freequay programs` look up the other installed games in the background, and while Steam runs a watcher looks up the games it installs. `freequay applegamingwiki` does it at once. Without network nothing changes: the game starts without these rules, and the next start tries again.

## Format

One rule per line, fields separated by tabs, `#` at the start of a line is a comment:

```
<key>	<directive>	<directive> ...
```

Keys:

| Key | matches |
|---|---|
| `steam:<appid>` | the game Steam starts (`SteamAppId` or `SteamGameId` in its environment) and every program it starts |
| `exe:<name.exe>` | every program with this file name, case-insensitive |
| `exe:\folder\name.exe` | every program whose path ends like this |

Directives at program start:

| Directive | Effect |
|---|---|
| `backend=<name>` | graphics: `d3dmetal`, `d3dmetal3`, `dxmt`, `dxvk` or `wined3d` |
| `env=<NAME>=<value>` | set an environment variable; without a value, delete it |
| `dll=<name>=<order>` | DLL override as in `WINEDLLOVERRIDES`: `n`, `b`, `n,b`, `b,n`, empty for off |
| `args=<text>` | append to the command line |
| `argdel=<text>` | remove from the command line |
| `exe=<from>><to>` | instead of the program whose path ends in `<from>`, start `<to>` (relative to it, `..` allowed), for instance to skip a broken launcher |

A program without a `backend` rule, or with one for a backend that is not installed, gets the bottle's default (`dxmt`, or the one from `freequay run --backend`). `dxmt` and `dxvk` have no Direct3D 12, so a program that imports `d3d12.dll`, directly or delay-loaded, gets `d3dmetal` (or `d3dmetal3`) instead when D3DMetal is installed and the program is 64-bit, and `wined3d` otherwise, where Wine's d3d12 runs on vkd3d. Without D3DMetal, a program that imports `d3d11.dll` as well keeps `dxmt` or `dxvk`: Unreal Engine games import both, and most of them run on Direct3D 11.

`args`, `argdel` and `exe` from a `steam:` key only apply to the first program of the game below `steamapps\common`: not to installers of runtime libraries, crash reporters or programs the game starts itself. ntdll sets `FREEQUAY_STEAM_LAUNCH` after that.

`exe=` only replaces the program when both are built the same way (32 or 64 bit).

ntdll also sets environment variables before a child process starts, so variables that are read before Wine runs work too: `env=ROSETTA_ADVERTISE_AVX=1` makes Rosetta report AVX.

Directives for the one-time setup (`freequay fix`, once per bottle):

| Directive | Effect |
|---|---|
| `verb=<name>` | install a winetricks verb (runtime libraries, fonts ...); the DLL overrides it sets apply only to the programs of the game |
| `reg=<key>\|<name>\|<type>\|<value>` | set a registry value; `<key>` alone creates the key |
| `winver=<version>` | Windows version for the programs of the game (`win7`, `win10`, `winxp` ...) |

Done steps are listed in `freequay-fixes.txt` in the bottle.

## Commands

```bash
scripts/freequay app games tf_win64.exe wined3d
scripts/freequay rule games steam:12210 'args=-norestrictions' env=WINE_LARGE_ADDRESS_AWARE=1
scripts/freequay rule games steam:12210 -
scripts/freequay info games steam:440
scripts/freequay info "Grand Theft Auto IV"
scripts/freequay fix games --list
```

`WINEDEBUG=+freequay` shows which rules a program got and which backend a Direct3D 12 program gets.
