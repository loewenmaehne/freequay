#!/bin/zsh
# Packs the finished build into Freequay.app on a disk image, which runs without Xcode, Homebrew or a
# build of its own: open it, drag the app into Applications. The app carries everything in
# Contents/SharedSupport/freequay, laid out like the repository: Wine, DXMT, DXVK, MoltenVK, the
# x86_64 libraries with GStreamer, the launcher and its helpers, the rules and the license texts. What Freequay
# downloads or installs later goes to ~/Library/Application Support/freequay, so the signed app stays
# as it is. Left out: D3DMetal (Apple's license; the app leads to Apple's download), Wine Mono (the
# first bottle downloads it from WineHQ), the rules from AppleGamingWiki (its license allows no
# commercial use; they are looked up on the user's Mac) and what only building needs.
# Usage: package.sh <version> [identity]   writes out/Freequay-<version>.dmg and its .sha256; the
#                                          identity goes to scripts/sign.sh, ad hoc without one
set -euo pipefail

ROOT=${0:A:h:h}
VERSION=${1:?version missing, for example 0.3.0}
ID=${2:--}
PKG=$ROOT/build/package
APP=$PKG/Freequay.app
STAGE=$APP/Contents/SharedSupport/freequay
OUT=$ROOT/out/Freequay-$VERSION.dmg
SRC=$ROOT/sources
NETTLE=$ROOT/downloads/nettle/x/nettle-3.10
PCRE2=$ROOT/downloads/pcre2/x/pcre2-10.42

for f in dist/wine/bin/wine dist/backends/dxmt dist/backends/dxvk deps/lib/libMoltenVK.dylib sources/wine \
    sources/glib sources/gstreamer; do
  [[ -e $ROOT/$f ]] || { print -u2 "missing $f, build first (README, Build)"; exit 1; }
done
for d in $NETTLE $PCRE2; do [[ -d $d ]] || { print -u2 "missing $d, run scripts/fetch-sources.sh"; exit 1; }; done

print "==> staging $APP"
rm -rf "$PKG"; mkdir -p "$PKG" "${OUT:h}"
"$ROOT/scripts/build-app.sh" "$VERSION"
cp -Rc "$ROOT/Freequay.app" "$APP"
mkdir -p "$STAGE/dist/backends" "$STAGE/deps/lib" "$STAGE/scripts/compat"
cp -Rc "$ROOT/dist/wine" "$STAGE/dist/wine"
cp -Rc "$ROOT/dist/backends/dxmt" "$ROOT/dist/backends/dxvk" "$STAGE/dist/backends/"
rm -rf "$STAGE/dist/wine/include" "$STAGE/dist/wine/share/wine/mono"
find "$STAGE/dist/wine/lib" -name '*.a' -delete
for t in function_grep.pl widl winebuild winecpp winedump wineg++ winegcc winemaker wmc wrc; do
  rm -f "$STAGE/dist/wine/bin/$t"
  find "$STAGE/dist/wine/share/man" -name "$t.1" -delete
done

# The x86_64 libraries name each other by their path in deps/ of the build tree, where deps/
# really is if it is a link; in the archive they find each other next to themselves. Wine loads
# them by name from deps/lib, where scripts/freequay points DYLD_FALLBACK_LIBRARY_PATH.
DEPS=$ROOT/deps/lib
DEPS=${DEPS:A}/
for f in libMoltenVK.dylib libfreetype.6.dylib libgnutls.30.dylib libgmp.10.dylib \
    libnettle.8.9.dylib libnettle.8.dylib libhogweed.6.9.dylib libhogweed.6.dylib; do
  cp -Pc "$DEPS$f" "$STAGE/deps/lib/"
done
# GStreamer for winegstreamer: the plugins without the OpenGL one, which only draws into windows of
# its own, the plugin scanner, and the libraries these and winegstreamer.so link to (GLib and
# GStreamer's), found through otool. winegstreamer.so links them by their path in deps/.
setopt extended_glob
GST_PLUGINS=(${DEPS}gstreamer-1.0/(^libgstopengl).dylib(.N))
GST_SCANNER=${DEPS:h}/libexec/gstreamer-1.0/gst-plugin-scanner  # DEPS ends in a slash
GST_WINE=$STAGE/dist/wine/lib/wine/x86_64-unix/winegstreamer.so
(( $#GST_PLUGINS )) && [[ -x $GST_SCANNER && -f $GST_WINE ]] ||
  { print -u2 "missing GStreamer or winegstreamer, run scripts/build-gstreamer.sh and scripts/build-wine.sh reconfigure"; exit 1; }
mkdir -p "$STAGE/deps/lib/gstreamer-1.0" "$STAGE/deps/libexec/gstreamer-1.0"
cp -c $GST_PLUGINS "$STAGE/deps/lib/gstreamer-1.0/"
cp -c "$GST_SCANNER" "$STAGE/deps/libexec/gstreamer-1.0/"
todo=($GST_PLUGINS "$GST_SCANNER" "$GST_WINE")
typeset -A linked
while (( $#todo )); do
  # libraries right in deps/lib; a plugin names itself in deps/lib/gstreamer-1.0 first
  for dep in $(otool -L "$todo[1]" | awk -v d="$DEPS" 'NR > 1 && index($1, d) == 1 && substr($1, length(d) + 1) !~ /\// {print $1}'); do
    [[ -n ${linked[$dep]:-} ]] || { linked[$dep]=1; todo+=("$dep"); }
  done
  shift todo
done
cp -c ${(k)linked} "$STAGE/deps/lib/"

# moves a file's links into the build's deps/lib to the given folder (relative to @loader_path) and
# drops its search paths into the build tree
relink() { # file folder
  local dep rpath
  otool -L "$1" | awk -v d="$DEPS" 'NR > 1 && index($1, d) == 1 {print $1}' | sort -u |
    while read -r dep; do install_name_tool -change "$dep" "@loader_path/$2${dep:t}" "$1" 2> /dev/null; done
  otool -l "$1" | awk '$1 == "cmd" && $2 == "LC_RPATH" {getline; getline; print $2}' |
    while read -r rpath; do [[ $rpath != /* ]] || install_name_tool -delete_rpath "$rpath" "$1" 2> /dev/null; done
}
for f in "$STAGE"/deps/lib/*.dylib(.) "$STAGE"/deps/lib/gstreamer-1.0/*.dylib; do
  install_name_tool -id "@rpath/$(otool -D "$f" | tail -1 | xargs basename)" "$f" 2> /dev/null
done
for f in "$STAGE"/deps/lib/*.dylib(.); do relink "$f" ""; done
for f in "$STAGE"/deps/lib/gstreamer-1.0/*.dylib; do relink "$f" ../; done
relink "$STAGE/deps/libexec/gstreamer-1.0/gst-plugin-scanner" ../../lib/
relink "$GST_WINE" ../../../../../deps/lib/
codesign --force --sign - "$STAGE/deps/lib/libMoltenVK.dylib" 2> /dev/null
# besides each other, the libraries may only use the system's
gst_files=("$STAGE"/deps/lib/gstreamer-1.0/*.dylib "$STAGE/deps/libexec/gstreamer-1.0/gst-plugin-scanner" "$GST_WINE")
if otool -L "$STAGE"/deps/lib/*.dylib(.) $gst_files | awk '!/:$/ && $1 ~ /^\// && $1 !~ /^\/(usr\/lib|System)\//' | grep .; then
  print -u2 "deps/lib still points into the build tree"; exit 1
fi
if otool -l "$STAGE"/deps/lib/*.dylib(.) $gst_files | awk '$1 == "cmd" && $2 == "LC_RPATH" {getline; getline; print $2}' | grep '^/'; then
  print -u2 "a library still searches the build tree"; exit 1
fi

cp "$ROOT"/scripts/{freequay,install-d3dmetal.sh,install-mono.sh,link-backend.sh} "$STAGE/scripts/"
cp "$ROOT"/scripts/compat/{applegamingwiki,fix,cabextract,lipo} "$STAGE/scripts/compat/"
cp -R "$ROOT/compat" "$STAGE/compat"
# nothing from AppleGamingWiki goes into the archive
rm -f "$STAGE/compat/applegamingwiki.txt"
if grep -q $'\tapplegamingwiki\t' "$STAGE/compat/notes.tsv"; then
  print -u2 "compat/notes.tsv has rows from AppleGamingWiki, run scripts/compat/update.sh"; exit 1
fi
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
lic glib "$SRC"/glib/{COPYING,LICENSES/*.txt}
lic glib/pcre2 "$PCRE2"/LICENCE
lic glib/proxy-libintl "$SRC"/glib/subprojects/proxy-libintl/COPYING
for p in gstreamer gst-plugins-base gst-plugins-good gst-plugins-bad; do
  lic gstreamer/$p "$SRC"/gstreamer/subprojects/$p/COPYING
done

print "==> signing"
"$ROOT/scripts/sign.sh" "$APP" "$ID"

print "==> disk image $OUT"
mkdir -p "$PKG/dmg"
mv "$APP" "$PKG/dmg/"
ln -s /Applications "$PKG/dmg/Applications"
rm -f "$OUT" "$OUT.sha256"
hdiutil create -quiet -volname Freequay -srcfolder "$PKG/dmg" -fs APFS -format ULMO -o "$OUT"
( cd "${OUT:h}" && shasum -a 256 "${OUT:t}" > "${OUT:t}.sha256" )
print "app $(du -sh "$PKG/dmg/Freequay.app" | cut -f1), disk image $(du -h "$OUT" | cut -f1)"
cat "$OUT.sha256"
