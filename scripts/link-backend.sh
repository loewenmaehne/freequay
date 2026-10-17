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

# No otool or python3 here: on a Mac without the Command Line Tools both only offer to install
# them, and the release archive must run there. The @rpath names stand in the binaries as plain
# strings; the path to Wine is computed in zsh.
base=$DIR; up=
while [[ $WINE_UNIX != ${base%/}/* ]]; do base=${base:h}; up+=../; done
rel=$up${WINE_UNIX#${base%/}/}

for lib in "$DIR"/*.(so|dylib)(N); do
  LC_ALL=C grep -aoE '@rpath/[A-Za-z0-9_.+-]+\.(so|dylib)' "$lib" | sed 's|^@rpath/||' | sort -u |
  while read -r dep; do
    if [[ ! -e $DIR/$dep && -e $WINE_UNIX/$dep ]]; then
      ln -s "$rel/$dep" "$DIR/$dep"
      print "linked: $dep"
    fi
  done
done
