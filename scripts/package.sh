#!/bin/zsh
# Packs the finished build into a release archive that runs without Xcode, Homebrew or a build of
# its own: Wine, DXMT, DXVK, MoltenVK, the x86_64 libraries, the launcher, Freequay.app, the rules
# and the license texts. Left out: D3DMetal (Apple's license, scripts/install-d3dmetal.sh), Wine
# Mono (the first `freequay new` downloads it from WineHQ) and what only building needs (headers,
# import libraries, compiler tools).
# Usage: package.sh <version>      writes out/freequay-<version>-macos.tar.xz and its .sha256
set -euo pipefail

ROOT=${0:A:h:h}
VERSION=${1:?version missing, for example 0.1.0}
NAME=freequay-$VERSION
STAGE=$ROOT/build/package/$NAME
OUT=$ROOT/out/$NAME-macos.tar.xz
SRC=$ROOT/sources
NETTLE=$ROOT/downloads/nettle/x/nettle-3.10

for f in dist/wine/bin/wine dist/backends/dxmt dist/backends/dxvk deps/lib/libMoltenVK.dylib sources/wine; do
  [[ -e $ROOT/$f ]] || { print -u2 "missing $f, build first (README, Build)"; exit 1; }
done
[[ -d $NETTLE ]] || { print -u2 "missing $NETTLE, run scripts/fetch-sources.sh"; exit 1; }

print "==> staging $STAGE"
rm -rf "$STAGE"; mkdir -p "$STAGE/dist/backends" "$STAGE/deps/lib" "$STAGE/scripts/compat" "${OUT:h}"
cp -Rc "$ROOT/dist/wine" "$STAGE/dist/wine"
cp -Rc "$ROOT/dist/backends/dxmt" "$ROOT/dist/backends/dxvk" "$STAGE/dist/backends/"
rm -rf "$STAGE/dist/wine/include" "$STAGE/dist/wine/share/wine/mono"
find "$STAGE/dist/wine/lib" -name '*.a' -delete
for t in function_grep.pl widl winebuild winecpp winedump wineg++ winegcc winemaker wmc wrc; do
  rm -f "$STAGE/dist/wine/bin/$t"
  find "$STAGE/dist/wine/share/man" -name "$t.1" -delete
done

# The x86_64 libraries name each other by their path in deps/ of the build tree; in the archive
# they find each other next to themselves. Wine loads them by name from deps/lib, where
# scripts/freequay points DYLD_FALLBACK_LIBRARY_PATH.
for f in libMoltenVK.dylib libfreetype.6.dylib libgnutls.30.dylib libgmp.10.dylib \
    libnettle.8.9.dylib libnettle.8.dylib libhogweed.6.9.dylib libhogweed.6.dylib; do
  cp -Pc "$ROOT/deps/lib/$f" "$STAGE/deps/lib/"
done
for f in "$STAGE"/deps/lib/*.dylib(.); do
  install_name_tool -id "@rpath/$(otool -D "$f" | tail -1 | xargs basename)" "$f" 2> /dev/null
  otool -L "$f" | awk -v d="$ROOT/deps/lib/" 'index($1, d) == 1 {print $1}' | sort -u |
    while read -r dep; do install_name_tool -change "$dep" "@loader_path/${dep:t}" "$f" 2> /dev/null; done
done
codesign --force --sign - "$STAGE/deps/lib/libMoltenVK.dylib" 2> /dev/null
if otool -L "$STAGE"/deps/lib/*.dylib(.) | grep -F -- "$ROOT/deps/"; then
  print -u2 "deps/lib still points into the build tree"; exit 1
fi

cp "$ROOT"/scripts/{freequay,install-d3dmetal.sh,install-mono.sh,link-backend.sh} "$STAGE/scripts/"
"$ROOT/scripts/build-app.sh" "$VERSION"
cp -Rc "$ROOT/Freequay.app" "$STAGE/"
cp "$ROOT/scripts/compat/fix.py" "$STAGE/scripts/compat/"
cp -R "$ROOT/compat" "$STAGE/compat"
cp "$ROOT/README.md" "$ROOT/LICENSE" "$STAGE/"
print -r -- "Freequay $VERSION ($(git -C "$ROOT" rev-parse --short HEAD)), Wine from crossover-sources-26.3.0" > "$STAGE/VERSION"

# License texts: licenses/ of the repository has the overview and the texts no source package has,
# the rest comes from the sources the build used
L=$STAGE/licenses
cp -R "$ROOT/licenses" "$L"
lic() { # folder in licenses/, files
  local d=$L/$1; shift
  mkdir -p "$d"; cp "$@" "$d/"
}
lic wine "$SRC"/wine/{LICENSE,COPYING.LIB,AUTHORS}
for d in "$SRC"/wine/libs/*(/); do
  files=("$d"/(LICENSE|COPYING|COPYRIGHT)*(N.))
  (( ! $#files )) || lic "wine/libs/${d:t}" $files
done
lic gnutls "$SRC"/gnutls/gnutls/{LICENSE,AUTHORS,doc/COPYING.LESSER}
lic gnutls/inih "$SRC"/gnutls/gnutls/lib/inih/LICENSE.txt
lic gmp "$SRC"/gnutls/gmp/{COPYING.LESSERv3,COPYINGv2,COPYINGv3}
lic nettle "$NETTLE"/{COPYING.LESSERv3,COPYINGv2,COPYINGv3}
lic freetype "$SRC"/freetype/{LICENSE.TXT,docs/FTL.TXT,docs/GPLv2.TXT}
lic dxvk "$SRC"/dxvk/LICENSE
lic dxvk/openvr "$SRC"/dxvk/include/openvr/LICENSE
lic moltenvk "$SRC"/moltenvk/LICENSE
lic moltenvk/SPIRV-Cross "$SRC"/moltenvk/External/SPIRV-Cross-cx/{LICENSE,LICENSES/*}
lic moltenvk/glslang "$SRC"/moltenvk/External/glslang/LICENSE.txt
lic moltenvk/cereal "$SRC"/moltenvk/External/cereal/LICENSE
lic moltenvk/Vulkan-Headers "$SRC"/moltenvk/External/Vulkan-Headers/{LICENSE.md,LICENSES/*}

print "==> packing $OUT"
rm -f "$OUT" "$OUT.sha256"
COPYFILE_DISABLE=1 tar --no-mac-metadata --no-xattrs --exclude .DS_Store --exclude __pycache__ \
  --uid 0 --gid 0 --uname root --gname wheel \
  --options xz:compression-level=9,xz:threads=0 -cJf "$OUT" -C "${STAGE:h}" "$NAME"
( cd "${OUT:h}" && shasum -a 256 "${OUT:t}" > "${OUT:t}.sha256" )
print "unpacked $(du -sh "$STAGE" | cut -f1), packed $(du -h "$OUT" | cut -f1)"
cat "$OUT.sha256"
