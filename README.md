# Freequay

Windows games on Apple Silicon Macs, built from the open source part of CodeWeavers' CrossOver 26.3.0, with per-game settings taken from open sources.

A quay is where ships come ashore; here Windows games land on your Mac, for free. Quay is pronounced like "key".

Freequay is not affiliated with, endorsed by or supported by CodeWeavers or Apple. CrossOver is a trademark of CodeWeavers, Inc. CodeWeavers publish the sources this builds on and do most of the work on Wine for the Mac; if you want something that just works, with support, buy CrossOver.

Releases come as a ready-made archive with a small app that starts Windows programs without Terminal (see Install); you can also build it yourself. Apple's D3DMetal is in neither: you download it from Apple yourself if you want it.

## What is in it

- Wine 11.0 with all CodeWeavers patches from `crossover-sources-26.3.0.tar.gz`: msync, the D3DMetal hooks in winemac.drv, Rosetta tweaks and their fixes for single programs (Steam, the Rockstar Games Launcher, Epic, Ubisoft Connect, GTA IV and others). Built as x86_64 for Rosetta 2; 32-bit programs run through WoW64.
- FreeType, GnuTLS, nettle and gmp as x86_64 libraries from the same package. nettle 3.10 comes from the GNU release because the package lacks its `Makefile.in`.
- Graphics backends, chosen per program:
  - `dxmt`: DXMT 0.80 (Feifan He, MIT; versions after 0.80 are LGPL-2.1), Direct3D 10 and 11 on Metal.
  - `dxvk`: DXVK 1.10.3, CodeWeavers' Mac version from the same package (zlib), Direct3D 9 and 11 over Vulkan, with CodeWeavers' MoltenVK (Apache-2.0), which emulates geometry shaders.
  - `wined3d`: Wine's own Direct3D up to version 11; on the Mac CodeWeavers send Direct3D 10 and 11 through Vulkan.
  - `d3dmetal` and `d3dmetal3`: Apple's D3DMetal from the Game Porting Toolkit 4.0 beta 2 and 3.0, Direct3D 11 and 12. Only if you download it from Apple yourself; Apple's license applies.
- Wine Mono from WineHQ for .NET programs; every new bottle gets it. The release archive leaves it out, the first `freequay new` downloads it.
- Rules per program: the open counterpart of CrossOver's closed compatibility database, filled from AppleGamingWiki, umu-protonfixes, Proton, ProtonDB and DXVK (see below).
- `Freequay.app`, one window that starts Windows programs without Terminal, and `scripts/freequay`, the launcher for bottles that it calls.

## What is not in it

Nothing from the CrossOver app itself: not its user interface, no CrossTie installers, no D3DMetal from CrossOver and not CodeWeavers' compatibility database. GStreamer is not built yet, so games that play videos through Media Foundation may show black videos.

## Install

You need an Apple Silicon Mac with Rosetta 2 (`softwareupdate --install-rosetta` installs it) and about 1.5 GB of disk space for Freequay and a first bottle; Steam takes another 1.5 GB, plus your games. No Xcode, no Homebrew, no build. Tested on a MacBook Air M1 with 16 GB and macOS 27.0.1.

Without Terminal: download `freequay-0.2.0-macos.tar.xz` from the [release page](https://github.com/loewenmaehne/freequay/releases/latest), double-click it in Finder to unpack it and open `Freequay.app` in the folder `freequay-0.2.0`. The app is not notarized by Apple, so macOS refuses it the first time: open System Settings, Privacy & Security, click Open Anyway next to the note about Freequay and confirm. After that it opens normally. macOS quarantines everything unpacked from a browser download and would also stop the unsigned `wine`; the app lifts that quarantine for its own folder when it starts.

With Terminal:

```bash
cd ~
curl -LO https://github.com/loewenmaehne/freequay/releases/download/v0.2.0/freequay-0.2.0-macos.tar.xz
tar -xf freequay-0.2.0-macos.tar.xz
cd freequay-0.2.0
scripts/freequay new games
```

The folder can go anywhere: the launcher finds everything relative to itself, and the app finds the launcher next to itself. Bottles live outside it (see Use), so a newer release can simply replace the folder; install D3DMetal again after that.

Downloaded with a browser and not opened the app yet? Then macOS quarantines the archive and everything unpacked from it, by Finder or by `tar`, and Gatekeeper stops the unsigned `wine` with a dialog. Lift the quarantine once, after unpacking:

```bash
xattr -dr com.apple.quarantine ~/freequay-0.2.0
```

The first `freequay new` downloads Wine Mono (82 MB) from WineHQ. `freequay fix`, which installs the runtime packages that rules ask for, needs python3 from the Command Line Tools (`xcode-select --install`), and many of those packages need `cabextract` (Homebrew); without them, Steam and games start without that setup. D3DMetal is installed as described under Build, `scripts/install-d3dmetal.sh` is in the archive too.

## Build

You need Xcode (MoltenVK is built with xcodebuild), Homebrew with `bison pkgconf mingw-w64 autoconf automake libtool m4 ninja glslang cabextract python` and about 4 GB of disk space for sources, build and result. All commands run from the root of the repository.

```bash
scripts/fetch-sources.sh      # CodeWeavers' sources and nettle, unpacked and patched in sources/
scripts/build-deps.sh         # gmp, nettle, GnuTLS, FreeType in deps/
scripts/build-moltenvk.sh     # CodeWeavers' MoltenVK in deps/lib; Wine's configure looks for it
scripts/build-wine.sh         # Wine in dist/wine
scripts/build-dxvk.sh         # DXVK in dist/backends/dxvk
scripts/install-dxmt.sh       # DXMT in dist/backends/dxmt
scripts/install-mono.sh       # Wine Mono for new bottles
scripts/compat/update.sh      # rules from the open sources, optional: compat/ has a recent copy
```

D3DMetal: download "Evaluation environment for Windows games" from developer.apple.com, mount it and run `scripts/install-d3dmetal.sh "/Volumes/<volume>"`; pass `d3dmetal3` as the second argument for version 3.0.

`scripts/build-app.sh` builds `Freequay.app` into the root of the repository with swiftc from Xcode or the Command Line Tools. `scripts/package.sh 0.2.0` builds it as well and packs the build with the launcher, the app, the rules and the license texts into `out/freequay-0.2.0-macos.tar.xz`, the release archive.

## Use

`Freequay.app` shows the programs of a bottle as `freequay programs` lists them: Steam, the Steam games installed in it, every program whose installer put a shortcut into the Start menu or on the desktop, and every `.exe` started from the app except installers (names with setup, install or unins), whose programs show up through their shortcuts anyway. A click starts one; a right click takes it off the list, without deleting or uninstalling anything. An installer or any other `.exe` dropped on the window or the Dock icon, or double-clicked in Finder, starts in the same bottle, through `freequay run`; a click on the strip at the foot of the list picks one instead. If the program lies in Downloads, Documents or on the Desktop, macOS asks whether Freequay may access that folder (in the test twice: when the program was dropped and at its first start from the list); allow it, or Wine cannot read the program. The window also creates bottles, installs Steam and starts it, shows the bottle's files in Finder and stops all programs of the bottle. Everything else, such as the graphics per program, is done with the launcher. The app looks for `scripts/freequay` next to itself, so leave it in the Freequay folder; drag it into the Dock to keep it at hand.

Commands run from the unpacked release folder or the root of the repository.

```bash
scripts/freequay new games
scripts/freequay run games --backend dxmt "/path/to/Game.exe"
scripts/freequay run games "$HOME/Library/Application Support/freequay/Bottles/games/drive_c/Program Files (x86)/Steam/steam.exe"
scripts/freequay programs games
scripts/freequay programs games "/path/to/Game.exe"
scripts/freequay programs games "/path/to/Game.exe" -
scripts/freequay run games steam:440
scripts/freequay app games tf_win64.exe wined3d
scripts/freequay info games steam:440
scripts/freequay info "Grand Theft Auto IV"
scripts/freequay fix games --list
```

Bottles live in `~/Library/Application Support/freequay/Bottles`. `run` starts a Windows program, a shortcut (`.lnk`) or a Steam game by its ID (`steam:440`, which Steam starts with `-applaunch`); `programs` lists what a bottle has, one name and `run` target per line; with a program after the bottle it adds that to the list, and with `-` after the program it takes it off again (an added program is forgotten, a found one hidden). The bottle keeps both in `programs.txt`. `run` takes `--backend`, `--avx` (Rosetta reports AVX to the game), `--hud` (Metal performance HUD) and `--debug`. A program without a rule gets the bottle's default backend (`dxmt`, change it with `freequay set <bottle> backend <name>`) or the one from `--backend`.

`freequay app <bottle> <program.exe|steam:ID> <backend>` sets the graphics for one program, `-` instead of the backend deletes it, and without a program the command lists the bottle's rules. `freequay rule` adds any directive, `freequay info` shows everything that applies to a program. New rules apply at the next program start, also while Steam is running.

Steam for Windows: install it with `SteamSetup.exe /S` and start `steam.exe` with `run`. Before Steam starts, `run` catches up on the one-time setup the rules ask for (`freequay fix`). At its first start Steam downloads about 480 MB of updates and restarts twice before the sign-in window comes up, about 80 seconds in all. In one of three tests the restarted Steam then hung without a window; `freequay kill <bottle>` and a new start helped.

## Patches

- `0001-ntdll-priority-dll-path`: `FREEQUAY_PRIORITY_DLLPATH` puts a backend's DLLs before Wine's builtin d3d11 and dxgi. CrossOver does the same from its closed compatibility database through `prepend_dll_path()`.
- `0002-win32u-zero-fill-monitor-device-name` and `dxvk-0002-dxgi-output-device-name-size`: the display name (`\\.\DISPLAY1`) arrives padded with zeros as on Windows. Before, DXMT, DXVK and D3DMetal passed on garbage behind it, and the FFXIV benchmark launcher cut the game's command line there.
- `0003-kernelbase-chromium-helpers-software-rendering`: `steamwebhelper.exe` and Rockstar's `SocialClubHelper.exe` get `--disable-gpu --disable-gpu-compositing --in-process-gpu`. Their Chromium otherwise draws from a separate GPU process, which winemac.drv does not show: the windows stayed black.
- `0004-registry-hkcu-software-shared-view`: `HKCU\Software` is the same key for 32 and 64 bit, as on Windows 7 and later, even when a `Wow6432Node` exists below it. Steam creates one; Wine then redirected 32-bit access there, `steam_api64.dll` did not find the running Steam, and Team Fortress 2 crashed at start.
- `0005-ntdll-compat-rules-per-program`: rules per program. Every program looks up rules for its path or Steam app ID in the files from `FREEQUAY_COMPAT_FILES` when it starts and gets its graphics backend, environment variables, DLL overrides and launch arguments from them; a broken launcher can be replaced by the game itself. ntdll sets environment variables before a child process starts, because Rosetta reads `ROSETTA_ADVERTISE_AVX` only at exec. That is how Steam runs with wined3d and a game started from it with DXVK. Format and commands: `compat/README.md`.
- `0006-cfgmgr32-reject-unknown-notification-handles`: `CM_Unregister_Notification` rejects unknown handles as Windows does. Steam's `steamclient64.dll` unregisters a stale handle when a game quits; Wine wrote into freed memory and an error dialog came up after Team Fortress 2.
- `dxvk-0003-config-from-environment`: DXVK also reads options from `DXVK_CONFIG` (separated by `;`), as DXVK 2.x does, so rules can set DXVK options per game.
- `moltenvk-0002-spirv-cross-alias-overlapping-samplers`: DXVK declares a depth-compare twin of every Direct3D 9 sampler on the same binding. SPIRV-Cross turned the twin's texture into an alias of the argument buffer slot but forgot its sampler, so every Direct3D 9 pixel shader with a texture failed to compile in MoltenVK and DXVK drew nothing. The sampler now gets the same alias.
- `dxvk-0001` and `moltenvk-0001` keep DXVK and MoltenVK buildable with mingw-w64 14 and Xcode 27.

## Rules from open sources

`compat/` holds the rules tested here (`manual.txt`) and rules from five open sources. `scripts/compat/update.sh` downloads the sources again and regenerates the files; what a source does not give, or what only applies on Linux, goes to `compat/notes.tsv` and shows up in `freequay info`.

| File | Source | License | Taken (2026-10-13) |
|---|---|---|---|
| `applegamingwiki.txt` | AppleGamingWiki, reports on CrossOver on Apple Silicon | CC BY-NC-SA 3.0 | graphics backend for 80 games, where the reports recommend exactly one and none reports problems with it; `ROSETTA_ADVERTISE_AVX` and MoltenVK variables |
| `protonfixes.txt` | umu-protonfixes, fixes per game | BSD-2-Clause | 204 of 313 fixes: winetricks verbs, DLL overrides, variables, registry, launch arguments, replaced launchers |
| `proton.txt` | Valve's Proton, launcher script | BSD-3-Clause | 77 games: heap zeroing, FNA on Direct3D 11, OpenSSL mask, DLL overrides |
| `protondb.txt` | ProtonDB, open export of all reports | ODbL 1.0 | 94 games: launch arguments, DLL overrides and Large Address Aware that at least three reports and a quarter of the working reports since 2023 agree on |
| `dxvk.txt` | DXVK, current game profiles | zlib | 165 of 261 profiles with options DXVK 1.10.3 knows; only with `backend=dxvk` |

Most of these come from Linux, where Proton runs with DXVK and Vulkan drivers; only the AppleGamingWiki rules are about the Mac. CodeWeavers' compatibility pages sit behind bot protection and are not read automatically.

The one-time setup (winetricks verbs, registry values, Windows version) is done by `freequay fix <bottle>` for all installed Steam games. All games share a bottle, so the DLL overrides a winetricks verb sets apply only to the programs of the game that asked for it.

## Tested on 2026-10-13 (MacBook Air M1, macOS 27.0.1)

| Test | Result |
|---|---|
| `cmd /c ver` | Microsoft Windows 10.0.19045, msync active |
| Direct3D 11, 64-bit, `dxmt` | feature level 11_0, adapter "Apple M1", triangle with shaders correct |
| Direct3D 11, 64-bit, `wined3d` over OpenGL | feature level 10_1, image correct |
| Direct3D 11, `wined3d` over Vulkan (CrossOver's default) | image correct with CodeWeavers' MoltenVK; crashed with the official MoltenVK |
| Direct3D 9, `wined3d` | image correct |
| Direct3D 9 with shaders and a texture (`tests/d3d9-shader`), 32- and 64-bit | correct with `wined3d`; with `dxvk` correct since patch moltenvk-0002, before that nothing was drawn |
| Direct3D 9 shadow map: a depth texture sampled with comparison (`tests/d3d9-shadow`), 32- and 64-bit | correct with `wined3d` and `dxvk` |
| Direct3D 9 and 11, `dxvk`, 32- and 64-bit | image correct with CodeWeavers' MoltenVK; the official one lacks geometry shaders |
| Direct3D 11, 32-bit, `dxmt` and `wined3d` | image correct (WoW64) |
| Direct3D 12, offscreen triangle with shaders (`tests/d3d12-draw`) | renders correctly with `d3dmetal`, `d3dmetal3` and with vkd3d over MoltenVK (Wine's own d3d12, any other backend), with vkd3d also as a 32-bit program |
| Direct3D 11, `d3dmetal` (Apple 4.0 beta 2) | image correct; the adapter is called "AMD Compatibility Mode" |
| Direct3D 11, `d3dmetal3` (Apple 3.0) | image correct |
| Display name (`tests/devname`), all backends | padded with zeros with patches 0002 and dxvk-0002; garbage before with DXMT, DXVK and D3DMetal |
| FINAL FANTASY XIV: Dawntrail Benchmark 1.1 (Direct3D 11, launcher in .NET with WPF), `dxmt` | the launcher runs on Wine Mono, the benchmark runs through, image correct. 1920×1080 "High (Desktop)": 2679 points, 19.6 FPS average with window switches (inactive windows slow the game down), 23 to 35 FPS in the foreground. A clean comparison of all backends is still open. |
| Steam for Windows (64-bit client, Chromium 126), `wined3d` | install, self-update and sign-in work; the window shows with patch 0003. With `dxmt` a Steam process aborts at `SwapDeviceContextState`. |
| Team Fortress 2 through Steam (64-bit, Direct3D 9), `wined3d` | starts with patch 0004 and runs smoothly against bots, best in fullscreen; quits cleanly with patch 0006. With `dxvk` the image stayed black before patch moltenvk-0002; not tried again since. The 32-bit `tf.exe` always restarts the 64-bit game on 64-bit Windows. |
| Rockstar Games Launcher 1.0.109 with Social Club 2.4.0.240 (Chromium 143), `wined3d` | installer, self-update, Social Club and sign-in work, then the main window opens. With `dxmt` it aborts at `SwapDeviceContextState`, with `dxvk` at `DXGID3D10CreateDevice`. |

The release archive 0.1.0 was tested on 2026-10-17 like a new user would: a browser download (quarantine set as by Chrome) unpacked into a new folder with a space in its path, the quarantine lifted with `xattr`, a new bottle under an empty home directory, and the build tree hidden so that nothing could load from there. All 29 graphics tests passed (Direct3D 9, 11 and 12, 32 and 64 bit, `dxmt`, `dxvk`, `wined3d`, vkd3d, and `d3dmetal` and `d3dmetal3` installed with the archive's `scripts/install-d3dmetal.sh`). Steam installed, updated itself and showed its sign-in window.

`Freequay.app` was tested on 2026-10-17 with a 0.2.0 archive unpacked the same way: quarantined as by Chrome, in a folder with a space in its path, with an empty home directory. At its start the app lifted the quarantine of its folder (1931 files). Creating a bottle took 34 seconds, the Wine Mono download included. Notepad and regedit, opened as from Finder or the Dock or dropped on the window, came up as Mac windows within 2 to 4 seconds. The Steam button's code downloaded and installed Steam in 4 seconds, Steam's sign-in window came about 80 seconds later, and from then on the list showed Steam and opened it. "Stop all programs" ended everything; programs keep running when the app quits. The list took in an `.exe` started from the app and still had it after the app restarted, left out installers named Setup.exe, GameInstaller.exe and unins000.exe, and removing an entry forgot an added program and kept a found one hidden after restarts. Not tested: Open Anyway for an app really downloaded with a browser, and App Translocation, which only macOS itself can set up.

`tests/` has the small programs behind these tests; build them with mingw-w64 as their first comment says. `tests/rulecheck` shows what the rules changed for a program: its path, command line, environment variables and where `d3d11.dll` comes from.

## Compared with CrossOver 26.3

| Part | CrossOver | Freequay |
|---|---|---|
| Wine with CodeWeavers' patches | yes | yes, the same source |
| D3DMetal (Apple) | included | from Apple's download |
| DXMT | yes | yes (release 0.80) |
| DXVK with CodeWeavers' MoltenVK | yes | built from the same package |
| wined3d | yes | yes |
| msync, 32-bit through WoW64 | yes | yes |
| .NET through Wine Mono | yes | yes, from WineHQ |
| Settings per game | closed compatibility database | open rules (patch 0005, `compat/`) from AppleGamingWiki, protonfixes, Proton, ProtonDB and DXVK |
| One-click installers (CrossTie) | yes | no; `freequay fix` installs the runtime packages the rules ask for with winetricks |
| User interface | yes | one window that starts programs (`Freequay.app`) and the command `freequay` |
| GStreamer (videos in games) | yes | not built yet |

## Folders

`downloads/` source packages, `sources/` unpacked and patched sources, `build/` build trees, `deps/` x86_64 libraries, `dist/` the finished build with its backends, `out/` release archives, `tools/` meson, `logs/` logs, `Freequay.app` the app built from `app/`. Only `app/`, `scripts/`, `patches/`, `compat/`, `tests/`, `licenses/` and the documents are versioned.

## License

- Scripts, tests and documents of this repository: MIT, see `LICENSE`.
- `patches/0*.patch` change Wine and are under Wine's license, LGPL-2.1-or-later. `patches/dxvk-*.patch` are under DXVK's zlib license, `patches/moltenvk-*.patch` under MoltenVK's Apache-2.0.
- The generated files in `compat/` keep the license of their source, named in each file's header: `applegamingwiki.txt` CC BY-NC-SA 3.0 (non-commercial), `protondb.txt` ODbL 1.0, `protonfixes.txt` BSD-2-Clause, `proton.txt` BSD-3-Clause, `dxvk.txt` zlib. Each row of `notes.tsv` names its source and keeps that source's license.
- Builds contain Wine, DXVK, MoltenVK, DXMT and other components under their own licenses. If you pass a build on, those licenses apply, including the LGPL's source requirements. D3DMetal is Apple's and under Apple's license.
- The release archive has the license texts of all its parts in `licenses/`; `licenses/README.md` lists them and where their source code is.
