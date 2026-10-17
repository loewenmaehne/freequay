#!/bin/zsh
# Builds Freequay.app, the window that starts Windows programs without Terminal, from app/ into the
# root of the repository: the app looks for scripts/freequay next to itself. Needs swiftc from Xcode
# or the Command Line Tools; the compiler's module cache stays in build/app. Signed ad hoc.
# Usage: build-app.sh [version]
set -euo pipefail

ROOT=${0:A:h:h}
VERSION=${1:-0.0.0}
BUILD=$ROOT/build/app
APP=$ROOT/Freequay.app

rm -rf "$APP"
mkdir -p "$BUILD" "$APP/Contents/MacOS"
xcrun swiftc -O -parse-as-library -target arm64-apple-macos13.0 -module-cache-path "$BUILD/ModuleCache" \
  -o "$APP/Contents/MacOS/Freequay" "$ROOT/app/Freequay.swift"
sed "s/@VERSION@/$VERSION/" "$ROOT/app/Info.plist" > "$APP/Contents/Info.plist"
codesign --force --sign - "$APP"
print "built $APP $VERSION"
