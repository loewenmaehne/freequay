#!/bin/zsh
# Builds the x86_64 libraries Wine needs (gmp, nettle, gnutls, freetype) from the CrossOver
# 26.3.0 sources. Runs on Apple Silicon: clang emits x86_64 code, configure's test programs run
# under Rosetta.
set -euo pipefail

ROOT=${0:A:h:h}
SRC=$ROOT/sources
DEPS=$ROOT/deps
WORK=$ROOT/build/deps
JOBS=8
HOST=x86_64-apple-darwin

export MACOSX_DEPLOYMENT_TARGET=11.0
export CC="clang -arch x86_64"
export CXX="clang++ -arch x86_64"
export CFLAGS="-O2"
export CPPFLAGS="-I$DEPS/include"
export LDFLAGS="-L$DEPS/lib -Wl,-headerpad_max_install_names"
export PKG_CONFIG_LIBDIR="$DEPS/lib/pkgconfig"
export LIBTOOLIZE=glibtoolize
export PATH="/opt/homebrew/opt/bison/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"

mkdir -p "$DEPS" "$WORK"

# name, source directory, more configure arguments
build_autotools() {
  local name=$1 src=$2; shift 2
  print "==> $name"
  rm -rf "$WORK/$name"; mkdir -p "$WORK/$name"; cd "$WORK/$name"
  "$src/configure" --prefix="$DEPS" --host=$HOST --disable-static --enable-shared "$@" \
    > configure.log 2>&1 || { tail -40 configure.log; exit 1; }
  make -j$JOBS > make.log 2>&1 || { tail -60 make.log; exit 1; }
  make install > install.log 2>&1 || { tail -40 install.log; exit 1; }
}

[[ -e "$DEPS/lib/libgmp.dylib" ]] || build_autotools gmp "$SRC/gnutls/gmp" --disable-assembly --disable-cxx

# CodeWeavers' package lacks nettle's Makefile.in; scripts/fetch-sources.sh unpacks the same
# version 3.10 from the GNU release into downloads/nettle/x.
[[ -e "$DEPS/lib/libnettle.dylib" ]] || build_autotools nettle "$ROOT/downloads/nettle/x/nettle-3.10" \
  --disable-assembler --disable-documentation --disable-openssl \
  --with-include-path="$DEPS/include" --with-lib-path="$DEPS/lib"

[[ -e "$DEPS/lib/libgnutls.dylib" ]] || build_autotools gnutls "$SRC/gnutls/gnutls" \
  --with-included-libtasn1 --with-included-unistring \
  --without-p11-kit --without-idn --without-brotli --without-zstd \
  --without-tpm --without-tpm2 --disable-doc --disable-manpages --disable-tools \
  --disable-cxx --disable-tests --disable-guile --disable-nls --disable-libdane \
  --disable-hardware-acceleration --disable-gost \
  NETTLE_CFLAGS="-I$DEPS/include" NETTLE_LIBS=-lnettle \
  HOGWEED_CFLAGS="-I$DEPS/include" HOGWEED_LIBS=-lhogweed \
  GMP_CFLAGS="-I$DEPS/include" GMP_LIBS=-lgmp

# freetype comes without a generated builds/unix/configure and without the dlg submodule (only
# for FT_DEBUG_LOGGING); empty placeholders are enough for the copy step.
for f in include/dlg/output.h include/dlg/dlg.h src/dlg/dlg.c; do
  [[ -e "$SRC/freetype/subprojects/dlg/$f" ]] || { mkdir -p "$SRC/freetype/subprojects/dlg/${f:h}"; : > "$SRC/freetype/subprojects/dlg/$f"; }
done
( cd "$SRC/freetype" && [[ -x builds/unix/configure ]] || sh autogen.sh > /dev/null )
[[ -e "$DEPS/lib/libfreetype.dylib" ]] || build_autotools freetype "$SRC/freetype" \
  --without-harfbuzz --without-png --without-brotli --without-bzip2 --with-zlib=yes

print "==> done"
file "$DEPS"/lib/*.dylib(.)
