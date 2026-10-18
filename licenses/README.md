# Licenses and source code

Freequay.app contains the parts below, in `Contents/SharedSupport/freequay`. Each keeps its own license; this folder has the license texts. Freequay's own scripts and documents are under the MIT license (`LICENSE` in the top folder). `scripts/package.sh` builds the app and copies the texts that are not in this folder of the repository from the sources the build used.

## Programs and libraries

| Part | Version | License | Texts |
|---|---|---|---|
| Wine with CodeWeavers' patches and Freequay's patches `0001` to `0006` | 11.0, from CrossOver 26.3.0 | LGPL-2.1-or-later | `wine/` |
| Libraries Wine builds in: Capstone, compiler-rt, FAudio, FluidSynth, GSM, libjpeg, jxrlib, Little CMS, OpenLDAP, mpg123, musl, libpng, LibTIFF, LibTomCrypt, vkd3d, libxml2, libxslt, zlib | as in the Wine sources | their own: LGPL-2.1 (FluidSynth, mpg123, vkd3d), BSD, MIT, zlib and similar permissive licenses | `wine/libs/<name>/` |
| GnuTLS, with the libtasn1 and libunistring it includes | 3.8.3 | LGPL-2.1-or-later; libunistring LGPL-3.0-or-later or GPL-2.0-or-later | `gnutls/`, texts of version 3 in `gmp/` |
| GMP | 6.3.0 | LGPL-3.0-or-later or GPL-2.0-or-later | `gmp/` |
| Nettle | 3.10 | LGPL-3.0-or-later or GPL-2.0-or-later | `nettle/` |
| FreeType | 2.13.3 | FreeType License (FTL), chosen from FTL or GPL-2.0 | `freetype/` |
| MoltenVK, CodeWeavers' version, with Freequay's patches `moltenvk-0001` and `-0002` | 1.2.10 | Apache-2.0 | `moltenvk/` |
| Inside MoltenVK: SPIRV-Cross (CodeWeavers' version), glslang, cereal, Vulkan-Headers | as in MoltenVK's `ExternalRevisions` | Apache-2.0; glslang BSD-3-Clause and others; cereal BSD-3-Clause | `moltenvk/<name>/` |
| DXVK, CodeWeavers' Mac version, with Freequay's patches `dxvk-0001` to `-0003` | 1.10.3 | zlib; the OpenVR header it uses BSD-3-Clause | `dxvk/` |
| DXMT, release build from github.com/3Shain/dxmt | 0.80 | MIT (the license at that release; later versions are LGPL-2.1) | `dxmt/LICENSE` |
| Inside DXMT: DXBCParser (Microsoft), NVAPI headers (NVIDIA), LLVM 15 | | MIT; MIT; Apache-2.0 with LLVM exception | `dxmt/` |

Portions of this software are copyright © 2024 The FreeType Project (www.freetype.org). All rights reserved.

Freequay changed Wine, MoltenVK and DXVK; the changes are the files in `patches/` of the repository, described in the README.

## Rules per program

| File in `compat/` | Source | License | Text |
|---|---|---|---|
| `manual.txt` | Freequay | MIT | `LICENSE` |
| `protonfixes.txt` | umu-protonfixes | BSD-2-Clause | `compat/protonfixes-LICENSE` |
| `proton.txt` | Valve's Proton | BSD-3-Clause | `compat/proton-LICENSE` |
| `protondb.txt` | ProtonDB data export | ODbL 1.0 | `compat/ODbL-1.0.txt` |
| `dxvk.txt` | DXVK game profiles | zlib | `dxvk/LICENSE` |

Each row of `notes.tsv` names its source and keeps that source's license.

## Not in the app

- D3DMetal: Apple's, under Apple's license. You download it from Apple yourself; the app, or `scripts/install-d3dmetal.sh`, copies it from that disk image into `~/Library/Application Support/freequay/backends`.
- Wine Mono: the first `freequay new` downloads it unchanged from WineHQ (dl.winehq.org/wine/wine-mono/10.4.1), where its source is as well, into `~/Library/Application Support/freequay/cache`.
- winetricks: `freequay fix` downloads it from its GitHub repository, into `~/Library/Application Support/freequay/cache`.
- cabextract: winetricks calls it, but Freequay brings no copy; `scripts/compat/cabextract`, Freequay's own program, unpacks with the bsdtar (libarchive) that comes with macOS.
- The rules from AppleGamingWiki: its content is under CC BY-NC-SA 3.0, which allows no commercial use. `scripts/compat/applegamingwiki` looks up the pages of the installed Steam games on applegamingwiki.com and makes the rules on your Mac, in `~/Library/Application Support/freequay/compat`; the header of the file names the license (creativecommons.org/licenses/by-nc-sa/3.0/).

## Source code

The source of everything under the LGPL in the app (Wine with its built-in libraries, GnuTLS, GMP, Nettle) and of the other parts Freequay built is in these files, attached unchanged to the same GitHub release:

| File | SHA-256 | Original location |
|---|---|---|
| `crossover-sources-26.3.0.tar.gz` (Wine, GnuTLS, GMP, FreeType, MoltenVK, SPIRV-Cross, DXVK) | `ac99c8ca4b3848f3e81784135f023df266b61c2345726ea55a50b3e030dd6872` | media.codeweavers.com/pub/crossover/source/ |
| `nettle-3.10.tar.gz` (Nettle; CodeWeavers' package lacks its `Makefile.in`) | `b4c518adb174e484cb4acea54118f02380c7133771e7e9beb98a0787194ee47c` | ftp.gnu.org/gnu/nettle/ |

Freequay's patches and build scripts are the repository at the release's tag (github.com/loewenmaehne/freequay); `scripts/fetch-sources.sh` unpacks and patches the sources, the steps under "Build" in the README build what the app contains. MoltenVK's `fetchDependencies` gets glslang, cereal and Vulkan-Headers at the revisions in `ExternalRevisions`. DXMT 0.80: github.com/3Shain/dxmt, tag `v0.80`.
