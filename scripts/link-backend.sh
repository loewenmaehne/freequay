#!/bin/zsh
# Links the Wine Unix libraries (ntdll.so, winemac.so ...) that a graphics backend expects via
# @rpath into the backend's x86_64-unix directory. Backends like DXMT and D3DMetal are built to
# sit right in Wine's lib/wine/x86_64-unix; they stay separate here so that Freequay can switch
# them per game. The links are relative, so the checkout can move.
# Usage: link-backend.sh <x86_64-unix directory of the backend>
set -euo pipefail

ROOT=${0:A:h:h}
WINE_UNIX=$ROOT/dist/wine/lib/wine/x86_64-unix
DIR=${${1:?directory missing}:A}
[[ -d $WINE_UNIX ]] || { print -u2 "Wine is not installed yet: $WINE_UNIX"; exit 1; }

for lib in "$DIR"/*.(so|dylib)(N); do
  otool -L "$lib" | awk 'NR>1 && $1 ~ /^@rpath\// {sub("@rpath/","",$1); print $1}' |
  while read -r dep; do
    if [[ ! -e $DIR/$dep && -e $WINE_UNIX/$dep ]]; then
      ln -s "$(python3 -I -c 'import os, sys; print(os.path.relpath(sys.argv[1], sys.argv[2]))' "$WINE_UNIX/$dep" "$DIR")" "$DIR/$dep"
      print "linked: $dep"
    fi
  done
done
