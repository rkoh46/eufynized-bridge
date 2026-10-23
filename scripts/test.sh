#!/bin/sh
# Runs the test suite. With only the Command Line Tools (no Xcode), SwiftPM sometimes fails to find
# swift-testing's macro plugin, so pass its folder explicitly when it exists.
set -eu
cd "$(dirname "$0")/.."
PLUGINS=/Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing
if [ -d "$PLUGINS" ]; then
    exec swift test -Xswiftc -plugin-path -Xswiftc "$PLUGINS" "$@"
fi
exec swift test "$@"
