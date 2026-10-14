#!/bin/zsh
# Downloads CodeWeavers' CrossOver 26.3.0 sources and GNU nettle 3.10, unpacks the parts this
# build uses into sources/ and applies the patches from patches/. CodeWeavers' package lacks
# nettle's Makefile.in, so nettle comes from the GNU release of the same version.
# A component that is already in sources/ stays as it is.
set -euo pipefail

ROOT=${0:A:h:h}
DL=$ROOT/downloads
CX_URL=https://media.codeweavers.com/pub/crossover/source/crossover-sources-26.3.0.tar.gz
CX_SHA=ac99c8ca4b3848f3e81784135f023df266b61c2345726ea55a50b3e030dd6872
NETTLE_URL=https://ftp.gnu.org/gnu/nettle/nettle-3.10.tar.gz
NETTLE_SHA=b4c518adb174e484cb4acea54118f02380c7133771e7e9beb98a0787194ee47c
COMPONENTS=(wine dxvk moltenvk freetype gnutls)

fetch() { # url sha256 file
  if [[ ! -f $3 ]]; then
    mkdir -p "${3:h}"
    print "==> downloading ${3:t}"
    curl -fL --progress-bar -o "$3.part" "$1"
    mv "$3.part" "$3"
  fi
  [[ $(shasum -a 256 "$3" | cut -d' ' -f1) == "$2" ]] || { print -u2 "checksum mismatch: $3"; exit 1; }
}

fetch $CX_URL $CX_SHA "$DL/${CX_URL:t}"
fetch $NETTLE_URL $NETTLE_SHA "$DL/nettle/${NETTLE_URL:t}"
if [[ ! -d $DL/nettle/x/nettle-3.10 ]]; then
  mkdir -p "$DL/nettle/x"
  tar -xzf "$DL/nettle/${NETTLE_URL:t}" -C "$DL/nettle/x"
fi

todo=()
for c in $COMPONENTS; do
  if [[ -d $ROOT/sources/$c ]]; then print "==> sources/$c exists, left as it is"; else todo+=($c); fi
done
(( $#todo )) || exit 0
print "==> unpacking $todo"
tar -xzf "$DL/${CX_URL:t}" -C "$ROOT" ${todo/#/sources/}

for c in $todo; do
  case $c in
    wine) patches=($ROOT/patches/0*.patch) ;;
    dxvk) patches=($ROOT/patches/dxvk-*.patch) ;;
    moltenvk) patches=($ROOT/patches/moltenvk-*.patch) ;;
    *) patches=() ;;
  esac
  for p in $patches; do
    print "==> $c: ${p:t}"
    patch -d "$ROOT/sources/$c" -p1 --no-backup-if-mismatch --quiet < "$p"
  done
done
print "==> done"
