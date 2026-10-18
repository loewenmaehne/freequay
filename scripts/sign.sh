#!/bin/zsh
# Signs Freequay.app and every Mach-O file inside it, from the inside out, with the hardened runtime
# and the entitlements Wine needs (app/Freequay.entitlements). Without an identity the signature is ad
# hoc, as in the releases so far; with a Developer ID the same call signs for Apple's notarization,
# which then only needs `xcrun notarytool submit` and `xcrun stapler staple` (Apple's developer program).
# Usage: sign.sh <Freequay.app> [identity]
set -euo pipefail

ROOT=${0:A:h:h}
APP=${${1:?path to Freequay.app missing}:A}
ID=${2:--}
opts=(--force --options runtime --entitlements "$ROOT/app/Freequay.entitlements" --sign "$ID")
[[ $ID == - ]] || opts+=(--timestamp)

xattr -cr "$APP"  # codesign refuses Finder information and similar detritus
# Mach-O files by their first bytes: thin 64 and 32 bit, and universal
macho=()
for f in "$APP"/Contents/**/*(.N); do
  [[ $f == $APP/Contents/MacOS/${APP:t:r} ]] && continue
  case $(od -An -tx1 -N4 "$f" | tr -d ' \n') in
    cffaedfe|cefaedfe|cafebabe|cafebabf) macho+=("$f") ;;
  esac
done
# deepest first, so that every folder is signed before what contains it
for f in ${(On)macho}; do codesign $opts "$f" 2> /dev/null; done
codesign $opts "$APP"
codesign --verify --deep --strict "$APP"
print "signed ${#macho} files and ${APP:t} (${ID})"
