#!/bin/bash
# Installs (or removes) the daily Eufynized watchdog as a user LaunchAgent.
#
#   scripts/install-watchdog.sh [--branch main] [--hour 11] [--minute 0]
#   scripts/install-watchdog.sh --uninstall
#
# It keeps its own clone of the repo in ~/Library/Application Support/Eufynized/watchdog/repo, so it
# tests what is on GitHub (the branch you pick) and never touches a checkout you work in. launchd runs it
# once a day (and catches up after sleep); results go to .../watchdog/LATEST.md with a notification
# when something broke or changed. Run once by hand: launchctl kickstart gui/$(id -u)/<label>
set -euo pipefail

LABEL=io.github.rkoh46.eufynized-watchdog
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
STATE="$HOME/Library/Application Support/Eufynized/watchdog"
CLONE="$STATE/repo"
REMOTE=$(git -C "$(dirname "$0")/.." remote get-url origin 2>/dev/null || echo https://github.com/rkoh46/Eufynized.git)
BRANCH=main; HOUR=11; MINUTE=0

if [ "${1:-}" = --uninstall ]; then
  launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
  rm -f "$PLIST"
  echo "Watchdog removed (its clone and reports stay in $STATE)."
  exit 0
fi
while [ $# -gt 0 ]; do
  case "$1" in
    --branch) BRANCH="$2"; shift 2 ;; --hour) HOUR="$2"; shift 2 ;; --minute) MINUTE="$2"; shift 2 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done

mkdir -p "$STATE"
if [ -d "$CLONE/.git" ]; then
  git -C "$CLONE" fetch -q origin "$BRANCH"
  git -C "$CLONE" checkout -q -B "$BRANCH" "origin/$BRANCH"
else
  git clone -q --branch "$BRANCH" "$REMOTE" "$CLONE"
fi
touch "$CLONE/.eufynized-watchdog-clone"
[ -x "$CLONE/scripts/eufy-watchdog.sh" ] || { echo "branch $BRANCH has no scripts/eufy-watchdog.sh yet" >&2; exit 1; }

mkdir -p "$(dirname "$PLIST")"
cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key>
  <array><string>/bin/bash</string><string>$CLONE/scripts/eufy-watchdog.sh</string></array>
  <key>EnvironmentVariables</key>
  <dict>
    <key>EUFY_WATCHDOG_BRANCH</key><string>$BRANCH</string>
    <key>PATH</key><string>/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin</string>
  </dict>
  <key>StartCalendarInterval</key>
  <dict><key>Hour</key><integer>$HOUR</integer><key>Minute</key><integer>$MINUTE</integer></dict>
  <key>LowPriorityIO</key><true/>
  <key>Nice</key><integer>10</integer>
  <key>StandardOutPath</key><string>$STATE/launchd.log</string>
  <key>StandardErrorPath</key><string>$STATE/launchd.log</string>
</dict>
</plist>
EOF
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$PLIST"
printf 'Watchdog installed: daily at %02d:%02d, testing %s.\nReports: %s/LATEST.md\n' "$HOUR" "$MINUTE" "$BRANCH" "$STATE"
