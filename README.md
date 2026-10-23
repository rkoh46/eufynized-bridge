# Eufynized bridge

Eufy cameras in Home Assistant straight from the HomeBase 3 over your own network: live video, recordings,
settings, detection sensors, alarm panel. No Eufy cloud in the video path, no RTSP, no go2rtc.

This is the free, open part of [Eufynized](https://github.com/rkoh46/Eufynized): a bridge that runs on a
Raspberry Pi (or any Linux box with Docker), a Home Assistant integration, the Swift library that speaks the
HomeBase's local P2P protocol, and the research behind it. The Mac and iPhone apps are separate.

## What you get

- **Home Assistant:** a "Security Camera" panel (live, Multi-View, events timeline with Photos-style scrubbing,
  pan-tilt, presets, panorama, quick replies, activity zones), `camera.*` entities, person / motion / pet /
  vehicle sensors, event images, an alarm panel for guard mode, switches and selects for every camera setting
  the eufy app offers (including Direct power and continuous recording on the S3 Pro), battery / signal /
  storage sensors, and an `eufynized_event` for automations.
- **Alerts:** health (offline, low battery, weak link, full drive) with hysteresis, loitering, a morning
  digest, quiet hours and per-camera windows, snooze. Push actions (View live / Snooze / False alarm).
- **One HomeBase session per camera**, shared by every screen in the house. The HomeBase only allows a few.

Tested with HomeBase 3, eufyCam S3 Pro, eufyCam 2C, SoloCam S340, Indoor Cam E30.

## How it works

```
Cameras ──► HomeBase 3 ──(local P2P)──► eufynized-bridge (Pi, port 18099) ──► Home Assistant
```

The HomeBase encrypts video with a key only Eufy's cloud hands out. `eufynized-login` fetches it once; after
that nothing talks to the cloud.

## Install

Needs: Docker Compose on the Pi, Home Assistant Core as a Compose service with its config in `/opt/ha/config`,
SSH with passwordless sudo, ffmpeg. A Mac with Swift (Xcode Command Line Tools) to run the one-time key step.

```bash
git clone https://github.com/rkoh46/eufynized-bridge.git && cd eufynized-bridge
swift run eufynized-login you@example.com        # signs in once (password + 2FA), stores the key locally
scripts/export-ha-config.sh --install pi@<pi>    # copies the key and camera list to the Pi
scripts/install-ha.sh pi@<pi>                    # builds on the Pi, installs the bridge + integration
```

Run `install-ha.sh` again for every update. It installs the `eufynized` Compose service and the integration,
and restarts Home Assistant only when needed.

Optional, in `configuration.yaml`:

```yaml
eufynized:
  entity_names:                            # keep entity ids from an old integration
    T8162T0000000001: backyard
  alarm_entity_name: eufy_home_base
  notify_service: mobile_app_your_phone    # phone pushes with buttons
```

On the Pi:

| Path | What |
|---|---|
| `/opt/ha/eufynized/app/` | bridge binary, web page, Dockerfile |
| `/opt/ha/eufynized/data/eufynized/bridge.json` | keys |
| `/opt/ha/eufynized/data/eufynized/prefs.json` | preferences (quality, snooze, presets, quiet hours) |
| `/opt/ha/config/custom_components/eufynized/` | integration |

Back up `bridge.json`. It holds the camera key, the one thing you can't get back without signing in again.

Running Home Assistant OS instead? `ha-addon/` is the add-on; the bridge binary is built by
`scripts/build-ha-addon.sh`.

## Good to know

- The HomeBase serves only a few sessions at once. Multi-View on several screens can exceed it.
- A Pi on Wi-Fi delivers video in clumps. Ethernet fixes it.
- Cameras start every stream at 720p and ramp up on their own.
- Direct power on the S3 Pro can't be read back; the bridge remembers what it last set.
- `EUFYNIZED_ALLOW_FROM=192.168.1.` (address prefixes) limits who may talk to the bridge. It has no login of
  its own, so keep it on the LAN or behind a private tunnel.

## Development

```bash
swift build
scripts/test.sh
swift run eufynized-fps <serial> <channel> <homebase-ip> <email>   # measure a direct stream
swift run eufynized-fps --bridge http://<pi>:18099 <channel>       # measure the bridge feed
swift run eufynized-probe …                                        # send a command (allow-listed, read-only)
```

Targets: `EufyKit` (the protocol: P2P transport, level-2 per-camera selection, settings catalog, recordings),
`EufynizedKit` (bridge client, live stream plumbing), `eufynized-bridge` (the HTTP/WebSocket server), and
small command-line tools for login, discovery, snapshots, PTZ, settings and health.

Protocol research (command tables, what the HomeBase sends, what was verified) is in
[`docs/homebase-research/`](docs/homebase-research/README.md).

## Disclaimer

Not affiliated with Anker or Eufy. "Eufy" is a trademark of Anker Innovations. Transport code is ported from
[eufy-sdk](https://github.com/mega-yfue/eufy-sdk) (Apache-2.0), informed by
[eufy-security-client](https://github.com/bropat/eufy-security-client) (MIT). No code or assets from Eufy's
apps. Firmware updates can change the protocol at any time.

## License

MIT
