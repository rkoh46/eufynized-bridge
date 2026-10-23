#!/bin/zsh
# Installs (or updates) Eufynized on a Home Assistant that runs in Docker Compose (the Pi's /opt/ha):
#   - the bridge as the `eufynized` compose service (host network, data in /opt/ha/eufynized/data),
#   - the `eufynized` integration in custom_components (sidebar panel + events), enabled in configuration.yaml.
# Backs up docker-compose.yml and configuration.yaml before changing them. Restarts Home Assistant Core only
# when the integration changed.
#
#   scripts/install-ha.sh pi@192.168.1.60
set -euo pipefail
cd "$(dirname "$0")/.."
target=${1:?usage: install-ha.sh user@host}
stamp=$(date +%Y-%m-%d)

BUILD_HOST=${BUILD_HOST-$target} scripts/build-ha-addon.sh >/dev/null   # builds on the Pi; BUILD_HOST= builds on this Mac
echo "Bridge built."

rsync -a --delete --exclude config.yaml --exclude run.sh ha-addon/eufynized/ "$target:/tmp/eufynized-app/"
rsync -a --delete ha-integration/custom_components/eufynized/ "$target:/tmp/eufynized-integration/"

host=${target#*@}
lan_prefix=${host%.*}.   # 192.168.1.60 → 192.168.1.
ssh "$target" "STAMP=$stamp LAN_PREFIX=$lan_prefix bash -s" <<'EOS'
set -euo pipefail
sudo mkdir -p /opt/ha/eufynized/app /opt/ha/eufynized/data/eufynized
sudo rsync -a --delete /tmp/eufynized-app/ /opt/ha/eufynized/app/
# Standalone run script (no Supervisor): data in /data/eufynized, port 18099.
sudo tee /opt/ha/eufynized/app/run.sh >/dev/null <<'RUN'
#!/bin/sh
export EUFYNIZED_DATA_DIR=/data/eufynized EUFYNIZED_WWW=/app/www EUFYNIZED_PORT=18099
export GO2RTC_BIN=/usr/local/bin/go2rtc FFMPEG_BIN=/usr/bin/ffmpeg
exec /usr/local/bin/eufynized-bridge
RUN
sudo chmod +x /opt/ha/eufynized/app/run.sh

compose=/opt/ha/docker-compose.yml
if ! sudo grep -q '^  eufynized:' $compose; then
  sudo cp $compose $compose.bak-$STAMP-eufynized
  sudo tee -a $compose >/dev/null <<'YML'

  eufynized:
    container_name: eufynized
    build: /opt/ha/eufynized/app
    image: eufynized:local
    restart: unless-stopped
    network_mode: host
    volumes:
      - /opt/ha/eufynized/data:/data
    environment:
      - TZ=America/Los_Angeles
      - EUFYNIZED_ALLOW_FROM=$LAN_PREFIX   # the Mac app on the home network uses the bridge too
YML
  echo "Added the eufynized service to $compose (backup: $compose.bak-$STAMP-eufynized)."
fi
if ! grep -q "EUFYNIZED_ALLOW_FROM" $compose; then
  sudo cp $compose $compose.bak-$STAMP-allow-from
  sudo sed -i "/container_name: eufynized/,/^  [a-z]/ s|^      - TZ=America/Los_Angeles$|      - TZ=America/Los_Angeles\n      - EUFYNIZED_ALLOW_FROM=$LAN_PREFIX|" $compose
  echo "Bridge now accepts the home network ($LAN_PREFIX*)."
fi
cd /opt/ha && sudo docker compose up -d --build eufynized 2>&1 | tail -2

config=/opt/ha/config
changed=0
if ! sudo diff -rq -x __pycache__ /tmp/eufynized-integration $config/custom_components/eufynized >/dev/null 2>&1; then
  sudo rsync -a --delete --exclude __pycache__ /tmp/eufynized-integration/ $config/custom_components/eufynized/
  changed=1
fi
if ! sudo grep -q '^eufynized:' $config/configuration.yaml; then
  sudo cp $config/configuration.yaml $config/configuration.yaml.bak-$STAMP-eufynized
  printf '\n# Eufynized: Security Camera in the sidebar, HomeBase events as eufynized_event\neufynized:\n' | sudo tee -a $config/configuration.yaml >/dev/null
  echo "Enabled eufynized in configuration.yaml (backup: configuration.yaml.bak-$STAMP-eufynized)."
  changed=1
fi
if [ $changed = 1 ]; then
  sudo docker exec homeassistant python -m homeassistant --script check_config -c /config 2>&1 | grep -iE "error|invalid|eufynized" | head -5 || true
  sudo docker restart homeassistant >/dev/null && echo "Restarted Home Assistant Core."
fi
EOS
