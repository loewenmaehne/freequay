#!/bin/zsh
# Builds Freequay.app, the window that starts Windows programs without Terminal, from app/ into the
# root of the repository: the app looks for scripts/freequay next to itself. app/Icon.swift draws its
# icon, iconutil packs it. Needs swiftc from Xcode or the Command Line Tools; the compiler's module
# cache and the icon's images stay in build/app. Signed ad hoc.
# Usage: build-app.sh [version]
set -euo pipefail

ROOT=${0:A:h:h}
VERSION=${1:-0.0.0}
BUILD=$ROOT/build/app
APP=$ROOT/Freequay.app

rm -rf "$APP" "$BUILD/Freequay.iconset"
mkdir -p "$BUILD" "$APP/Contents/MacOS" "$APP/Contents/Resources"
xcrun swiftc -O -parse-as-library -target arm64-apple-macos13.0 -module-cache-path "$BUILD/ModuleCache" \
  -o "$APP/Contents/MacOS/Freequay" "$ROOT/app/Freequay.swift"
xcrun swiftc -O -module-cache-path "$BUILD/ModuleCache" -o "$BUILD/icon" "$ROOT/app/Icon.swift"
"$BUILD/icon" "$BUILD/Freequay.iconset"
iconutil -c icns -o "$APP/Contents/Resources/Freequay.icns" "$BUILD/Freequay.iconset"
sed "s/@VERSION@/$VERSION/" "$ROOT/app/Info.plist" > "$APP/Contents/Info.plist"
codesign --force --sign - "$APP"
print "built $APP $VERSION"
