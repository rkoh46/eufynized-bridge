#!/bin/sh
# The bridge keeps its files (bridge.json, prefs, snapshots) in the add-on's persistent /data volume.
export EUFYNIZED_DATA_DIR=/data/eufynized
export EUFYNIZED_WWW=/app/www
export GO2RTC_BIN=/usr/local/bin/go2rtc
export FFMPEG_BIN=/usr/bin/ffmpeg
export EUFYNIZED_PORT=18099
exec /usr/local/bin/eufynized-bridge
