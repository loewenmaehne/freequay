#!/bin/zsh
# Configures and builds Wine from the CrossOver 26.3.0 sources: x86_64 for Rosetta, 32-bit
# programs through WoW64. Usage: build-wine.sh [reconfigure]
set -euo pipefail

ROOT=${0:A:h:h}
SRC=$ROOT/sources/wine
DEPS=$ROOT/deps
BUILD=$ROOT/build/wine
PREFIX=$ROOT/dist/wine
JOBS=8

export PATH="/opt/homebrew/opt/bison/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"
export PKG_CONFIG_LIBDIR="$DEPS/lib/pkgconfig"
export MACOSX_DEPLOYMENT_TARGET=11.0

mkdir -p "$BUILD"; cd "$BUILD"

if [[ ! -f Makefile || "${1:-}" == reconfigure ]]; then
  print "==> configure"
  # --without-opengl only turns off EGL (for X11/Wayland); OpenGL on the Mac goes through
  # winemac.drv with CGL and is always built.
  # build and host fixed to x86_64: the helper tools (widl, winebuild ...) are built as x86_64
  # and run under Rosetta, otherwise configure takes the M1 for the target.
  "$SRC/configure" --prefix="$PREFIX" \
    --build=x86_64-apple-darwin --host=x86_64-apple-darwin \
    --enable-archs=i386,x86_64 --disable-tests \
    --with-mingw --without-x --without-wayland \
    --with-coreaudio --with-cups --with-opencl --without-opengl \
    --with-freetype --with-gnutls --with-vulkan \
    --without-alsa --without-capi --without-dbus --without-ffmpeg --without-fontconfig \
    --without-gettext --without-gettextpo --without-gphoto --without-gssapi --without-gstreamer \
    --without-hwloc --without-inotify --without-krb5 --without-netapi --without-oss \
    --without-pcap --without-pcsclite --without-pulse --without-sane --without-sdl \
    --without-udev --without-unwind --without-usb --without-v4l2 \
    CC="clang -arch x86_64" OBJC="clang -arch x86_64" \
    CFLAGS="-O2" CROSSCFLAGS="-O2" \
    LDFLAGS="-L$DEPS/lib -Wl,-headerpad_max_install_names" \
    FREETYPE_CFLAGS="-I$DEPS/include/freetype2" FREETYPE_LIBS="-L$DEPS/lib -lfreetype" \
    GNUTLS_CFLAGS="-I$DEPS/include" GNUTLS_LIBS="-L$DEPS/lib -lgnutls" \
    > configure.log 2>&1 || { tail -50 configure.log; exit 1; }
  grep -E '^configure: (WARNING|error)|libMoltenVK|vulkan' configure.log | tail -20 || true
fi

print "==> make ($(date +%H:%M))"
make -j$JOBS > make.log 2>&1 || { grep -nE ' error|Error [0-9]' make.log | head -30; tail -30 make.log; exit 1; }
print "==> make install ($(date +%H:%M))"
make install > install.log 2>&1 || { tail -30 install.log; exit 1; }
print "==> done ($(date +%H:%M))"
du -sh "$PREFIX"
