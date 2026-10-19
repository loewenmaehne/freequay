#!/bin/zsh
# Downloads CodeWeavers' CrossOver 26.3.0 sources, GNU nettle 3.10, pcre2 10.42, proxy-libintl 0.4
# and gvdb, unpacks the parts this build uses into sources/ and applies the patches from patches/.
# CodeWeavers' package lacks nettle's Makefile.in, so nettle comes from the GNU release of the same
# version; GLib needs pcre2 and a libintl, which the package does not have at all, and gvdb, whose
# folder is empty in it (the revision GLib's wrap names). Of GStreamer only the core and the base,
# good and bad plugins are unpacked.
# A component that is already in sources/ stays as it is.
set -euo pipefail

ROOT=${0:A:h:h}
DL=$ROOT/downloads
CX_URL=https://media.codeweavers.com/pub/crossover/source/crossover-sources-26.3.0.tar.gz
CX_SHA=ac99c8ca4b3848f3e81784135f023df266b61c2345726ea55a50b3e030dd6872
NETTLE_URL=https://ftp.gnu.org/gnu/nettle/nettle-3.10.tar.gz
NETTLE_SHA=b4c518adb174e484cb4acea54118f02380c7133771e7e9beb98a0787194ee47c
PCRE2_URL=https://github.com/PhilipHazel/pcre2/releases/download/pcre2-10.42/pcre2-10.42.tar.bz2
PCRE2_SHA=8d36cd8cb6ea2a4c2bb358ff6411b0c788633a2a45dabbf1aeb4b701d1b5e840
INTL_URL=https://github.com/frida/proxy-libintl/archive/refs/tags/0.4.tar.gz
INTL_SHA=13ef3eea0a3bc0df55293be368dfbcff5a8dd5f4759280f28e030d1494a5dffb
GVDB_REV=0854af0fdb6d527a8d1999835ac2c5059976c210
GVDB_URL=https://gitlab.gnome.org/GNOME/gvdb/-/archive/$GVDB_REV/gvdb-$GVDB_REV.tar.gz
GVDB_SHA=08352e54e8216d9001820c627c62858585465b51dc557cc22f0f4770ed182ebd
COMPONENTS=(wine dxvk moltenvk freetype gnutls glib gstreamer)
GST_PARTS=(LICENSE README.md subprojects/gstreamer subprojects/gst-plugins-base
  subprojects/gst-plugins-good subprojects/gst-plugins-bad)

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
fetch $PCRE2_URL $PCRE2_SHA "$DL/pcre2/${PCRE2_URL:t}"
if [[ ! -d $DL/pcre2/x/pcre2-10.42 ]]; then
  mkdir -p "$DL/pcre2/x"
  tar -xjf "$DL/pcre2/${PCRE2_URL:t}" -C "$DL/pcre2/x"
fi
fetch $INTL_URL $INTL_SHA "$DL/proxy-libintl/proxy-libintl-0.4.tar.gz"
fetch $GVDB_URL $GVDB_SHA "$DL/gvdb/${GVDB_URL:t}"

todo=()
for c in $COMPONENTS; do
  if [[ -d $ROOT/sources/$c ]]; then print "==> sources/$c exists, left as it is"; else todo+=($c); fi
done
if (( $#todo )); then
  print "==> unpacking $todo"
  paths=()
  for c in $todo; do
    if [[ $c == gstreamer ]]; then paths+=(${GST_PARTS/#/sources/gstreamer/}); else paths+=(sources/$c); fi
  done
  tar -xzf "$DL/${CX_URL:t}" -C "$ROOT" $paths
fi
# GLib's meson takes proxy-libintl and gvdb from its subprojects folder, under the names its wraps give
if [[ ! -d $ROOT/sources/glib/subprojects/proxy-libintl ]]; then
  mkdir -p "$ROOT/sources/glib/subprojects/proxy-libintl"
  tar -xzf "$DL/proxy-libintl/proxy-libintl-0.4.tar.gz" -C "$ROOT/sources/glib/subprojects/proxy-libintl" --strip-components 1
fi
if [[ ! -f $ROOT/sources/glib/subprojects/gvdb/meson.build ]]; then
  mkdir -p "$ROOT/sources/glib/subprojects/gvdb"
  tar -xzf "$DL/gvdb/${GVDB_URL:t}" -C "$ROOT/sources/glib/subprojects/gvdb" --strip-components 1
fi

for c in $todo; do
  case $c in
    wine) patches=($ROOT/patches/0*.patch) ;;
    dxvk) patches=($ROOT/patches/dxvk-*.patch) ;;
    moltenvk) patches=($ROOT/patches/moltenvk-*.patch) ;;
    glib) patches=($ROOT/patches/glib-*.patch) ;;
    *) patches=() ;;
  esac
  for p in $patches; do
    print "==> $c: ${p:t}"
    patch -d "$ROOT/sources/$c" -p1 --no-backup-if-mismatch --quiet < "$p"
  done
done
print "==> done"
