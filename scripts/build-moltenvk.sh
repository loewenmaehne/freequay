#!/bin/zsh
# Builds CodeWeavers' MoltenVK from crossover-sources-26.3.0 (with the geometry shader emulation
# DXVK needs) and installs it as deps/lib/libMoltenVK.dylib. MoltenVK's own fetchDependencies
# fetches the other dependencies (cereal, Vulkan headers, glslang, Vulkan tools, Volk) with git
# from GitHub; CodeWeavers' SPIRV-Cross from the package stays in use.
set -euo pipefail

ROOT=${0:A:h:h}
SRC=$ROOT/sources/moltenvk
DEPS=$ROOT/deps/lib
LOGS=$ROOT/logs
export PATH="/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"
mkdir -p "$DEPS" "$LOGS"

cd "$SRC"
if [[ -d External/SPIRV-Cross && ! -L External/SPIRV-Cross ]]; then
  mv External/SPIRV-Cross External/SPIRV-Cross-cx
fi

# Xcode 27 no longer builds for macOS 10.15; patches/moltenvk-0001 raises the minimum to 12.0,
# this catches project files the patch does not know
grep -rlE "MACOSX_DEPLOYMENT_TARGET = 10\\.15;" --include=project.pbxproj . | grep -v /External/ |
  while read -r f; do sed -i "" "s/MACOSX_DEPLOYMENT_TARGET = 10\\.15;/MACOSX_DEPLOYMENT_TARGET = 12.0;/" "$f"; done

print "==> fetching and building dependencies ($(date +%H:%M))"
./fetchDependencies --macos --spirv-cross-root "$SRC/External/SPIRV-Cross-cx" \
  > "$LOGS/moltenvk-deps.log" 2>&1 || { tail -40 "$LOGS/moltenvk-deps.log"; exit 1; }

print "==> building MoltenVK ($(date +%H:%M))"
make macos > "$LOGS/moltenvk-build.log" 2>&1 || { grep -nE 'error:' "$LOGS/moltenvk-build.log" | head -20; tail -30 "$LOGS/moltenvk-build.log"; exit 1; }

LIB=$(find "$SRC/Package" -path '*dylib/macOS/libMoltenVK.dylib' | head -1)
[[ -f $LIB ]] || { print -u2 "libMoltenVK.dylib not found"; exit 1; }
lipo -info "$LIB"

cp "$LIB" "$DEPS/libMoltenVK.dylib"
install_name_tool -id "$DEPS/libMoltenVK.dylib" "$DEPS/libMoltenVK.dylib" 2>/dev/null
codesign --force --sign - "$DEPS/libMoltenVK.dylib"
print "==> done ($(date +%H:%M))"
