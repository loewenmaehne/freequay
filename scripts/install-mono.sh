#!/bin/zsh
# Downloads Wine Mono (the free .NET replacement CrossOver ships as well) from WineHQ and puts it
# where Wine looks for it when it creates a bottle: $XDG_CACHE_HOME/wine, which scripts/freequay
# sets to ~/Library/Application Support/freequay/cache. Version and checksum are the ones this Wine
# build expects (dlls/appwiz.cpl/addons.c); when the sources are there, the script checks that they
# still match. Freequay does not ship Wine Mono, the first `freequay new` runs this script.
set -euo pipefail

ROOT=${0:A:h:h}
VERSION=10.4.1
SHA=071f4b2887e1c97a11d791ff3d65be9429eed6dec4c2708888bfd546ba358e23
ADDONS=$ROOT/sources/wine/dlls/appwiz.cpl/addons.c
DEST="$HOME/Library/Application Support/freequay/cache/wine"

if [[ -f $ADDONS ]]; then
  ver=$(awk '/#define MONO_VERSION/ { gsub(/"/, "", $3); print $3 }' "$ADDONS")
  sha=$(awk '/#define MONO_SHA/ && !/\?\?\?/ { gsub(/"/, "", $3); print $3 }' "$ADDONS")
  [[ $ver == "$VERSION" && $sha == "$SHA" ]] ||
    { print -u2 "Wine expects Wine Mono $ver ($sha); update VERSION and SHA in ${0:t}"; exit 1; }
fi
file=wine-mono-$VERSION-x86.msi

mkdir -p "$DEST"
if [[ ! -f $DEST/$file ]]; then
  print "downloading Wine Mono $VERSION from WineHQ (82 MB)"
  curl -fL --progress-bar -o "$DEST/$file.part" "https://dl.winehq.org/wine/wine-mono/$VERSION/$file"
  mv "$DEST/$file.part" "$DEST/$file"
fi
got=$(shasum -a 256 "$DEST/$file" | cut -d' ' -f1)
[[ $got == "$SHA" ]] || { print -u2 "checksum mismatch: $got"; rm -f "$DEST/$file"; exit 1; }
print "Wine Mono $VERSION is in $DEST"
