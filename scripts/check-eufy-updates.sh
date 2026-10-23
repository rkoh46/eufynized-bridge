#!/bin/bash
# Keep Eufynized current with the official eufy app and the reference libraries.
#
#   scripts/check-eufy-updates.sh [--app PATH] [--skip-upstream] [--force]
#
# 1. Finds the installed official app ("Anker eufy", com.security.BatteryCam;
#    on Apple-silicon Macs it is the iOS app under /Applications/BatteryCam.app).
# 2. Builds a static inventory of it (strings, ObjC symbols, plists, bundled
#    JSON and React Native Hermes string tables) into docs/eufy-baselines/<version>/.
#    Static inspection only: nothing is run, hooked or decrypted, and key
#    material is stored as fingerprints, never values.
# 3. Diffs it against the previous baseline.
# 4. Checks github.com/mega-yfue/eufy-sdk and github.com/bropat/eufy-security-client
#    for releases/commits relevant to Eufynized (needs a signed-in `gh`).
# 5. Writes docs/eufy-baselines/LATEST.md with the combined summary.
#
# An existing baseline for the same version is left alone unless --force.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BASE="$ROOT/docs/eufy-baselines"
APP=""
SKIP_UPSTREAM=0
FORCE=0
while [ $# -gt 0 ]; do
  case "$1" in
    --app) APP="$2"; shift 2 ;;
    --skip-upstream) SKIP_UPSTREAM=1; shift ;;
    --force) FORCE=1; shift ;;
    -h|--help) sed -n '2,18p' "$0"; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done

find_app() {
  local c
  for c in /Applications/BatteryCam.app ~/Applications/BatteryCam.app \
           "/Applications/Anker eufy.app" "/Applications/eufy Security.app"; do
    if [ -f "$c/Wrapper/BatteryCam.app/Info.plist" ]; then echo "$c/Wrapper/BatteryCam.app"; return; fi
    if [ -d "$c/Wrapper" ]; then
      local inner; inner=$(find "$c/Wrapper" -maxdepth 1 -name '*.app' | head -1)
      [ -n "$inner" ] && { echo "$inner"; return; }
    fi
    if [ -f "$c/Info.plist" ]; then echo "$c"; return; fi
  done
  # Fall back to Spotlight by bundle id (read-only metadata query).
  c=$(mdfind "kMDItemCFBundleIdentifier == 'com.security.BatteryCam'" 2>/dev/null | head -1)
  if [ -n "$c" ]; then
    if [ -d "$c/Wrapper" ]; then find "$c/Wrapper" -maxdepth 1 -name '*.app' | head -1; else echo "$c"; fi
  fi
}

[ -n "$APP" ] || APP="$(find_app)"
if [ -z "$APP" ] || [ ! -f "$APP/Info.plist" ]; then
  echo "Official eufy app not found. Install \"Anker eufy\" from the App Store or pass --app." >&2
  exit 1
fi

VERSION=$(plutil -extract CFBundleShortVersionString raw "$APP/Info.plist")
BUILD=$(plutil -extract CFBundleVersion raw "$APP/Info.plist")
BUNDLE=$(plutil -extract CFBundleIdentifier raw "$APP/Info.plist")
echo "Official app: $BUNDLE $VERSION ($BUILD) at $APP"

mkdir -p "$BASE"
OUT="$BASE/$VERSION"
PREV=$(ls -1 "$BASE" | grep -E '^[0-9]+(\.[0-9]+)+$' | grep -vx "$VERSION" | sort -t. -k1,1n -k2,2n -k3,3n -k4,4n | tail -1 || true)

NEW_VERSION=0
if [ -d "$OUT" ] && [ "$FORCE" = 0 ]; then
  echo "Baseline for $VERSION already exists; no new official version (use --force to rebuild)."
else
  NEW_VERSION=1
  TMP=$(mktemp -d)
  trap 'rm -rf "$TMP"' EXIT
  python3 -I -B "$ROOT/scripts/eufy_inventory.py" "$APP" "$TMP/inv" >/dev/null
  rm -rf "$OUT"; mv "$TMP/inv" "$OUT"
  echo "Wrote baseline $OUT"
fi

UPSTREAM_MD="$BASE/upstream-report.md"
if [ "$SKIP_UPSTREAM" = 0 ]; then
  echo "Checking upstream libraries…"
  python3 -I -B "$ROOT/scripts/eufy_upstream.py" "$BASE/upstream" "$UPSTREAM_MD" >/dev/null
fi

if [ -n "$PREV" ] && [ "$NEW_VERSION" = 1 ]; then PREV_ARG="$BASE/$PREV"; else PREV_ARG="-"; fi
SUMMARY=$(python3 -I -B "$ROOT/scripts/eufy_compare.py" "$OUT" "$PREV_ARG" "$BASE/upstream" "$ROOT/Sources")

{
  echo "# eufy update check — $(date -u +%Y-%m-%d)"
  echo
  echo "Official app: \`$BUNDLE\` **$VERSION** (build $BUILD)."
  if [ "$NEW_VERSION" = 1 ]; then
    if [ -n "$PREV" ]; then echo "New baseline; previous was $PREV — see \`$VERSION/diff-from-$PREV.md\`."
    else echo "First baseline (nothing to diff against)."; fi
  else
    echo "No new official version since the last check."
  fi
  echo
  echo "$SUMMARY"
  echo
  if [ -f "$UPSTREAM_MD" ]; then sed 's/^## /### /; 1s/^# /## /' "$UPSTREAM_MD"; fi
  echo
  echo "Triage: docs/eufy-update-tracking.md explains what to look for."
} > "$BASE/LATEST.md"

echo
cat "$BASE/LATEST.md"
