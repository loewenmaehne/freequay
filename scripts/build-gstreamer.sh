#!/bin/zsh
# Builds GStreamer for winegstreamer, through which Wine plays the videos and sounds of Windows
# programs (Media Foundation, DirectShow): GLib 2.78.0 and GStreamer 1.24.4 from the CrossOver
# 26.3.0 sources, x86_64 for macOS 11 like Wine, into deps/. GLib needs pcre2 and a libintl, which
# CodeWeavers' package lacks: scripts/fetch-sources.sh downloads pcre2 10.42 and proxy-libintl 0.4,
# the versions GLib's own wraps name, and both are linked into GLib. libffi comes with macOS.
# Plugins: only what decodes without FFmpeg and without GPL code. The containers MP4, AVI, Matroska
# and WebM, MPEG program streams, FLV and WAV; H.264, H.265, MPEG-2, Motion JPEG and ProRes are
# decoded by Apple's VideoToolbox (vtdec from applemedia), AAC and MP3 by AudioToolbox (atdec).
# Nothing from gst-plugins-ugly and gst-libav, no x264, no codec with an open patent question.
# Usage: build-gstreamer.sh [clean]   clean builds everything again
set -euo pipefail

ROOT=${0:A:h:h}
SRC=$ROOT/sources
GST=$SRC/gstreamer/subprojects
DEPS=$ROOT/deps
WORK=$ROOT/build/gstreamer
VENV=$ROOT/tools/meson/venv
MESON=$VENV/bin/meson
PCRE2=$ROOT/downloads/pcre2/x/pcre2-10.42
JOBS=8

export MACOSX_DEPLOYMENT_TARGET=11.0
# Homebrew's bison: GStreamer's parser needs 2.4 or newer, macOS has 2.3
export PATH="/opt/homebrew/opt/bison/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"
unset CFLAGS CXXFLAGS OBJCFLAGS LDFLAGS PKG_CONFIG_PATH

for f in $GST/gstreamer $GST/gst-plugins-bad $SRC/glib/subprojects/proxy-libintl $PCRE2; do
  [[ -e $f ]] || { print -u2 "missing $f, run scripts/fetch-sources.sh"; exit 1; }
done
# meson from PyPI in its own venv, as in scripts/build-dxvk.sh, which runs later
if [[ ! -x $MESON ]]; then
  python3 -c 'import sys; sys.exit(sys.version_info < (3, 10))' ||
    { print -u2 "need Python 3.10 or newer as python3 (brew install python)"; exit 1; }
  python3 -m venv "$VENV"
  "$VENV/bin/pip" install --quiet meson==1.12.1
fi
[[ ${1:-} != clean ]] || rm -rf "$WORK"
mkdir -p "$WORK" "$DEPS/lib/pkgconfig"

# meson runs on Homebrew's arm64 Python, so the x86_64 build is a cross build; Rosetta runs its
# test programs and GLib's tools, hence no exe wrapper
CROSS=$WORK/x86_64-darwin.txt
min=-mmacosx-version-min=11.0
cat > "$CROSS" <<EOF
[binaries]
c = ['clang', '-arch', 'x86_64']
cpp = ['clang++', '-arch', 'x86_64']
objc = ['clang', '-arch', 'x86_64']
objcpp = ['clang++', '-arch', 'x86_64']
ar = 'ar'
strip = 'strip'
pkg-config = 'pkg-config'
glib-mkenums = '$DEPS/bin/glib-mkenums'
glib-genmarshal = '$DEPS/bin/glib-genmarshal'
glib-compile-resources = '$DEPS/bin/glib-compile-resources'
gdbus-codegen = '$DEPS/bin/gdbus-codegen'

[built-in options]
c_args = ['$min']
cpp_args = ['$min']
objc_args = ['$min']
objcpp_args = ['$min']
c_link_args = ['$min', '-Wl,-headerpad_max_install_names']
cpp_link_args = ['$min', '-Wl,-headerpad_max_install_names']
objc_link_args = ['$min', '-Wl,-headerpad_max_install_names']
objcpp_link_args = ['$min', '-Wl,-headerpad_max_install_names']

[properties]
needs_exe_wrapper = false
pkg_config_libdir = '$DEPS/lib/pkgconfig'

[host_machine]
system = 'darwin'
subsystem = 'macos'
kernel = 'xnu'
cpu_family = 'x86_64'
cpu = 'x86_64'
endian = 'little'
EOF

# name, source directory, meson options
build_meson() {
  local name=$1 src=$2; shift 2
  [[ ! -f $WORK/$name/.installed ]] || { print "==> $name is built"; return; }
  print "==> $name ($(date +%H:%M))"
  rm -rf "$WORK/$name"
  "$MESON" setup --cross-file "$CROSS" --prefix "$DEPS" --libdir lib --buildtype release \
    --wrap-mode nodownload "$@" "$WORK/$name" "$src" > "$WORK/$name.setup.log" 2>&1 ||
    { tail -40 "$WORK/$name.setup.log"; exit 1; }
  ninja -C "$WORK/$name" -j $JOBS > "$WORK/$name.ninja.log" 2>&1 ||
    { grep -nE 'error' "$WORK/$name.ninja.log" | head -20; tail -20 "$WORK/$name.ninja.log"; exit 1; }
  ninja -C "$WORK/$name" install > "$WORK/$name.install.log" 2>&1 || { tail -20 "$WORK/$name.install.log"; exit 1; }
  touch "$WORK/$name/.installed"
}

# pcre2 for GRegex, 8-bit only and static, so that it ends up inside libglib
if [[ ! -e $DEPS/lib/libpcre2-8.a ]]; then
  print "==> pcre2"
  rm -rf "$WORK/pcre2"; mkdir -p "$WORK/pcre2"; cd "$WORK/pcre2"
  "$PCRE2/configure" --prefix="$DEPS" --host=x86_64-apple-darwin --enable-static --disable-shared \
    --enable-pcre2-8 --disable-pcre2-16 --disable-pcre2-32 --disable-pcre2grep-libz --disable-pcre2grep-libbz2 \
    CC="clang -arch x86_64" CFLAGS="-O2 $min" > configure.log 2>&1 || { tail -40 configure.log; exit 1; }
  make -j$JOBS > make.log 2>&1 || { tail -40 make.log; exit 1; }
  make install > install.log 2>&1 || { tail -20 install.log; exit 1; }
fi

# libffi from macOS: the SDK has its headers in usr/include/ffi, the library is /usr/lib/libffi.dylib
sdk=$(xcrun --sdk macosx --show-sdk-path)
cat > "$DEPS/lib/pkgconfig/libffi.pc" <<EOF
Name: libffi
Description: libffi of macOS
Version: 3.4.0
Cflags: -I$sdk/usr/include/ffi
Libs: -lffi
EOF

# proxy-libintl in place of gettext's libintl: GLib then shows its messages untranslated
build_meson glib "$SRC/glib" -Dproxy-libintl:default_library=static \
  -Dtests=false -Dinstalled_tests=false -Dnls=disabled -Dman=false -Dgtk_doc=false -Ddtrace=false \
  -Dsystemtap=false -Dsysprof=disabled -Dselinux=disabled -Dlibmount=disabled -Dlibelf=disabled \
  -Doss_fuzz=disabled

common=(-Dauto_features=disabled -Dtests=disabled -Dexamples=disabled -Dnls=disabled -Ddoc=disabled)
build_meson gstreamer "$GST/gstreamer" $common -Dintrospection=disabled -Dbenchmarks=disabled \
  -Dtools=enabled -Dptp-helper=disabled -Dlibunwind=disabled -Dlibdw=disabled -Dbash-completion=disabled \
  -Dcheck=disabled
build_meson gst-plugins-base "$GST/gst-plugins-base" $common -Dintrospection=disabled -Dorc=disabled \
  -Dtools=enabled -Dapp=enabled -Daudioconvert=enabled -Daudioresample=enabled -Dplayback=enabled \
  -Dtypefind=enabled -Dvideoconvertscale=enabled \
  -Dgl=enabled -Dgl_api=opengl -Dgl_platform=cgl -Dgl_winsys=cocoa
build_meson gst-plugins-good "$GST/gst-plugins-good" $common -Dorc=disabled -Dasm=disabled \
  -Disomp4=enabled -Daudioparsers=enabled -Davi=enabled -Dmatroska=enabled -Dflv=enabled \
  -Dwavparse=enabled -Did3demux=enabled -Dapetag=enabled -Ddeinterlace=enabled -Dvideofilter=enabled
# applemedia needs GStreamer's OpenGL library from base; gpl stays off
build_meson gst-plugins-bad "$GST/gst-plugins-bad" $common -Dintrospection=disabled -Dorc=disabled \
  -Dtools=disabled -Dgpl=disabled -Dgl=enabled -Dapplemedia=enabled -Dvideoparsers=enabled \
  -Dmpegdemux=enabled

print "==> done"
ls "$DEPS/lib/gstreamer-1.0"
