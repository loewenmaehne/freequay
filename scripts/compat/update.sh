#!/bin/zsh
# Downloads the open sources again and generates the rule files in compat/ from them: the
# ProtonDB export, AppleGamingWiki, umu-protonfixes, Proton's launcher script and DXVK's game
# profiles. The downloads go to downloads/compat/ (not versioned).
# Usage: update.sh [--offline]   (--offline: use the downloads that are there)
set -euo pipefail

ROOT=${0:A:h:h:h}
DL=$ROOT/downloads/compat
PY=(python3 -I)
WINETRICKS_VERSION=20260125
offline=0; [[ ${1:-} == --offline ]] && offline=1
mkdir -p "$DL"

if (( ! offline )); then
  print "==> winetricks $WINETRICKS_VERSION"
  [[ -f $DL/winetricks-$WINETRICKS_VERSION ]] ||
    curl -sfL -o "$DL/winetricks-$WINETRICKS_VERSION" \
      "https://raw.githubusercontent.com/Winetricks/winetricks/$WINETRICKS_VERSION/src/winetricks"

  print "==> umu-protonfixes"
  if [[ -d $DL/protonfixes/.git ]]; then git -C "$DL/protonfixes" pull -q --ff-only
  else rm -rf "$DL/protonfixes"; git clone -q --depth 1 https://github.com/Open-Wine-Components/umu-protonfixes.git "$DL/protonfixes"; fi

  print "==> Proton (experimental_11.0)"
  mkdir -p "$DL/proton"
  curl -sfL -o "$DL/proton/proton" https://raw.githubusercontent.com/ValveSoftware/Proton/experimental_11.0/proton
  gh api "repos/ValveSoftware/Proton/commits?sha=experimental_11.0&path=proton&per_page=1" \
    --jq '"experimental_11.0 " + .[0].sha[0:7] + " " + .[0].commit.committer.date[0:10]' > "$DL/proton/version"

  print "==> DXVK (master)"
  mkdir -p "$DL/dxvk"
  curl -sfL -o "$DL/dxvk/config.cpp" https://raw.githubusercontent.com/doitsujin/dxvk/master/src/util/config/config.cpp
  gh api "repos/doitsujin/dxvk/commits?path=src/util/config/config.cpp&per_page=1" \
    --jq '"master " + .[0].sha[0:7] + " " + .[0].commit.committer.date[0:10]' > "$DL/dxvk/version"

  print "==> ProtonDB-Export"
  mkdir -p "$DL/protondb"
  latest=$(gh api repos/bdefore/protondb-data/contents/reports --jq '.[] | select(.name | endswith(".tar.gz")) | .name' |
    python3 -I -c 'import sys, datetime
names = [l.strip() for l in sys.stdin if l.strip()]
def date(n):
    s = n[len("reports_"):-len(".tar.gz")]
    return datetime.datetime.strptime(s[:3] + s[3:].split("_")[0].zfill(2) + s.split("_")[1], "%b%d%Y")
print(max(names, key=date))')
  [[ -f $DL/protondb/$latest ]] || { rm -f "$DL"/protondb/reports_*.tar.gz
    curl -sfL -o "$DL/protondb/$latest" "https://github.com/bdefore/protondb-data/raw/master/reports/$latest"; }

  print "==> AppleGamingWiki"
  rm -rf "$DL/agw"
  "${PY[@]}" "$ROOT/scripts/compat/agw_fetch.py" "$DL/agw" | tail -1
  date +%Y-%m-%d > "$DL/agw/version"
fi

print "==> generating rules"
cd "$ROOT"
rm -f compat/notes.tsv compat/titles.tsv
# order: titles from ProtonDB (Steam names) come first
"${PY[@]}" scripts/compat/protondb.py "$(ls "$DL"/protondb/reports_*.tar.gz | tail -1)" "$(basename "$(ls "$DL"/protondb/reports_*.tar.gz | tail -1)" .tar.gz)"
"${PY[@]}" scripts/compat/applegamingwiki.py "$DL/agw" "$(cat "$DL/agw/version" 2>/dev/null || date +%Y-%m-%d)"
"${PY[@]}" scripts/compat/protonfixes.py "$DL/protonfixes" "$DL/winetricks-$WINETRICKS_VERSION"
"${PY[@]}" scripts/compat/proton.py "$DL/proton/proton" "$(cat "$DL/proton/version")"
"${PY[@]}" scripts/compat/dxvk.py "$DL/dxvk/config.cpp" "$ROOT/sources/dxvk" "$(cat "$DL/dxvk/version")"
