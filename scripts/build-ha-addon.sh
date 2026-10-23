#!/bin/zsh
# Builds the bridge for Linux (arm64, same as the Raspberry Pi) in Docker and puts it in the add-on folder.
#   scripts/build-ha-addon.sh               build in Docker on this Mac
#   BUILD_HOST=user@pi scripts/build-ha-addon.sh
#                                           build in Docker on that host instead (no Docker VM needed on the Mac)
#   scripts/build-ha-addon.sh user@pi       build, then copy the add-on to the Pi's local add-ons folder
set -euo pipefail
cd "$(dirname "$0")/.."
compile='swift build -c release --static-swift-stdlib --scratch-path /build --product eufynized-bridge $JOBS >/dev/null \
   && strip -o /out/eufynized-bridge /build/release/eufynized-bridge'
if [[ -n "${BUILD_HOST:-}" ]]; then
  # Two cores at low priority, so it can't starve Home Assistant on the same Pi. (The Pi's kernel ignores Docker's
  # memory limit; two compile jobs stay well under the free memory.)
  ssh "$BUILD_HOST" 'mkdir -p eufynized-build/src eufynized-build/out'   # ours, before Docker would make them as root
  rsync -a --delete --include 'Package.*' --include 'Sources/***' --include 'Tests/***' --exclude '*' ./ "${BUILD_HOST}:eufynized-build/src/"
  ssh "$BUILD_HOST" "mkdir -p eufynized-build/out && cd eufynized-build && \
    sudo nice -n 15 docker run --rm --cpus 2 -v \$PWD/src:/src -v \$PWD/out:/out \
      -v eufynized-linux-build:/build -w /src -e JOBS='-j 2' swift:6.1-noble bash -c '$compile'"
  scp -q "${BUILD_HOST}:eufynized-build/out/eufynized-bridge" ha-addon/eufynized/eufynized-bridge
else
  docker run --rm -v "$PWD":/src -v "$PWD/ha-addon/eufynized":/out -v eufynized-linux-build:/build -w /src swift:6.1-noble \
    bash -c "$compile"
fi
ls -lh ha-addon/eufynized/eufynized-bridge
if [[ -n "${1:-}" ]]; then
  rsync -a --delete ha-addon/eufynized/ "$1:/tmp/eufynized-addon/"
  ssh "$1" 'sudo mkdir -p /var/lib/homeassistant/apps/local && sudo rsync -a --delete /tmp/eufynized-addon/ /var/lib/homeassistant/apps/local/eufynized/'
  echo "Copied to $1:/var/lib/homeassistant/apps/local/eufynized"
fi
