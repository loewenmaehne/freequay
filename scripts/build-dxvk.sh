#!/bin/zsh
# Builds CodeWeavers' DXVK (the Mac version 1.10.3 from crossover-sources-26.3.0) for 64 and
# 32 bit and marks the DLLs as Wine builtins with winebuild. That way Freequay switches to DXVK
# through FREEQUAY_PRIORITY_DLLPATH like DXMT and D3DMetal, without swapping files in the bottle.
set -euo pipefail

ROOT=${0:A:h:h}
SRC=$ROOT/sources/dxvk
BUILD=$ROOT/build/dxvk
OUT=$ROOT/dist/backends/dxvk
VENV=$ROOT/tools/meson/venv
MESON=$VENV/bin/meson
export PATH="/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"

# meson from PyPI in its own venv, made with Homebrew's Python (meson 1.12 needs Python 3.10 or
# newer; the one in macOS is 3.9). Homebrew's meson formula would pull in yet another Python.
if [[ ! -x $MESON ]]; then
  python3 -c 'import sys; sys.exit(sys.version_info < (3, 10))' ||
    { print -u2 "need Python 3.10 or newer as python3 (brew install python)"; exit 1; }
  python3 -m venv "$VENV"
  "$VENV/bin/pip" install --quiet meson==1.12.1
fi

mkdir -p "$BUILD"
for arch in 64 32; do
  if [[ $arch == 64 ]]; then cross=build-win64.txt; dir=x86_64-windows; else cross=build-win32.txt; dir=i386-windows; fi
  print "==> DXVK $arch-bit"
  rm -rf "$BUILD/$arch"
  # DXVK 1.10.3 is from 2022; GCC 15 wants <cstdint> included explicitly
  { cat "$SRC/$cross"; print "\n[built-in options]\ncpp_args = ['-include', 'cstdint']"; } > "$BUILD/$cross"
  # Direct3D 10 stays off: its UUIDs clash with mingw-w64 14
  "$MESON" setup --cross-file "$BUILD/$cross" --buildtype release --strip \
    --prefix "$BUILD/$arch/install" --bindir "$dir" --libdir "$dir" -Denable_tests=false -Denable_d3d10=false \
    "$BUILD/$arch" "$SRC" > "$BUILD/setup-$arch.log" 2>&1 || { tail -30 "$BUILD/setup-$arch.log"; exit 1; }
  ninja -C "$BUILD/$arch" install > "$BUILD/ninja-$arch.log" 2>&1 || { grep -nE 'error' "$BUILD/ninja-$arch.log" | head -20; tail -20 "$BUILD/ninja-$arch.log"; exit 1; }
  rm -rf "$OUT/$dir"; mkdir -p "$OUT/$dir"
  cp "$BUILD/$arch/install/$dir"/*.dll "$OUT/$dir/"
done

for f in "$OUT"/*-windows/*.dll; do "$ROOT/dist/wine/bin/winebuild" --builtin "$f"; done
print "==> done"
ls -la "$OUT"/*-windows
