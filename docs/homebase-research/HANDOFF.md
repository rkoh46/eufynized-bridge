# Handoff: reverse-engineering eufy / Anker for Eufynized

For whoever (or whatever model) picks this up next. Everything here was established between 2026-10-21 and
2026-10-26 with REA driving Ghidra on this Mac, then checked against a real HomeBase 3. Read this page, then the
pages it points to; the data files in `data/` are the raw results.

## 1. The goal

Eufynized talks to a eufy **HomeBase 3** over its local P2P protocol, with no eufy cloud except one sign-in to
fetch the camera key. The protocol is not documented. Two sources feed the work:

- **eufy-security-client** (open source, Node), the starting point: command numbers, framing, crypto.
- **The eufy Security iOS app**, decompiled: eufy's own command-name table, who sends what, payload shapes, and the
  messages the HomeBase pushes back. This is where everything the library doesn't know comes from.

Research produces three things: a command number (or SET_PAYLOAD inner `cmd`), the JSON or struct it takes, and a
verification on hardware. Only the third makes it real; see §6.

## 2. Ground rules (non-negotiable)

- **Never send** 1034 (reboot) or 1036 / 1037 (factory reset). `CameraSettingsCatalog.forbiddenCommands` in
  `Sources/EufyKit/Settings/CameraSettings.swift` blocks those three in code; treat anything named `DEVS_REBOOT`,
  `DEV_REBOOT`, `FAC_*`, `UNBIND`, `FORMAT`, `DELETE`, `BIND`, `MIGRATION`, `SET_WIFI_*` the same way.
- **Never toggle a camera's power** (the owner's standing instruction), and never test alarms, sirens or Away
  mode at night or without the owner's OK.
- **Read before write.** For a setting: read it, write one different value, read it back, restore the original.
- **The owner's cloud session is single-client.** Never reuse `eufy-session:*` from `secrets.json` on a second
  device or tool; eufy kicks the session and the apps sign themselves out. The P2P key (`eufy-ecc:*`) is fine to
  copy for tools.
- **Static analysis never touches the HomeBase.** Decompiling is free; sending is not. Use the allow-listed probe
  (§6) for the first contact with any new number.

## 3. The target

- **App:** eufy Security for iOS **6.1.11** (build 260929151932), installed on this Mac from the App Store as
  `/Applications/BatteryCam.app` (bundle `com.security.BatteryCam`). 237 frameworks.
- **Protocol binary:** `/Applications/BatteryCam.app/Wrapper/BatteryCam.app/Frameworks/BC_P2PClient.framework/BC_P2PClient`,
  arm64. SHA-256 `6c0dc09562f9cffa3ea4d62cd18f3e8cd7daa0d592fdd96c9f1e98e13980ecc0`. It holds the PPPP/CS2
  transport, `BCP2PClient` / `BCP2PSession` (every command builder) and the dispatcher for station messages.
- **Newer payload code:** `ESIotMegaKit`, `MegaMainFramework`, `MegaCommonFramework` build many SET_PAYLOAD (1350)
  inner commands as JSON. `BCPDTSecurity` holds screens such as the eufyCam power manager (that's where 6445 came from).
- **Hardware it was checked on:** HomeBase 3 (T8030), eufyCam S3 Pro ×2 (T8162), SoloCam S340 (T8170, pan-tilt,
  dual lens, solar), eufyCam 2C (T8113), Indoor Cam E30 ×3 (T8417, pan-tilt). Firmware at the time: HomeBase
  `main_sw_version` 3.8.7.4 / `sec_sw_version` 1.4.0.8.

## 4. Tooling on this Mac

| What | Where |
|---|---|
| Ghidra 12.1.4 | `~/Applications/ghidra_12.1.4_PUBLIC` |
| Temurin JDK 21 | `~/Applications/jdk-21/Contents/Home` |
| arm64 decompiler | built from source into `Ghidra/Features/Decompiler/os/mac_arm_64/decompile` (the release ships none; see README "Reproducing") |
| REA | `rea mcp` (stdio MCP server, `/Users/rkoh/.local/opt/node/bin/rea`, registered in `~/.claude.json` as `rea`) |
| Headless scripts | `tools/ghidra/`: `DumpDecomp.java`, `ListFunctions.java`, `MethodConstants.java`, `CallersOf.java`, `build_research_docs.py` |
| Hopper | installed but blocked by macOS Automation permission; don't change that setting |

Two ways to work:

1. **REA's tools** (`open_binary`, `search_strings`, `procedure_pseudo_code`, `xrefs`, `binary_session`,
   `close_binary` …). Convenient, but the REA CLI re-analyzes the binary on every call, about 3.5 minutes for
   `BC_P2PClient`. Its MCP registration needs `GHIDRA_INSTALL_DIR` and `JAVA_HOME` in `env` to use the local
   Ghidra (set them in `~/.claude.json` under `mcpServers.rea.env`, then reconnect the server). A local model with
   REA as an MCP client gets the same tools.
2. **Headless Ghidra against a saved project**: import once (3.5 min), then every script runs in seconds. This is
   the way for bulk work. From the repo root:

```bash
export JAVA_HOME=~/Applications/jdk-21/Contents/Home
H=~/Applications/ghidra_12.1.4_PUBLIC/support/analyzeHeadless
B=/Applications/BatteryCam.app/Wrapper/BatteryCam.app/Frameworks/BC_P2PClient.framework/BC_P2PClient
$H /tmp/ghidra-eufy eufy -import "$B" -overwrite                                   # once
$H /tmp/ghidra-eufy eufy -process BC_P2PClient -noanalysis -scriptPath tools/ghidra \
   -postScript DumpDecomp.java 'setSnoozeMode' /tmp/snooze.txt                     # decompile matching functions
$H /tmp/ghidra-eufy eufy -process BC_P2PClient -noanalysis -scriptPath tools/ghidra \
   -postScript MethodConstants.java '^BCP2PSession::' docs/homebase-research/data/session_method_constants.tsv
python3 tools/ghidra/build_research_docs.py                                         # rebuilds the .md tables from data/
```

Why `MethodConstants`: on arm64 the command number travels in a register to small stubs, so it appears as an
instruction operand rather than in pseudocode. The script collects each method's numeric constants, including
those in the Objective-C blocks it creates. Constants in more than 8% of methods (960, 992, 1680, 1968, 2400,
2768) are stack offsets, not commands.

Other frameworks import the same way; `ESIotMegaKit` and `MegaMainFramework` are the ones still largely unread.

## 5. The protocol in one page (all verified on the HomeBase 3)

- **Connect:** LOCAL_LOOKUP (broadcast, plus the known IP) → the HomeBase answers 0x41 with its P2P DID →
  CHECK_CAM with that DID → CAM_ID = connected. The LAN-announced DID is the one that works, not the cloud's.
- **Framing:** DATA packet = `f1 d0 len | d1 kind | seq BE | XZYH cmd(LE) bytesToRead(LE) .. channel/type (16 B) | payload`;
  continuation packets carry only more payload. Level-1 command key = last 7 chars of the station serial + 9 DID
  chars from its first `-`.
- **Level 1 vs level 2.** Level-1 `sendCommand 1003` plays only the HomeBase's *active* camera. Per-camera
  selection is level 2: CMD_GATEWAYINFO (1100) reply, AES-ECB under the level-1 key → `cipher_id` (2 LE) + 0000 +
  ECIES envelope (129 B). `get_ciphers([cipher_id], accountUserId, stationSn)` on `security-app.eufylife.com`
  (its own key exchange with the eufylife bootstrap key; not throttled with the mega hosts) → 32-byte ECC key, kept
  locally. Level-2 key = ECIES-unwrap(envelope, ECC key, no HMAC), first 32 bytes.
- **Media start:** CMD_SET_PAYLOAD (1350), body = AES-256-GCM(level2Key) of
  `{account_id, cmd:1003, mChannel, mValue3:1003, payload:{ClientOS:"Android", accountId, camera_type:0, entrytype:0, key:<RSA-1024 modulus hex>, streamtype:1}}`.
  GCM output = tag(16) + nonce(12) + sub(4 LE = 0x01020300 + level2Seq, its own counter from 0) + ct; signCode 8,
  magic `08 00`. Two traps: the GCM counter must be separate and start at 0; `account_id` must be the owner's
  real account user id (empty → error -104).
- **Video:** CMD_VIDEO_FRAME 1300. On level 1 the payload after the 22-byte frame header is plain H.265 Annex B.
  On level 2 a per-frame AES key is RSA-wrapped (PKCS1) in body[22..150] when signCode > 0 and videoLen ≥ 128,
  payload starts at 151, the first 128 bytes are AES-ECB(aesKey), the rest is plaintext H.265. Audio is 1301,
  AAC-LC 16 kHz mono ADTS after a 16-byte header. Cameras start every stream at 720p and ramp up on their own.
- **Control payloads:** 1700 (CMD_CONTROL_PAYLOAD) carries `{"commandType":N,"data":{…}}`: 6030 PTZ rotate
  (`cmd_type:1, rotate_type:1–4, zoom:1.0`), 6035/6032/6033 preset go/save/delete (`value:0–3`), 6042 activity
  zones (`Normalized:1, polygens:[{points:[{x,y}]}]`, 1000×1000 grid; read back from parameter 1204, base64).
- **SET_PAYLOAD inner commands (1350):** 1307 inner 11001 storage info (answer in a 1351 notify with `hdd_info`
  / `emmc_info` / `storage_days`); 1306 database queries (`{cmd:10006, table:"history_record_info", …}` for
  events, one start day per reply; 1308 thumbnails; 1024 clip download, exact `storage_path` matters);
  6445 `{"source":1|2}` Direct power on the eufyCam 3 family (write-only, nothing reports it back); 6010/6011
  continuous recording; 6243 `{"restore":1,"video_type":0|12}` dual-lens view on the S340 (reported as 2700);
  2730 streaming quality on S340 / E30, 1705 on the eufyCam 3 family.
- **Plain level-2 commands:** 1224 guard mode (`setBSArming`), 1271 snooze
  (`{account_id, snooze_time, startTime, chime_onoff:0, motion_notify_onoff:1, homebase_onoff:0}`), 1103 camera
  parameters (channel 255 = the HomeBase's own; 1257 = mode outside schedule), 1005/1006 talkback start/stop,
  1003/1004 live start/stop, 1024/1025 clip download/play.
- **Parameters worth knowing:** 1101 battery, 1142 RSSI, 1138 battery temperature, 2111 charging, 1710
  notification style, 1191 working days, 1192/1193 detected/recorded events, 3100 daily battery history (~30
  days), 7013 firmware, 1204 zones, 1309 "solar reading" (meaning assumed, watch it against daylight).
  Still unnamed: 1189, 1190, 1197, 1198, 6254.
- **What the HomeBase pushes:** [station-messages.md](station-messages.md). Eufynized handles 1151 (guard mode),
  1350/1351 (replies, events, storage), 1103 (parameters). Unhandled but mapped: 1133/1134 camera firmware update
  progress, 1135/1143 SD card, 1187 bind payload, 3102 parameter sync, 7002/7004 parameter value and GPS.

## 6. Verified, candidate, dead

- **Verified** means sent to the HomeBase, answer seen, and (for a setting) read back. The list is the "Status"
  section of [opportunities.md](opportunities.md).
- **Candidate** means static evidence only: a number next to a method name, or a name with no number. The tables
  in [command-names.md](command-names.md) and [app-methods.md](app-methods.md), and the list in
  [undocumented-names.md](undocumented-names.md). A method listing two or more numbers may include a neighbour's
  constant; one number for a `…userid:chl:` method is reliable.
- **Dead ends:** faces (`person_info` / `face_feature_info` tables answer empty lists over 1306 sub-commands
  10009/10011; the app's 10001 delete and 10002 update are never sent); pre-record (doorbells only); the arming
  schedule's time slots (kept by the cloud, pushed with 1211, not readable from the HomeBase); a HomeBase panorama
  command (the app stitches on the phone; Eufynized does the same).

**How to test a candidate safely.** The bridge has `POST /api/probe` (`Sources/eufynized-bridge/Routes.swift`,
`probeAllowed`): it sends one allow-listed command over the existing event session and returns every frame for a
few seconds. Add a number to the allow-list only after reading its sender in the app and deciding it's a read or a
reversible write. For raw sessions from the Mac, `eufynized-fps` (measure a stream, `PROBE_CONTROL=1` prints the
station's control replies), `eufynized-settings` (read/write parameters with read-back) and `eufynized-probe`
exist under `Sources/`.

## 7. Open questions, in the order worth doing

1. **SET_PAYLOAD inner commands in the higher frameworks.** Import `ESIotMegaKit` and `MegaMainFramework`; search
   strings for JSON keys (`"commandType"`, `"source"`, `"video_type"`, `"restore"`) and decompile the builders.
   Targets: anything for the S340's telephoto/wide switching beyond 6243, link quality
   (`GET_HOMEBASE_LINK_INFO`, `GET_LINK_STATUS`), solar/battery health (`SOLAR_INTENSITY`, `VOLTAGE_DETECT`,
   `POWER_SOURCE`), privacy masks (`GET_PRIVACY_MASK`, `PRIVACY_ZONES_STATUS`).
2. **1275 "record only on AI"** (`APP_CMD_SET_RECODER_ONLY_AI`, not in the library). Find its payload; test read
   first. The detection-type toggles already give the same result, so this is low value unless it exposes
   something new.
3. **The remaining dispatcher branches.** `BCP2PClient::notify_callback:type:cvalue:…` decompiles whole with a
   1 GB payload limit; station-messages.md lists the branches with log text within reach. The rest are compared
   against hex constants and still need names.
4. **Unnamed parameters** 1189, 1190, 1197, 1198, 6254, and the meaning of 1309: find where the app reads them
   (search the parameter number as a constant in the settings view controllers).
5. **Settings not in Eufynized.** Compare the app's parameter numbers against `Sources/EufyKit/Settings/` (the
   catalog, `CameraSettingsExtras.swift`, the generated recipes from `scripts/generate-settings-*.js`).
6. **Push-message mode 1252** (`setSmartNotificationMode`) and **1192 recent events** as a faster event list:
   both "known number, read first".

Skip: pairing/binding/migration (1060, `DEVS_BIND`, `QUICK_BIND_*`), HomeKit (`HK_*`), Wi-Fi credentials and
repeaters (1263/1264), locks/keypads, baby-monitor sock data. Risky or irrelevant here.

## 8. Where things live

| | |
|---|---|
| Research pages and raw data | `docs/homebase-research/` (`data/command_table.json`, `session_commands.json`, `known_names.json`, `unknown_names.json`, `session_method_constants.tsv`) |
| Protocol implementation | `Sources/EufyKit/P2P/` (`EufyLiveStream.swift` media, `HomeBaseConnection.swift` transport, `PPPPMessage.swift` framing and payload builders, `HomeBaseEventWatcher.swift`, `EufyAudioPlayer.swift`, `MicrophoneCapture.swift`) |
| Cloud (sign-in, get_ciphers) | `Sources/EufyKit/EufyCloudClient.swift` |
| Settings catalog | `Sources/EufyKit/Settings/` |
| Bridge (Pi) and its probe | `Sources/eufynized-bridge/` |
| Command-line tools | `Sources/eufynized-*/` |
| Ghidra scripts | `tools/ghidra/` |
| Public copy of all of the above | github.com/rkoh46/eufynized-bridge (synced from the private repo with `scripts/sync-public.sh`; never put serials, addresses or account ids in these files) |

## 9. Working with a local model

- Give it this page and the three files it needs for the question at hand, not the whole folder. `data/*.json` are
  big; `command_table.json` (eufy's own names) is the one worth loading whole.
- Decompile narrowly: one method pattern per `DumpDecomp` run, and cap what you paste. A `BCP2PSession` method
  is 50–300 lines; the dispatcher is 190 KB, so grep it for the number first.
- Ask for the three things: number, payload shape, and a proposed read-only probe. Then a human runs the probe.
- Keep the owner's identifiers out of prompts and files: no serials (they look like `T8030T…`), no LAN addresses,
  no account id, no email.
