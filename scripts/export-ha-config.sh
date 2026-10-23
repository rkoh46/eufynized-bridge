#!/bin/zsh
# Writes the Home Assistant add-on's bridge.json from what the Mac app already knows: the HomeBase's IP and
# serial, the account id and the station's ECC key (from the app's secrets file), and the camera list.
# No Eufy password or cloud session leaves the Mac. Reads files only: no Keychain, no network.
#
#   scripts/export-ha-config.sh [out-file]            (default: ./bridge.json, mode 600)
#   scripts/export-ha-config.sh --install user@pi     (copies it into the add-on's data folder on the Pi)
# Without the Mac app, say what it would have known:
#   HOMEBASE_IP=192.168.1.50 STATION_SERIAL=T8030… EUFY_EMAIL=you@example.com scripts/export-ha-config.sh --install pi@<pi>
# (after `swift run eufynized-login <email>` and `swift run eufynized-cipher <email> <serial> <homebase-ip>`).
set -euo pipefail

domain=io.github.rkoh46.Eufynized
out=bridge.json
target=""
if [[ "${1:-}" == "--install" ]]; then target="$2"; out=$(mktemp -t bridge); else out="${1:-bridge.json}"; fi

ip=${HOMEBASE_IP:-$(defaults read $domain homeBaseIP 2>/dev/null || true)}
serial=${STATION_SERIAL:-$(defaults read $domain stationSerial 2>/dev/null || true)}
email=${EUFY_EMAIL:-$(defaults read $domain accountEmail 2>/dev/null || true)}
[[ -n "$ip" && -n "$serial" && -n "$email" ]] || { echo "need HOMEBASE_IP, STATION_SERIAL and EUFY_EMAIL (or the Mac app's settings)" >&2; exit 1; }

umask 077
python3 - "$ip" "$serial" "$email" "$out" <<'EOF'
import json, os, sys
ip, serial, email, out = sys.argv[1:5]
secrets = json.load(open(os.path.expanduser("~/Library/Application Support/Eufynized/secrets.json")))
session = json.loads(secrets[f"eufy-session:{email.lower()}"])
cameras = json.load(open(os.path.expanduser(f"~/Library/Caches/Eufynized/cameras-{email.lower()}.json")))
config = {
    "homeBaseIP": ip,
    "stationSerial": serial,
    "accountID": session["accountUserId"],
    "eccPrivateKeyHex": secrets[f"eufy-ecc:{serial.upper()}"],
    "cameras": cameras,
}
with open(out, "w") as f:
    json.dump(config, f, indent=2)
print(f"{len(cameras)} cameras → {out}")
EOF

if [[ -n "$target" ]]; then
  # The bridge runs as a Compose service; its /data is /opt/ha/eufynized/data on the host (install-ha.sh).
  dir=/opt/ha/eufynized/data/eufynized
  scp -q "$out" "$target:/tmp/eufynized-bridge.json"
  ssh "$target" "sudo mkdir -p $dir && sudo install -m 600 /tmp/eufynized-bridge.json $dir/bridge.json && rm /tmp/eufynized-bridge.json"
  rm -f "$out"
  echo "Installed on $target:$dir/bridge.json"
fi
