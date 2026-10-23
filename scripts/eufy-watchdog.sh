#!/bin/bash
# Daily watchdog: catches the day a HomeBase/camera firmware update, an official-app update or one of
# our own changes breaks (or starts to change) the direct path, and tells you with a notification.
#
#   scripts/eufy-watchdog.sh [--full] [--no-update] [--no-notify]
#
# Each run:
#   1. (in the dedicated watchdog clone only) updates to the latest origin/<branch>;
#   2. builds and runs the unit tests, so a code change that breaks parsing or crypto is caught;
#   3. runs eufynized-health against the real HomeBase: discovery, P2P session, level-2 key, live video,
#      audio and settings from one indoor camera (all cameras on Sundays, after any firmware change, or
#      with --full), plus the cloud device list for firmware versions;
#   4. diffs that against the last good run (firmware versions, codec, resolution, control frames,
#      settings types) — see scripts/eufy_health_compare.py;
#   5. notices a new official eufy app version, and (weekly) new upstream library commits that matter.
# Results: ~/Library/Application Support/Eufynized/watchdog/LATEST.md (+ history/).
# It never reads the Keychain and never stops or restarts the Eufynized app.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
STATE="${EUFY_WATCHDOG_DIR:-$HOME/Library/Application Support/Eufynized/watchdog}"
BRANCH="${EUFY_WATCHDOG_BRANCH:-main}"
FULL=0; UPDATE=1; NOTIFY=1
for a in "$@"; do
  case "$a" in
    --full) FULL=1 ;; --no-update) UPDATE=0 ;; --no-notify) NOTIFY=0 ;;
    -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
    *) echo "unknown option: $a" >&2; exit 2 ;;
  esac
done
export PATH="/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin:$PATH"
mkdir -p "$STATE/history"
LOG="$STATE/last-run.log"
exec > >(tee "$LOG") 2>&1

notify() {
  [ "$NOTIFY" = 1 ] || return 0
  local msg="${1//\"/\'}"
  osascript -e "display notification \"$msg\" with title \"Eufynized watchdog\"" >/dev/null 2>&1 || true
}

# One run at a time.
if ! mkdir "$STATE/lock" 2>/dev/null; then
  if [ -n "$(find "$STATE/lock" -maxdepth 0 -mmin +120 2>/dev/null)" ]; then rm -rf "$STATE/lock"; mkdir "$STATE/lock"
  else echo "another watchdog run is in progress"; exit 0; fi
fi
trap 'rm -rf "$STATE/lock"' EXIT

STAMP=$(date +%Y-%m-%dT%H%M%S)
NEWS=()      # lines for the summary / notification
STATUS=ok    # ok | changed | broken

echo "== Eufynized watchdog $STAMP (repo $ROOT)"

# 1. Self-update, only inside the dedicated clone made by install-watchdog.sh (never a working checkout).
if [ "$UPDATE" = 1 ] && [ -f "$ROOT/.eufynized-watchdog-clone" ]; then
  # Tracking a feature branch: once it's merged into main (or deleted), follow main from then on.
  [ -f "$STATE/branch" ] && BRANCH=$(cat "$STATE/branch")
  if [ "$BRANCH" != main ] && git -C "$ROOT" fetch -q origin main 2>/dev/null; then
    if ! git -C "$ROOT" fetch -q origin "$BRANCH" 2>/dev/null ||
       git -C "$ROOT" merge-base --is-ancestor "origin/$BRANCH" origin/main 2>/dev/null; then
      echo "branch $BRANCH is merged or gone; following main from now on"
      BRANCH=main; echo main > "$STATE/branch"
    fi
  fi
  if git -C "$ROOT" fetch -q origin "$BRANCH" 2>/dev/null; then
    git -C "$ROOT" reset -q --hard "origin/$BRANCH" && echo "updated to $(git -C "$ROOT" log --oneline -1)"
  else
    echo "git fetch failed; testing the code already here"
  fi
fi
REV=$(git -C "$ROOT" log --oneline -1 2>/dev/null || echo unknown)

# 2. Build and unit tests.
cd "$ROOT"
if ! swift build -c release --product eufynized-health >"$STATE/build.log" 2>&1; then
  STATUS=broken; NEWS+=("build failed at $REV (see build.log)")
  tail -20 "$STATE/build.log"
else
  if ! scripts/test.sh >"$STATE/test.log" 2>&1; then
    STATUS=broken; NEWS+=("unit tests fail at $REV (see test.log)")
    grep -E 'error|failed|✘' "$STATE/test.log" | head -20
  else
    echo "unit tests pass"
  fi
fi
HEALTH="$ROOT/.build/release/eufynized-health"

# 3. Live health check, after any other Eufynized probe has finished (the HomeBase drops overlapping sessions).
PROBES='eufynized-(fps|l2snapshot|settings|connect|snapshot|ptz|cipher|discover|probe|params|health)( |$)'
for _ in $(seq 1 60); do pgrep -f "$PROBES" >/dev/null || break; sleep 15; done

LAST_GOOD="$STATE/last-good.json"
# The newest official-app baseline's firmware gates, so crossing one is called out by feature name.
FEATURES=$(ls -1d docs/eufy-baselines/[0-9]*/ 2>/dev/null | sort -t/ -k3 -V | tail -1)device-features.txt
GATES=(); [ -f "$FEATURES" ] && GATES=(--features "$FEATURES")
[ "$(date +%u)" = 7 ] && FULL=1
run_health() {   # $1 = output json, rest = extra args
  local out="$1"; shift
  [ -x "$HEALTH" ] || return 2
  "$HEALTH" --cloud --out "$out" "$@"
}
REPORT="$STATE/history/$STAMP.json"
if [ -x "$HEALTH" ]; then
  if [ "$FULL" = 1 ]; then run_health "$REPORT"; else run_health "$REPORT" --quick; fi
  HRC=$?
  if [ "$HRC" = 2 ]; then
    STATUS=broken; NEWS+=("health check could not run: Eufynized is not set up or signed in")
  elif [ -f "$REPORT" ]; then
    # A firmware change found by the quick run: test every camera right away.
    if [ "$FULL" = 0 ] && [ -f "$LAST_GOOD" ] && python3 -I -B scripts/eufy_health_compare.py "$REPORT" "$LAST_GOOD" "${GATES[@]+"${GATES[@]}"}" | grep -q ' firmware'; then
      echo "firmware changed — running the full check"
      sleep 5; run_health "$REPORT"
    fi
    if [ -f "$LAST_GOOD" ]; then CMP=$(python3 -I -B scripts/eufy_health_compare.py "$REPORT" "$LAST_GOOD" "${GATES[@]+"${GATES[@]}"}"); CRC=$?
    else CMP=$(python3 -I -B scripts/eufy_health_compare.py "$REPORT"); CRC=$?; fi
    echo "$CMP"
    case "$CRC" in
      0) cp "$REPORT" "$LAST_GOOD" ;;
      3) cp "$REPORT" "$LAST_GOOD"; [ "$STATUS" = ok ] && STATUS=changed
         NEWS+=("HomeBase/camera behaviour changed (still working) — see LATEST.md") ;;
      *) STATUS=broken; NEWS+=("live check FAILED: $(echo "$CMP" | grep -m1 '^- FAIL' | cut -c3-)") ;;
    esac
  fi
fi

# 4. Official app version (the baselines live in the repo; adding one is a deliberate, committed step).
APP_PLIST=/Applications/BatteryCam.app/Wrapper/BatteryCam.app/Info.plist
if [ -f "$APP_PLIST" ]; then
  OFFICIAL=$(plutil -extract CFBundleShortVersionString raw "$APP_PLIST" 2>/dev/null)
  if [ -n "$OFFICIAL" ] && [ ! -d "$ROOT/docs/eufy-baselines/$OFFICIAL" ]; then
    [ "$STATUS" = ok ] && STATUS=changed
    NEWS+=("official eufy app is now $OFFICIAL — run scripts/check-eufy-updates.sh in Eufynized and commit the baseline")
  fi
fi

# 5. Upstream libraries, weekly (Mondays), into watchdog-local state seeded from the repo's.
if [ "$(date +%u)" = 1 ] || [ "$FULL" = 1 ]; then
  [ -d "$STATE/upstream" ] || cp -R "$ROOT/docs/eufy-baselines/upstream" "$STATE/upstream" 2>/dev/null
  if python3 -I -B scripts/eufy_upstream.py "$STATE/upstream" "$STATE/upstream-report.md" >/dev/null 2>&1; then
    N=$(grep -o 'relevant to Eufynized: [0-9]*' "$STATE/upstream-report.md" | awk '{s+=$4} END {print s+0}')
    [ "$N" -gt 0 ] && NEWS+=("$N new upstream commits relevant to Eufynized — see upstream-report.md")
  else
    echo "upstream check skipped (gh unavailable)"
  fi
fi

# Summary.
{
  echo "# Eufynized watchdog — $(date '+%Y-%m-%d %H:%M')"
  echo
  echo "Status: **$STATUS** (code $REV)"
  echo
  for n in "${NEWS[@]+"${NEWS[@]}"}"; do echo "- $n"; done
  echo
  [ -n "${CMP:-}" ] && { echo "## Live check"; echo; echo "$CMP"; echo; }
  echo "Report: history/$STAMP.json · log: last-run.log"
} > "$STATE/LATEST.md"
ls -1t "$STATE/history"/*.json 2>/dev/null | tail -n +91 | xargs rm -f 2>/dev/null

echo; cat "$STATE/LATEST.md"
case "$STATUS" in
  broken)  notify "Something broke: ${NEWS[0]:-see LATEST.md}"; open "$STATE/LATEST.md" 2>/dev/null; exit 1 ;;
  changed) notify "${NEWS[0]:-Something changed — see LATEST.md}"; exit 0 ;;
  *)       [ "${#NEWS[@]}" -gt 0 ] && notify "${NEWS[0]}"; exit 0 ;;
esac
