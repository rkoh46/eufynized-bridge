# Keeping Eufynized current with the official eufy app and firmware

Eufynized talks to the HomeBase directly, so it only learns about new protocol
features, device models and security changes if someone looks for them.
`scripts/check-eufy-updates.sh` does the looking:

1. It finds the installed official app. On this Mac that is the iOS app
   **"Anker eufy"**, bundle id `com.security.BatteryCam`, at
   `/Applications/BatteryCam.app`, version **6.1.11** (build 260929151932).
2. It builds a static inventory of the app into `docs/eufy-baselines/<version>/`.
3. It diffs that inventory against the previous baseline.
4. It checks [mega-yfue/eufy-sdk](https://github.com/mega-yfue/eufy-sdk) and
   [bropat/eufy-security-client](https://github.com/bropat/eufy-security-client)
   for new releases and commits that matter to Eufynized.
5. It writes a combined summary to `docs/eufy-baselines/LATEST.md`.

## Running it

```bash
scripts/check-eufy-updates.sh
```

- `--skip-upstream`: run without the network. The GitHub step needs a signed-in `gh`.
- `--force`: rebuild the baseline for a version that already has one. The output is deterministic, so a rebuild of an unchanged app gives no git diff.
- `--app PATH`: inspect a different copy of the app, for example an older one kept for comparison.

A full run takes about a minute (about 10 s without the upstream step). When it
finishes:

- Read `LATEST.md` first.
- If the official app version changed, read `<version>/diff-from-<previous>.md`.
- Commit the new baseline and `upstream/` state, so the next run diffs against them.

After the App Store updates the eufy app, run the script and commit the new
baseline before the old app version is gone. A version without a baseline cannot
be diffed later.

### What it inspects (static only)

The script never runs, attaches to, hooks or decrypts the app, and it never
reads the Keychain. The main `BatteryCam` executable is FairPlay-encrypted
(`cryptid 1`), so the script does not read it. All 237 frameworks and the React
Native bundles are unencrypted, and the P2P code lives in those.

| File | Source | Contents |
|---|---|---|
| `app.txt` | Info.plist | Version, build, minimum iOS, encryption flag, background modes |
| `frameworks.txt` | each framework | Name, version and SHA-256 prefix. Shows *which component* changed, e.g. `BC_P2PClient 0.0.8`, `ThingP2PSDK 3.9.2`, `BC_WebRTC 0.0.8` |
| `p2p-commands.txt` | strings in frameworks and Hermes bundles | `CMD_*` / `APP_CMD_*` names, with where each was seen |
| `sub-commands.txt` | same | `COMMAND_*` sub-commands that ride inside the 1700/1350 wrappers (PTZ presets, zoom, calibration…) |
| `api-paths.txt`, `hosts.txt` | same | Cloud API paths (`v1/…`, `app/…`, `passport/…`) and eufy/Anker/Thing hosts |
| `models.txt`, `device-types.txt` | strings and bundled JSON | `T8xxx` model codes, `device_type`→model mapping, serial-prefix mapping |
| `device-features.txt` | `security_device_configuration.json`, `device_configuration.json` | Per-model capability flags and **feature gates by station firmware** (e.g. `T8030 >=4.2.0.5 playback_command …`) |
| `remote-config.txt` | `RemoteConfigDefaults.plist` | Bundled Firebase remote-config defaults: feature flags and version gates |
| `crypto.txt` | P2P/media/crypto frameworks | Crypto-related strings. Certificates, PPCS init strings and key-like constants are stored **only as length + SHA-256 prefix**, never their values |
| `objc-classes.txt`, `objc-selectors.txt` | `nm` / `otool` | ObjC class and selector names of the eufy frameworks. New classes or selectors are a good early sign of new features |
| `rn-bundles.txt` | `RN_*.zip` | Each React Native module, its Hermes bytecode version and a fingerprint |
| `coverage.txt` | generated | One row per P2P command name: id (from the libraries), and whether the official app, eufy-sdk, bropat and Eufynized each know it |

Helpers, all in `scripts/`:

- `eufy_inventory.py` builds the inventory.
- `hbc_strings.py` reads Hermes bytecode string tables (versions 84–99).
- `eufy_compare.py` produces the diff and `coverage.txt`.
- `eufy_upstream.py` does the GitHub check. Its state is stored in `docs/eufy-baselines/upstream/state.json`, with snapshots of each library's `CommandType` and `DeviceType` enums for diffing.

### Limits

- **Command numbers are not in the official app's strings.** The iOS frameworks
  carry command *names*. The name→number table sits in the encrypted main binary
  or inside Hermes bytecode as literals. The ids in `coverage.txt` come from
  eufy-sdk and bropat; 362 official names have no known id in either.
- `RemoteConfigDefaults.plist` holds *defaults*. Firebase can override them at
  runtime, so treat them as "what the app ships with", not as what is live.
- The upstream check lists the latest 80 commits per branch on the first run.
  Later runs are incremental from the stored commit.
- Eufynized "uses" a command when its id appears as a command constant in
  `Sources/EufyKit`. This is a heuristic, good enough for a coverage table.

### Triage checklist for a new official version

1. Read `frameworks.txt`. If the versions of `BC_P2PClient`, `BC_Security`, `BCMega_Player`, `BC_VideoSDK`, `ThingP2PSDK` or `BC_WebRTC` changed, protocol work happened.
2. Read `p2p-commands.txt` and `sub-commands.txt`. New names show what the HomeBase and cameras can now do.
3. In `device-features.txt`, grep for `T8030` and our camera models. New firmware-gated features are listed per HomeBase firmware version.
4. In `remote-config.txt`, look for new `force_*`, `*_need_auth_*`, `*webrtc*` and `*thing*` flags.
5. In `crypto.txt`, check for new or removed fingerprints, certificates or crypto strings.
6. For anything new, check whether eufy-sdk already decoded it (search its `beta-*` branch), then decide whether to adopt it.

## Surviving firmware updates: the watchdog

The baselines above tell us what the *official app* changed. Firmware is the bigger risk: Eufy pushes
HomeBase and camera updates silently, and Eufynized only finds out when something stops working. The
watchdog finds out first.

**`eufynized-health`** (`swift run eufynized-health [--quick] [--cloud]`) walks every stage of the direct
path against the real HomeBase and fails loudly at the stage that broke:

| Stage | Passes when |
|---|---|
| secrets | the station key and session are in `secrets.json` (checked file-only: it never touches the Keychain, so it can't prompt) |
| cloud device list (`--cloud`) | the device list loads; records every device's firmware (`main_sw_version`/`sec_sw_version`) and fails if a camera's channel moved |
| discovery | the HomeBase answers the LAN lookup |
| camera chN … (one per camera) | gateway info (1100) answers, the **level-2 key** derives, video **decodes** through VideoToolbox, plus audio frame count and the settings (1103) report |

Level-2 is checked explicitly because the app silently falls back to level-1 when it fails, and level-1
shows the HomeBase's *active* camera — "video plays" would hide exactly the break we care about.

Each run's JSON report doubles as a **wire fingerprint**: firmware versions, codec, resolution, the set
of control frames (`command:signCode`), the settings types each camera reports. `scripts/eufy_health_compare.py`
diffs it with the last good run, so a firmware update that *changes* the protocol shows up the day it
lands, usually before anything visibly breaks.

**`scripts/eufy-watchdog.sh`** runs it all daily:

1. updates its own clone to the latest `origin/main` (it never touches a checkout you work in);
2. builds and runs the unit tests — catches our own regressions;
3. waits for any other `eufynized-*` probe to finish (the HomeBase drops overlapping sessions), then runs
   the health check: one indoor camera daily, every camera on Sundays and immediately after any
   firmware change;
4. compares with the last good run; notices a new official app version and (weekly) relevant upstream
   commits;
5. writes `~/Library/Application Support/Eufynized/watchdog/LATEST.md` and posts a notification when
   something broke or changed (and opens the report when broken).

Install it as a daily LaunchAgent with `scripts/install-watchdog.sh` (remove: `--uninstall`).

**Offline cameras are not breakage.** A camera that is unplugged, switched off or out of battery still
"connects" (the HomeBase answers for it) but sends nothing. Its HomeBase says so in the camera's own
settings report: param **1131** (State: 0 offline, 1 online, 2 turned off, 3 battery empty, 4/5 needs
re-adding), with Wi-Fi signal 1142 at -100 dBm. `CameraAvailability` (EufyKit) reads it, and
`EufyLiveStream` asks for it by itself when no video arrives within 5 s, so:

- the app shows "Kids Room: Offline — check that it's powered and on Wi-Fi" on the live screen, the
  Multi-View tile and the Cameras grid, instead of a black picture or a spinner;
- the health check reports the camera as offline (a change worth a notification) instead of failing the
  protocol check.

First live run (2026-10-21, HomeBase 3 firmware 3.8.7.4): six cameras pass — H.265 720p (S3 Pro ×2),
H.265 1080p (S340), H.264 1080p (2C, E30), H.265 2304×1296 (E30) — and the unplugged Kids Room E30
reads Offline. The official app's next HomeBase 3 gate is firmware **4.2.0.5** (Thing/WebRTC live
support for every camera); the watchdog calls it out by name when the HomeBase crosses it.

**When the watchdog fires:**

- *Firmware changed, still healthy* — read the changes in `LATEST.md`, compare with eufy-sdk's latest
  commits for that model, and add any new behaviour before it becomes required.
- *A stage failed* — the stage name says where: discovery (network/IP), gateway or level-2 (key
  exchange changed: re-run setup's cipher fetch first, then compare with `BC_P2PClient`'s
  `PPCS_ENC_EEC`/`APP_CMD_GET_ASEKEY` logic and eufy-sdk), decode (codec or frame layout: check
  `formatChanges`, `decryptFail`, and eufy-sdk's video fixes), channel moved (refresh cameras in the app).

---

## First report — 2026-10-21

**Baseline:** official app 6.1.11 (`docs/eufy-baselines/6.1.11/`). The
libraries were checked at eufy-sdk `main@7d1f016` (v0.4.0) and `beta-0.5.0`, and
bropat `master@3bfef13` (4.1.1).

**Our hardware:**

- HomeBase 3 (T8030)
- 3× Indoor Cam E30 (T8417, pan-tilt)
- SoloCam S340 (T8170, pan-tilt)
- eufyCam 2C (T8113)
- 2× eufyCam S3 Pro (T8162)

### Where things stand

| | Official app 6.1.11 | eufy-sdk (v0.4.0 + beta-0.5.0) | bropat 4.1.1 | Eufynized |
|---|---|---|---|---|
| P2P command names | 643 `CMD_*` + 95 `COMMAND_*` sub-commands | 545-entry `CommandType` with ids | 542-entry `CommandType` | 12 ids used |
| Live video (PPPP, level 1 + level 2) | yes | yes | yes | yes. Its 4 MiB `SO_RCVBUF` already matches eufy-sdk v0.4.0's fix |
| Talkback | yes | yes | yes | yes (1005/1301/1006, needs level-2) |
| PTZ | rotate, presets, cruise, calibration, motion-track, speed, digital zoom | rotate, presets, zoom, speed | rotate | rotate only (6030) |
| Events / recordings / download | yes | download from HomeBase 2 (v0.4.0) | yes | not yet (another session is working on this) |
| Stream quality / resolution | yes | yes | yes | hardcoded (another session is working on this) |
| Privacy mode / zones | yes | partial | partial | not yet (the main session is working on this) |
| WebRTC / Thing (Tuya) live path | yes, firmware-gated | yes, for doorbells and NVR (`src/transport/rtc`, beta) | no | no |
| Device types | 191 `device_type`→model rows, 436 model codes | 102 `DeviceType` | 96 | 20 model codes named |
| Maintenance | — | very active; most work lands on `beta-0.5.0` first (368 commits ahead of `main`) | **archived, with a deprecation notice in the README** | — |

bropat is archived, so eufy-sdk is now the only live reference. The script
still snapshots bropat's enums in case of a fork.

### Top gaps worth adopting next

Ranked by value for our own hardware. Each item gives its evidence and where it
lives.

1. **PTZ presets, calibration and speed** (E30 ×3, S340).

   *Evidence:*
   - The official sub-commands include:
     - `COMMAND_INDOOR_SPAN_CRUISE_POINT/QUERY/DELETE/PREVIEW`
     - `COMMAND_APP_SPAN_PTZ_PIC`
     - `COMMAND_INDOOR_PAN_CALIBRATION`
     - `COMMAND_INDOOR_PAN_SPEED`
     - `COMMAND_INDOOR_PAN_MOTION_TRACK`
     - `COMMAND_APP_SPAN_PANORAMIC_MAKE` (all in `6.1.11/sub-commands.txt`)
   - eufy-sdk `src/model/capabilities/ptz.ts` (beta) maps them to ids:
     - goto/save 6032, delete 6033, query 6034, preview 6035, thumbnail 6097, speed 6015 — all in the 1700 wrapper Eufynized already sends for 6030
     - set-default 1350 `{index, settingstate}`
     - zoom 6203
   - Eufynized has rotate only (`Sources/EufyKit/P2P/PTZ.swift`).

   *Cost:* small, because it reuses the working 1700 path. **Owner:** the main session (PTZ files).

2. **Event list, playback and clip download from the HomeBase 3.**

   *Evidence:*
   - `device-features.txt` shows `T8030 >=4.2.0.5 event_command / event_stop_command / playback_command` gated on for all four of our models (T8113, T8162, T8170, T8417).
   - The command ids are known in both libraries:
     - `CMD_DOWNLOAD_VIDEO` 1024, `CMD_RECORD_VIEW` 1025, `CMD_RECORD_PLAY_CTRL` 1026
     - `CMD_DOWNLOAD_CANCEL` 1051, `CMD_DOWNLOAD_FINISH` 1304
     - `CMD_GET_RECORD_TIME` 1104, `CMD_DATABASE` 1306
   - The official names `CMD_VIDEO_DOWNLOAD` and `CMD_MERGE_DOWNLOAD_STATUS` have no id yet.
   - `BC_P2PClient` decrypts 1306 replies with AES-GCM ("PPCS_ENC_EEC 1306 decrypt_data").
   - eufy-sdk v0.4.0 added `downloadRecording` (`src/transport/p2p/recording-download.ts`), verified on a HomeBase 2 only.

   **Owner:** the events/clips session.

3. **Live-stream robustness fixes from eufy-sdk.**

   - *Keyframe detection.* Unmerged branch `fix/keyframe-flag-0x40` (`ea43e0b`): when header bit 0 is clear, decide the keyframe from the Annex-B payload (IDR present). Some models never set bit 0. Eufynized uses `flags & 0x01` only (`Sources/EufyKit/P2P/VideoFrame.swift:25`).
   - *Late-datagram recovery and resync at keyframe.* `6bd87c4`: the reorder bound was measured at 700 ms, against Eufynized's 0.3 s hole timeout (`HomeBaseConnection.swift:103`).
   - *UDP close drain.* `b217089`: wait for the UDP send to complete before closing, so the 1004 stop actually goes out.

   **Owner:** the stream-quality session.

4. **Stream quality / resolution selection.**

   *Evidence:*
   - Command ids: `CMD_SET_RESOLUTION` 1205, `CMD_SET_RECORD_QUALITY` 1286.
   - Official names with no id: `CMD_MULTICAM_SET_VIDEO_QUALITY`, `COMMAND_INDOOR_OWNER_STREAM_TYPE`, `COMMAND_VIDEO_RECORD_QUALITY`.
   - Eufynized hardcodes `streamtype`/`video_type` (`HomeBaseConnection.swift:325-334`, `Level2.swift:30-33`).

   **Owner:** the stream-quality session.

5. **Do not fall back to plaintext on a HomeBase 3** (security).

   *Evidence:*
   - The official remote-config default `force_p2p_encrypt_device = T8030|T8171`: the app forces encrypted P2P for the HomeBase 3.
   - `hb_need_auth_on_live_stream_version = 2.0.9.7` also exists.
   - When level-2 fails, Eufynized silently retries with plain 1003 (`EufyLiveStream.swift:135-159`).

   *Suggestion:* make the plaintext fallback visible in the UI and log, or opt-in, so a level-2 regression doesn't quietly turn into an unencrypted stream. The data is LAN-only today, but it travels over the WARP tunnel when remote.

6. **Privacy mode and privacy zones.**

   *Evidence:*
   - Official names: `CMD_COMMAND_SETTING_PRIVACY_MODE`, `CMD_SET_PRIVACY_ZONE_SWITCH`, `CMD_GET_PRIVACY_MASK`, `CMD_PRIVACY_ZONES_STATUS`.
   - `CMD_SET_PRIVACYPARAM` has a known id (1295); the rest have none in either library.

   *Next step:* look these up on eufy-sdk `beta-*` first. **Owner:** the main session (privacy-zone files).

7. **Cloud identity is behind.**

   *Evidence:* Eufynized presents as Android `eufy_mega 6.0.41_26142` (`EufyCloudClient.swift:13-15`). The current official app is 6.1.11.

   This only matters for login, the device list and `get_ciphers`, and it works today. If the cloud starts enforcing a minimum version, bump `appVersion` to the current Android build. Check eufy-sdk `src/transport/http/passport.ts` for the value it sends.

### Watch items (no action yet)

- **The HomeBase 3 is gaining a WebRTC/Thing live path.**
  - `remote-config.txt`:
    - `homebase3_support_webrtc_version = 3.6.2.1`
    - `homebase3_support_rtc_cmd = 1000|1001|1002|1004`
  - `device-features.txt`: `T8030 >=4.2.0.5 live_support_thing` for every sub-camera.
  - The app ships `BC_WebRTC`, `ThingP2PSDK 3.9.2` and `ThingCameraSDK 4.21.51`.
  - However, `support_thing_player_pair` for `T8030` lists only T8110/T8115/T817L/T8172/T8215/T814X. None of our cameras is on it, so they stay on the PPPP path that Eufynized speaks (`support_player_live_v2_pn_list_v2` includes T8113, T8162, T8170 and T8417).
  - If a future version adds our models to that pair list, PPPP live may stop being the app's path. Watch for it in `remote-config.txt` diffs.
  - eufy-sdk's `src/transport/rtc/` (beta) is the reference if we ever need it.
- **Device-type drift.** The official app maps 191 `device_type` numbers, and 89 of them are missing from eufy-sdk's `DeviceType` (see `LATEST.md`). None of the missing ones are our models.
- **Key material fingerprints.** `crypto.txt` tracks these, so a rotation shows up as a diff:
  - the bundled certificates `cerficate_v2`, `cerficate_v3`, `cerficate_h2_local` and `h2.ca.der`
  - `useridPubKey.txt`
  - one PPCS init string in `BC_P2PClient`
  - 445 key-like constants
- **Level-2 key flow on the official side.** `BC_P2PClient` logs:
  - `APP_CMD_GET_ASEKEY` and `CMD_DEV_ECC_PUBKEY_REQ(_NOTI)` (no ids known)
  - a per-station `cipher_key_map` ("zx_p2p_add_cipher_key")
  - video frame header variants `I2/I3/I4/I8/V9`

  If our level-2 setup ever breaks after a HomeBase firmware update, these are the first names to chase.
