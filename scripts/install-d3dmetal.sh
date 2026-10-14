#!/bin/zsh
# Adds D3DMetal from Apple's Game Porting Toolkit as a graphics backend.
# D3DMetal is Apple's closed library and not part of the CrossOver sources. Download the .dmg
# ("Evaluation environment for Windows games") yourself from Apple (developer.apple.com/games,
# Apple account, Apple's license) and mount it.
# Usage: install-d3dmetal.sh "/Volumes/<GPTK volume>" [backend name, default d3dmetal]
set -euo pipefail

ROOT=${0:A:h:h}
VOL=${1:?path to the mounted Game Porting Toolkit volume missing}
NAME=${2:-d3dmetal}
DEST=$ROOT/dist/backends/$NAME/lib

REDIST=$(find "$VOL" -maxdepth 4 -type d -path '*/redist/lib' 2>/dev/null | head -1)
[[ -n $REDIST && -d $REDIST/wine ]] || { print -u2 "redist/lib with wine/ not found in $VOL"; exit 1; }

print "source: $REDIST"
rm -rf "$DEST"; mkdir -p "$DEST"
ditto "$REDIST" "$DEST"
xattr -dr com.apple.quarantine "$DEST" 2>/dev/null || true

# as Apple's Read Me says: offer the DLSS bridge to MetalFX under the name nvngx
for ext in dll so; do
  d=$DEST/wine/x86_64-${${ext:#dll}:+unix}${${ext:#so}:+windows}
  [[ -e $d/nvngx-on-metalfx.$ext && ! -e $d/nvngx.$ext ]] && mv "$d/nvngx-on-metalfx.$ext" "$d/nvngx.$ext"
done

for d in "$DEST"/wine/*-unix(N/); do "$ROOT/scripts/link-backend.sh" "$d"; done
print "D3DMetal $(defaults read "$DEST/external/D3DMetal.framework/Resources/Info.plist" CFBundleShortVersionString 2>/dev/null) installed as backend $NAME"
