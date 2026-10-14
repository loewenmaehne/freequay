#!/bin/zsh
# Downloads Wine Mono (the free .NET replacement CrossOver ships as well) from WineHQ and puts it
# where Wine looks for it when it creates a bottle. Version and checksum come from
# dlls/appwiz.cpl/addons.c, so it is exactly the version this Wine build expects.
set -euo pipefail

ROOT=${0:A:h:h}
ADDONS=$ROOT/sources/wine/dlls/appwiz.cpl/addons.c
DEST=$ROOT/dist/wine/share/wine/mono

ver=$(awk '/#define MONO_VERSION/ { gsub(/"/, "", $3); print $3 }' "$ADDONS")
sha=$(awk '/#define MONO_SHA/ && !/\?\?\?/ { gsub(/"/, "", $3); print $3 }' "$ADDONS")
[[ -n $ver && -n $sha ]] || { print -u2 "version or checksum not found in $ADDONS"; exit 1; }
file=wine-mono-$ver-x86.msi

mkdir -p "$DEST"
if [[ ! -f $DEST/$file ]]; then
  curl -fL --progress-bar -o "$DEST/$file.part" "https://dl.winehq.org/wine/wine-mono/$ver/$file"
  mv "$DEST/$file.part" "$DEST/$file"
fi
got=$(shasum -a 256 "$DEST/$file" | cut -d' ' -f1)
[[ $got == "$sha" ]] || { print -u2 "checksum mismatch: $got"; rm -f "$DEST/$file"; exit 1; }
print "Wine Mono $ver is in $DEST"
