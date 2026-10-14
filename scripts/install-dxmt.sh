#!/bin/zsh
# Downloads the builtin release of DXMT (Direct3D 10 and 11 on Metal, LGPL-2.1, Feifan He for
# CodeWeavers) and installs it as the graphics backend dxmt in dist/backends/dxmt.
set -euo pipefail

ROOT=${0:A:h:h}
VERSION=v0.80
URL=https://github.com/3Shain/dxmt/releases/download/$VERSION/dxmt-$VERSION-builtin.tar.gz
SHA=8f260e36b5739e68f3bad613381441385c4dc7b85b78ba8de653d5a6a264529d
FILE=$ROOT/downloads/dxmt/${URL:t}
DEST=$ROOT/dist/backends/dxmt

if [[ ! -f $FILE ]]; then
  mkdir -p "${FILE:h}"
  curl -fL --progress-bar -o "$FILE.part" "$URL"
  mv "$FILE.part" "$FILE"
fi
[[ $(shasum -a 256 "$FILE" | cut -d' ' -f1) == "$SHA" ]] || { print -u2 "checksum mismatch: $FILE"; exit 1; }

rm -rf "$DEST"; mkdir -p "$DEST"
tar --strip-components 1 -xzf "$FILE" -C "$DEST"
xattr -dr com.apple.quarantine "$DEST" 2>/dev/null || true
"$ROOT/scripts/link-backend.sh" "$DEST/x86_64-unix"
print "DXMT $VERSION installed in $DEST"
