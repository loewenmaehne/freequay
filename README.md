# Freequay

Freequay runs Windows games and programs on Apple Silicon Macs, for free: Wine built from the open source part of CodeWeavers' CrossOver 26.3.0, with a small app and settings per game from open sources. It is not affiliated with CodeWeavers or Apple.

<img src="app/screenshot.png" width="660" alt="Freequay.app with the bottle games: Steam and Notepad in the list, below it a strip to drop installers on">

## Download

You need an Apple Silicon Mac with macOS 14 or newer, Rosetta 2 and about 1.5 GB of free disk space; Steam takes another 1.5 GB, plus your games. Neither Xcode, its Command Line Tools nor Homebrew are needed. Most Macs got Rosetta 2 with the first Intel app they opened; otherwise run `softwareupdate --install-rosetta` once in Terminal.

1. Download `Freequay-0.3.1.dmg` from the [latest release](https://github.com/loewenmaehne/freequay/releases/latest) and open it.
2. Drag Freequay into Applications and open it there. The first time, macOS refuses it because the app is not notarized by Apple: open System Settings, Privacy & Security, click Open Anyway next to the note about Freequay and confirm. After that it opens normally.
3. The app lists once which servers Freequay downloads from. Then click Create a bottle, a Windows drive of its own (about a minute, with the download of Wine Mono), and install Steam with its button, or drop the installer of a Windows program on the window.

A bottle is not a sandbox. Wine shows your whole Mac to Windows programs as drive Z:, so they can read and change all your files, just as a Mac program can. Only start Windows programs you trust.

Freequay itself collects no data. It downloads from AppleGamingWiki (settings for your Steam games), WineHQ (Wine Mono for a new bottle), Valve (Steam, when you install it), GitHub (winetricks), Microsoft and others through winetricks (runtime packages games ask for) and, only if you add it yourself, Apple (D3DMetal).

Everything Freequay needs is inside the app. What it downloads later, your bottles and D3DMetal live in `~/Library/Application Support/freequay`, so a newer Freequay replaces the app and keeps them.

## What runs

Tested on a MacBook Air M1 with 16 GB and macOS 27.0.1, not yet on an older macOS. Few games have been tried so far; reports are welcome as issues.

| Program | Result |
|---|---|
| Steam for Windows | installs, updates itself and signs in. The first start downloads about 575 MB in two updates; after each update Steam closes to start again, and in two of three test bottles on 2026-10-18 it did not come back. Stop all programs and a new start helped, and the sign-in window then came after about 20 seconds. |
| Team Fortress 2 through Steam (Direct3D 9) | runs smoothly against bots, best in fullscreen |
| FINAL FANTASY XIV: Dawntrail Benchmark (Direct3D 11, .NET launcher) | runs through: 2679 points at 1920×1080 "High (Desktop)", 23 to 35 FPS in the foreground |
| Rockstar Games Launcher with Social Club | installs, updates itself, signs in and opens its main window |
| Black Myth: Wukong Benchmark Tool (Direct3D 12, D3DMetal) | hangs while loading, then Unreal's crash reporter comes up |

Games that play videos through Media Foundation may show them black, because GStreamer is not built yet. Apple's D3DMetal (Direct3D 11 and 12) is not included; the app leads you to Apple's own download and installs it from there. Without it, Direct3D 12 runs on Wine's own d3d12 with vkd3d, tried so far only with small test programs.

## Using the app

- The list shows the programs of the chosen bottle: Steam, its games, every program whose installer put a shortcut into the Start menu or on the desktop, and every `.exe` started from the app except installers (setup, install or unins in the name).
- Open starts a program. Programs start one at a time: the row shows a spinner until the program's window appears, and Open on a program whose window is still open brings it forward.
- An installer or any other `.exe` dropped on the window or the Dock icon, or double-clicked in Finder, starts in the chosen bottle. A click on the strip at the foot of the list picks one instead.
- Every bottle has your whole Mac as drive Z:, so a Windows program can read and change all your files. Open only programs you trust.
- A right click takes a program off the list. Nothing is deleted or uninstalled.
- Show files opens the bottle's drive C: in Finder; Stop all programs ends every program of the bottle. Programs keep running when the app quits.
- If a program lies in Downloads, Documents or on the Desktop, macOS asks whether Freequay may access that folder. Allow it, or Wine cannot read the program.
- Add D3DMetal opens Apple's download page for "Evaluation environment for Windows games", free with an Apple Account. Freequay finds the disk image in Downloads, notes that D3DMetal is Apple's and under Apple's license, which allows using it to develop, test and evaluate games, and installs it when you click Install. If macOS shows Apple's license as the image opens, agree to it.
- When it starts, the app lifts the download quarantine from what it carries inside. Without that, macOS would stop the unsigned `wine`. Opened right on the disk image, it asks to be moved to Applications first.
- The first time it opens, the app lists the servers Freequay downloads from, and why. Freequay itself collects no data.
- The settings for your Steam games come from AppleGamingWiki: the app looks up each installed game there, at most once a week (see Rules from open sources).

Everything else, such as the graphics per program, is done in Terminal with `freequay`, the launcher the app calls as well.

## With Terminal

```bash
cd ~
curl -LO https://github.com/loewenmaehne/freequay/releases/download/v0.3.1/Freequay-0.3.1.dmg
hdiutil attach -nobrowse -mountpoint /tmp/freequay Freequay-0.3.1.dmg
cp -R /tmp/freequay/Freequay.app /Applications/
hdiutil detach /tmp/freequay
alias freequay=/Applications/Freequay.app/Contents/SharedSupport/freequay/scripts/freequay
freequay new games
```

curl sets no quarantine, so this needs no Open Anyway. After a browser download, macOS quarantines everything copied out of the disk image and stops the unsigned `wine` with a dialog until the app or this command lifts it: `xattr -dr com.apple.quarantine /Applications/Freequay.app`.

The first `freequay new` downloads Wine Mono (82 MB) from WineHQ. `freequay fix` installs the runtime packages that rules ask for with winetricks, without the Command Line Tools or Homebrew: Freequay brings its own `cabextract`, which unpacks with the bsdtar of macOS.

The commands run from anywhere; in a checkout of the repository, `scripts/freequay` is the same launcher.

```bash
freequay new games
freequay run games --backend dxmt "/path/to/Game.exe"
freequay run games "$HOME/Library/Application Support/freequay/Bottles/games/drive_c/Program Files (x86)/Steam/steam.exe"
freequay run games steam:440
freequay programs games
freequay programs games "/path/to/Game.exe"
freequay programs games "/path/to/Game.exe" -
freequay app games tf_win64.exe wined3d
freequay info games steam:440
freequay info "Grand Theft Auto IV"
freequay fix games --list
freequay applegamingwiki
```

Bottles live in `~/Library/Application Support/freequay/Bottles`. `run` starts a Windows program, a shortcut (`.lnk`) or a Steam game by its ID (`steam:440`, which Steam starts with `-applaunch`), and takes `--backend`, `--avx` (Rosetta reports AVX to the game), `--hud` (Metal performance HUD) and `--debug`. A program without a rule gets the bottle's default backend (`dxmt`, change it with `freequay set <bottle> backend <name>`) or the one from `--backend`. `dxmt` and `dxvk` have no Direct3D 12, so a program that imports `d3d12.dll` gets `d3dmetal` instead when it is installed, otherwise `wined3d`; without D3DMetal, programs that import `d3d11.dll` as well, as Unreal Engine games do, keep the default (details in `compat/README.md`).

`programs` lists what a bottle has, one name and `run` target per line, as the app shows it. With a program after the bottle it adds that to the list, and with `-` after the program it takes it off again: an added program is forgotten, a found one hidden. The bottle keeps both in `programs.txt`.

`freequay app <bottle> <program.exe|steam:ID> <backend>` sets the graphics for one program, `-` instead of the backend deletes it, and without a program the command lists the bottle's rules. `freequay rule` adds any directive, `freequay info` shows everything that applies to a program. New rules apply at the next program start, also while Steam is running. `freequay applegamingwiki` looks up the installed Steam games in AppleGamingWiki at once; `run` and `programs` do it by themselves.

Steam for Windows without the app: install it with `SteamSetup.exe /S` and start `steam.exe` with `run`. Before Steam starts, `run` catches up on the one-time setup the rules ask for (`freequay fix`).

## About

A quay is where ships come ashore; here Windows games land on your Mac. Quay is pronounced like "key".

Freequay is not affiliated with, endorsed by or supported by CodeWeavers or Apple. CrossOver is a trademark of CodeWeavers, Inc. CodeWeavers publish the sources this builds on and do most of the work on Wine for the Mac; if you want something that just works, with support, buy CrossOver.

### What is in it

- Wine 11.0 with all CodeWeavers patches from `crossover-sources-26.3.0.tar.gz`: msync, the D3DMetal hooks in winemac.drv, Rosetta tweaks and their fixes for single programs (Steam, the Rockstar Games Launcher, Epic, Ubisoft Connect, GTA IV and others). Built as x86_64 for Rosetta 2; 32-bit programs run through WoW64.
- FreeType, GnuTLS, nettle and gmp as x86_64 libraries from the same package. nettle 3.10 comes from the GNU release because the package lacks its `Makefile.in`.
- Graphics backends, chosen per program:
  - `dxmt`: DXMT 0.80 (Feifan He, MIT; versions after 0.80 are LGPL-2.1), Direct3D 10 and 11 on Metal.
  - `dxvk`: DXVK 1.10.3, CodeWeavers' Mac version from the same package (zlib), Direct3D 9 and 11 over Vulkan, with CodeWeavers' MoltenVK (Apache-2.0), which emulates geometry shaders.
  - `wined3d`: Wine's own Direct3D up to version 11; on the Mac CodeWeavers send Direct3D 10 and 11 through Vulkan. Direct3D 12 runs on Wine's d3d12 with vkd3d over MoltenVK.
  - `d3dmetal` and `d3dmetal3`: Apple's D3DMetal from the Game Porting Toolkit 4.0 beta 2 and 3.0, Direct3D 11 and 12. Never included: you download it from Apple yourself, and Apple's license applies; the app then installs it.
- Wine Mono from WineHQ for .NET programs; every new bottle gets it. Freequay does not ship it, the first new bottle downloads it.
- Rules per program: the open counterpart of CrossOver's closed compatibility database, filled from umu-protonfixes, Proton, ProtonDB and DXVK. The rules from AppleGamingWiki are not included; Freequay looks them up on your Mac (see below).
- `Freequay.app`, with all of the above inside, and `scripts/freequay`, the launcher for bottles that it calls, with its helpers: `applegamingwiki`, `fix` for the one-time setup with winetricks, and `cabextract`, which unpacks Microsoft's cabinet files with the bsdtar of macOS.

Wine is built for macOS 11 and newer, MoltenVK for macOS 12 and the app for macOS 13. DXMT names macOS 14 as its minimum and recommends macOS 15; its release 0.80 is built for macOS 15. So every part is meant to run on macOS 14 and newer.

### What is not in it

Nothing from the CrossOver app itself: not its user interface, no CrossTie installers, no D3DMetal from CrossOver and not CodeWeavers' compatibility database. GStreamer is not built yet.

### Compared with CrossOver 26.3

| Part | CrossOver | Freequay |
|---|---|---|
| Wine with CodeWeavers' patches | yes | yes, the same source |
| D3DMetal (Apple) | included | from Apple's download |
| DXMT | yes | yes (release 0.80) |
| DXVK with CodeWeavers' MoltenVK | yes | built from the same package |
| wined3d | yes | yes |
| msync, 32-bit through WoW64 | yes | yes |
| .NET through Wine Mono | yes | yes, from WineHQ |
| Settings per game | closed compatibility database | open rules (patch 0005, `compat/`) from protonfixes, Proton, ProtonDB and DXVK, and from AppleGamingWiki, made on your Mac |
| One-click installers (CrossTie) | yes | no; `freequay fix` installs the runtime packages the rules ask for with winetricks |
| User interface | yes | one window that starts programs (`Freequay.app`) and the command `freequay` |
| GStreamer (videos in games) | yes | not built yet |

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

`build-wine.sh` builds Wine for macOS 11 and newer and leaves out `pipe2`. The macOS 27 SDK has that function and older macOS does not; Wine calls it without checking, so with it Wine would most likely not start on macOS 26 and older. Releases up to 0.2.0 were built with it.

D3DMetal: the app leads to Apple's download and installs it. Without the app, download "Evaluation environment for Windows games" from developer.apple.com, mount it and run `scripts/install-d3dmetal.sh "/Volumes/<volume>"`. It installs D3DMetal 4 as `d3dmetal` and version 3 as `d3dmetal3` into `~/Library/Application Support/freequay/backends`, where it stays when Freequay is updated.

`scripts/build-app.sh` builds `Freequay.app` into the root of the repository with swiftc from Xcode or the Command Line Tools, and the helpers in `scripts/compat`: `applegamingwiki`, `fix` and `cabextract`. `scripts/package.sh 0.3.1` builds them as well, puts the build with the launcher, the rules and the license texts into `Freequay.app/Contents/SharedSupport/freequay`, signs the app with `scripts/sign.sh` and packs it into `out/Freequay-0.3.1.dmg`, the release disk image. `sign.sh` signs every Mach-O file with the hardened runtime and the entitlements Wine needs (`app/Freequay.entitlements`); without an identity the signature is ad hoc, with a Developer ID (Apple's developer program) the same call signs for notarization, which then only needs `xcrun notarytool` and `xcrun stapler`.

## Patches

- `0001-ntdll-priority-dll-path`: `FREEQUAY_PRIORITY_DLLPATH` puts a backend's DLLs before Wine's builtin d3d11 and dxgi. CrossOver does the same from its closed compatibility database through `prepend_dll_path()`.
- `0002-win32u-zero-fill-monitor-device-name` and `dxvk-0002-dxgi-output-device-name-size`: the display name (`\\.\DISPLAY1`) arrives padded with zeros as on Windows. Before, DXMT, DXVK and D3DMetal passed on garbage behind it, and the FFXIV benchmark launcher cut the game's command line there.
- `0003-kernelbase-chromium-helpers-software-rendering`: `steamwebhelper.exe` and Rockstar's `SocialClubHelper.exe` get `--disable-gpu --disable-gpu-compositing --in-process-gpu`. Their Chromium otherwise draws from a separate GPU process, which winemac.drv does not show: the windows stayed black.
- `0004-registry-hkcu-software-shared-view`: `HKCU\Software` is the same key for 32 and 64 bit, as on Windows 7 and later, even when a `Wow6432Node` exists below it. Steam creates one; Wine then redirected 32-bit access there, `steam_api64.dll` did not find the running Steam, and Team Fortress 2 crashed at start.
- `0005-ntdll-compat-rules-per-program`: rules per program. Every program looks up rules for its path or Steam app ID in the files from `FREEQUAY_COMPAT_FILES` when it starts and gets its graphics backend, environment variables, DLL overrides and launch arguments from them; a broken launcher can be replaced by the game itself. ntdll sets environment variables before a child process starts, because Rosetta reads `ROSETTA_ADVERTISE_AVX` only at exec. That is how Steam runs with wined3d and a game started from it with DXVK. A program that imports `d3d12.dll` and has no backend rule gets D3DMetal or wined3d, because DXMT and DXVK have no Direct3D 12 and Wine's d3d12 does not work with their dxgi. Format and commands: `compat/README.md`.
- `0006-cfgmgr32-reject-unknown-notification-handles`: `CM_Unregister_Notification` rejects unknown handles as Windows does. Steam's `steamclient64.dll` unregisters a stale handle when a game quits; Wine wrote into freed memory and an error dialog came up after Team Fortress 2.
- `0007-winemac-defer-display-mode-while-hiding`: Cmd+Tab out of a game in exclusive fullscreen, which captured the displays to change their mode, comes back to the game. Wine hides the app on Cmd+Tab, but macOS deactivates it only a moment later. A game that restored the desktop mode and minimized itself in that moment, as Direct3D 9 games do, made winemac.drv capture the displays again, which brought the app back to the front: its window minimized, the screen black without Dock and menu bar, and Cmd+Tab leading away from the game. The mode is now kept for when the app is active again, as for an app in the background.
- `dxvk-0003-config-from-environment`: DXVK also reads options from `DXVK_CONFIG` (separated by `;`), as DXVK 2.x does, so rules can set DXVK options per game.
- `moltenvk-0002-spirv-cross-alias-overlapping-samplers`: DXVK declares a depth-compare twin of every Direct3D 9 sampler on the same binding. SPIRV-Cross turned the twin's texture into an alias of the argument buffer slot but forgot its sampler, so every Direct3D 9 pixel shader with a texture failed to compile in MoltenVK and DXVK drew nothing. The sampler now gets the same alias.
- `dxvk-0001` and `moltenvk-0001` keep DXVK and MoltenVK buildable with mingw-w64 14 and Xcode 27.

## Rules from open sources

`compat/` holds the rules tested here (`manual.txt`) and rules from four open sources; the rules from a fifth, AppleGamingWiki, are made on your Mac. `scripts/compat/update.sh` downloads the four sources again and regenerates their files; what a source does not give, or what only applies on Linux, goes to `notes.tsv` and shows up in `freequay info`.

| File | Source | License | Taken (2026-10-13) |
|---|---|---|---|
| `applegamingwiki.txt`, made on your Mac | AppleGamingWiki, reports on CrossOver on Apple Silicon | CC BY-NC-SA 3.0 | graphics backend for 80 games, where the reports recommend exactly one and none reports problems with it; `ROSETTA_ADVERTISE_AVX` and MoltenVK variables |
| `protonfixes.txt` | umu-protonfixes, fixes per game | BSD-2-Clause | 204 of 313 fixes: winetricks verbs, DLL overrides, variables, registry, launch arguments, replaced launchers |
| `proton.txt` | Valve's Proton, launcher script | BSD-3-Clause | 77 games: heap zeroing, FNA on Direct3D 11, OpenSSL mask, DLL overrides |
| `protondb.txt` | ProtonDB, open export of all reports | ODbL 1.0 | 94 games: launch arguments, DLL overrides and Large Address Aware that at least three reports and a quarter of the working reports since 2023 agree on |
| `dxvk.txt` | DXVK, current game profiles | zlib | 165 of 261 profiles with options DXVK 1.10.3 knows; only with `backend=dxvk` |

Most of these come from Linux, where Proton runs with DXVK and Vulkan drivers; only the AppleGamingWiki rules are about the Mac. CodeWeavers' compatibility pages sit behind bot protection and are not read automatically.

AppleGamingWiki's license allows no commercial use, so Freequay does not ship its rules. It looks up the Steam games installed in a bottle one by one instead, each at most once a week, with two requests: the infobox of a game's page links to steamdb.info with its Steam ID, and AppleGamingWiki's list of pages with that link names the pages Freequay then reads. `freequay run <bottle> steam:<ID>` looks up the game right before it starts; the other installed games are looked up in the background when the app lists them, and so are the games Steam installs while it runs. The rules are kept in `~/Library/Application Support/freequay/compat`. Without network a game starts without them, and the next start tries again. The rules are the same as the ones Freequay 0.2.1 made from all pages, apart from Steam IDs that a page lists only as further editions, nearly all DLC that no game starts with. Of the 85 games with a rule on 2026-10-18, all matched except One Piece Odyssey, whose rule came from a misspelled page holding a copy of GTA V's text. The program behind it is `scripts/compat/applegamingwiki.swift`, a port of the Python importer of 0.2.1.

The one-time setup (winetricks verbs, registry values, Windows version) is done by `freequay fix <bottle>` for all installed Steam games. All games share a bottle, so the DLL overrides a winetricks verb sets apply only to the programs of the game that asked for it.

## Tests

Graphics tests from 2026-10-13 on a MacBook Air M1 with macOS 27.0.1; the programs in `tests/` ran again with every backend on 2026-10-18 for 0.2.1, 0.2.2 and 0.3.0, and for 0.3.1 without `--backend` and with `dxvk`:

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
| Direct3D 12, offscreen triangle with shaders (`tests/d3d12-draw`) | renders correctly with `d3dmetal`, `d3dmetal3` and with vkd3d over MoltenVK (Wine's own d3d12 with `wined3d`), with vkd3d also as a 32-bit program. `dxmt` and `dxvk` have no Direct3D 12; up to 0.2.0 `D3D12CreateDevice` failed with them, so a program without a rule did not start |
| Direct3D 12 without `--backend` or with `dxmt` or `dxvk` (`tests/d3d12-smoke`, `d3d12-draw`, `d3d12-draw32`), 0.2.1 | the 64-bit programs got `d3dmetal` with D3DMetal installed and `wined3d` without it, the 32-bit one `wined3d`; all correct, also when started by another program. The Unreal Engine 5 executable of the Wukong benchmark imports `d3d11.dll` and delay-loads `d3d12.dll`: it got `d3dmetal`, and kept `dxmt` without D3DMetal |
| Direct3D 11, `d3dmetal` (Apple 4.0 beta 2) | image correct; the adapter is called "AMD Compatibility Mode" |
| Direct3D 11, `d3dmetal3` (Apple 3.0) | image correct |
| Display name (`tests/devname`), all backends | padded with zeros with patches 0002 and dxvk-0002; garbage before with DXMT, DXVK and D3DMetal |

The programs under What runs need these backends, which their rules set: Steam and the Rockstar Games Launcher run with `wined3d`; with `dxmt` both abort at `SwapDeviceContextState`, the launcher with `dxvk` at `DXGID3D10CreateDevice`. Steam's window shows with patch 0003. Team Fortress 2 runs with `wined3d`, starts with patch 0004 and quits cleanly with patch 0006; with `dxvk` its image stayed black before patch moltenvk-0002 and was not tried again. The FFXIV benchmark ran with `dxmt`, its launcher on Wine Mono; a clean comparison of all backends is still open.

The release archives were tested like a new user would: downloaded with the quarantine a browser sets, unpacked into a new folder with a space in its path, with an empty home directory. With 0.1.0 all 29 graphics tests passed (Direct3D 9, 11 and 12, 32 and 64 bit, `dxmt`, `dxvk`, `wined3d`, vkd3d, and `d3dmetal` and `d3dmetal3` installed with the archive's `scripts/install-d3dmetal.sh`), and Steam installed, updated itself and showed its sign-in window. With 0.2.0 the app lifted the quarantine of its folder, created a bottle in 34 seconds with the Wine Mono download, opened Notepad from Finder, the Dock, a drop and its list within 2 to 4 seconds, installed Steam with its button and showed Steam's sign-in window about 80 seconds later. Programs started from the app stayed in the list after a restart, installers stayed out and removed entries stayed away; quick repeated clicks gave one program, and a click on an open program brought it forward. Not tested: Open Anyway for an app really downloaded with a browser. With 0.2.1, which changes the backend for Direct3D 12 and builds Wine without `pipe2`, the build folders were hidden during the test; the bottle took 31 seconds with Wine Mono copied from the build, and all 12 programs in `tests/` passed with `dxmt`, `dxvk`, `wined3d` and without `--backend`, then also with `d3dmetal` and `d3dmetal3` after `scripts/install-d3dmetal.sh` from the archive. The app and Steam were not tried again.

0.2.2 looks up the rules from AppleGamingWiki on the Mac, game by game. Its archive was tested the same way, with the build folders out of the test's reach. The bottle took 31 seconds and all 12 programs passed with every backend: 48 runs without D3DMetal, 72 with it. Started as one of seven Steam games, a program got the same backend, variables and AVX setting as under 0.2.1. The 85 games with a rule on 2026-10-18 got the same rules as from all pages, except One Piece Odyssey (see Rules from open sources). A game started with `run steam:<ID>` was looked up in about a second, without network the start went on after two seconds without the rules, and a game Steam installed while it ran was looked up within a minute. Steam installed from the temp folder as the app's button does it. The app lifted the quarantine of 1,933 files when it opened, looked up nothing before its note on downloads was read and the installed game three seconds after, and started Notepad from Finder in two seconds.

0.3.0 is one app on a disk image. The image carried the quarantine of a browser download; the app was copied out of it and opened with an empty home directory, with the build folders out of reach and the Command Line Tools' `python3`, `lipo` and `otool` blocked. The app lifted the quarantine of what it carries. The first bottle took 37 seconds with Wine Mono downloaded from WineHQ into the data folder, and the app's signature stayed valid, so nothing was written into the app. All 12 programs passed with every backend: 48 runs without D3DMetal, 72 after the app installed D3DMetal 4.0 beta 2 and 3.0 from disk images in Downloads named and laid out like Apple's. After the app was moved to another folder, they passed again with `dxmt`, `d3dmetal` and `d3dmetal3`. `freequay fix` set up a Steam game with DirectX packages in 62 seconds, without python3 or Homebrew. Steam installed and showed its sign-in window on its second start, and the app started Notepad from Finder in under a second. Not tried: Apple's download page itself, which needs an Apple Account, and Open Anyway for an app downloaded with a browser.

0.3.1 fixes the `cabextract` of 0.3.0, which left its work folder in the temporary folder of macOS after every call, several hundred MB for each DirectX package a game asked for. On Microsoft's DirectX package (`directx_Jun2010_redist.exe`) it now gives the same 40 cabinets and 40 DLLs as the real cabextract, byte for byte, and leaves no folder behind, also when a call fails. The image was tested like 0.3.0's, with the app approved by the Terminal steps above and Homebrew blocked as well: the first bottle took 61 seconds with the Wine Mono download, `freequay fix` set up a game with `d3dcompiler_43` and `d3dx9_43` in 48 seconds and left nothing in the temporary folder, the launcher removed a work folder older than an hour and kept a newer one, and all 12 programs passed without `--backend` and with `dxvk`.

`tests/` has the small programs behind these tests; build them with mingw-w64 as their first comment says. `tests/rulecheck` shows what the rules changed for a program: its path, command line, environment variables and where `d3d11.dll` comes from.

## Folders

`downloads/` source packages, `sources/` unpacked and patched sources, `build/` build trees, `deps/` x86_64 libraries, `dist/` the finished build with its backends, `out/` release disk images, `tools/` meson, `logs/` logs, `Freequay.app` the app built from `app/`, `scripts/compat/applegamingwiki`, `fix` and `cabextract` the programs built from the `.swift` files next to them. Only `app/`, `scripts/`, `patches/`, `compat/`, `tests/`, `licenses/` and the documents are versioned.

## License

- Scripts, app, tests and documents of this repository: MIT, see `LICENSE`.
- `patches/0*.patch` change Wine and are under Wine's license, LGPL-2.1-or-later. `patches/dxvk-*.patch` are under DXVK's zlib license, `patches/moltenvk-*.patch` under MoltenVK's Apache-2.0.
- The generated files in `compat/` keep the license of their source, named in each file's header: `protondb.txt` ODbL 1.0, `protonfixes.txt` BSD-2-Clause, `proton.txt` BSD-3-Clause, `dxvk.txt` zlib. Each row of `notes.tsv` names its source and keeps that source's license.
- The rules from AppleGamingWiki are not part of Freequay: Freequay looks them up on your Mac, where they keep AppleGamingWiki's license, CC BY-NC-SA 3.0.
- Builds contain Wine, DXVK, MoltenVK, DXMT and other components under their own licenses. If you pass a build on, those licenses apply, including the LGPL's source requirements. D3DMetal is Apple's and under Apple's license.
- The app has the license texts of all its parts in `Contents/SharedSupport/freequay/licenses/`; `licenses/README.md` lists them and where their source code is.
