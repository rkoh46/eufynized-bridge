# Opportunities for Eufynized

Features the official app has that Eufynized could add, from the research in this folder. Ranked by value to the
user and by how safely they can be verified on the HomeBase. "Known" means the command number came from eufy's own
name table or a single-number sender method; "candidate" means static evidence that needs confirming on hardware.

## Status (2026-10-22)

Built in both apps, verified against the HomeBase 3:

- **Storage:** SET_PAYLOAD 1307 with payload `{"version":0,"cmd":11001}` (eufy-security-client's form). The answer
  is a 1351 notify `{"cmd":1307,"payload":{"body":{…}}}` with `hdd_info` (video_size / video_used in MB, health
  0 = good, cur_temperate °C, device_module), `emmc_info`, `storage_days` and `storage_events`. `HomeBaseStorage`
  in EufyKit parses it.
- **Snooze:** level-2 command 1271 on the camera's channel with
  `{"account_id","snooze_time":<s>,"startTime":"<unix>","chime_onoff":0,"motion_notify_onoff":1,"homebase_onoff":0}`.
  The HomeBase answers 1271 with result 0. No "snooze over" message came back on the local session. Eufynized
  also mutes its own alerts while a camera is snoozed.
- **Notification style, Wi-Fi signal, battery, battery temperature, charging:** already in the settings read
  (1710, 1142, 1101, 1138, 2111). Now Home Assistant entities too.
- **New from the parameter read** (`GET /api/cameras/<ch>/settings?raw=1` dumps every number): 1191 working
  days, 1192 detected events, 1193 recorded events, 3100 daily battery history for about 30 days
  (`battery_data_detail`), 7013 firmware. `CameraHealth` in EufyKit parses them.

Second pass (same day):

- **Arming schedule:** the HomeBase doesn't hold the schedule's time slots. The eufy cloud keeps them and pushes
  them down with 1211. The HomeBase's own parameters (1103 on channel 255, `dev_type` 255) include 1257, the mode
  it uses outside scheduled times (63 = Disarmed here), plus `main_sw_version` 3.8.7.4 / `sec_sw_version` 1.4.0.8.
  Home Assistant shows those on the alarm panel.
- **Record only on AI:** the app's only "only AI" switch (`only_ai`, `p2p_setHumanOnlyAINight:`) is in its video
  doorbell settings. On these cameras the same result comes from the detection types: with "all other motion"
  off, only people and vehicles (and pets, if on) trigger a recording. Those toggles are now switches in Home
  Assistant (`switch.<camera>_detect_people`, `_detect_vehicles`, `_detect_pets`, `_detect_all_other_motion`).
- **Dual lens (S340):** the lens choice is the view mode, Single view (0) or Double view (12). It's written with
  SET_PAYLOAD inner cmd 6243 `{"restore":1,"video_type":N}`. The S340 reports it as 2700, not 6243, so the
  catalog reads 2700 as a fallback.
- **Panorama:** the eufy app builds it on the phone (`BCEufyPanoramaManager`, stitching with camera matrices).
  It pans and grabs pictures; the HomeBase has no panorama command. Eufynized does the same: it pans a step at a
  time, measures each step's shift from the pictures (`PanoramaMath`), stitches, and returns. Measured on the
  S340: a settled step is about a quarter of the frame and varies, so the camera can only return to within
  about half a step of where it was.
- **Faces:** known people live in the HomeBase's event database (tables `person_info`, `face_feature_info`;
  fields name, person_id, group_id, relation, notice_flag, face_picture_content). Read with the database
  command 1306 and a query sub-command (10000 family). Delete (10001) and update (10002) are never sent.
- **Direct power (eufyCam 3 family):** the eufy app's Power Manager "Working Mode: Battery / Direct Power"
  (`ECCamPowerSettingVC::switchWirePowerMode:`) sends SET_PAYLOAD inner cmd **6445** `{"source": 1 | 2}`
  (1 Battery, 2 Direct power). Verified on an S3 Pro: the camera answers `{"cmd":6445,"payload":{"result":0}}`.
  Nothing reports the mode back, so Eufynized remembers the last value written. The same screen's wired mode
  also exposes continuous recording (6010 on/off, 6011 Always/Schedule), which the S3 Pros report and which
  Eufynized now shows for them.
- **Preset positions (S340):** 1700 payload `{"commandType":6035|6032|6033,"data":{"value":0–3}}` (go / save /
  delete), as eufy-security-client sends for outdoor pan-tilt cameras. Built into both apps with a return-home timer.
- **Activity zones:** read from parameter 1204 (base64 JSON, 1000×1000 grid), written with the 1700 payload
  `{"commandType":6042,"data":{"Normalized":1,"polygens":[…]}}`; verified on an S3 Pro (write, read back equal).
- **Pre-record:** doorbells only (`setDoorbellPreRecording:task:`); none of these cameras has it.
- **Digital zoom:** `SET_STREAM_ZOOM` crops on the camera before encoding, losing resolution. Eufynized zooms on
  the viewer's side instead (both apps), which keeps the full 4K picture and costs no battery.
- **1309** is shown as a raw "solar reading" in both apps (the user confirms the S340 and S3 Pro both have solar
  panels). Watch it against daylight to confirm the meaning. Still unnamed: 1189, 1190, 1197, 1198, 6254.
- **Push messages:** see [station-messages.md](station-messages.md).

The bridge's `POST /api/probe` sends one allow-listed command over the event session and returns every frame for
a few seconds: the tool for the next pass.

## Ready to verify (read-only or low risk)

| Feature | Command | Status | For the Mac app | For Home Assistant |
|---|---|---|---|---|
| **HomeBase 3 storage info** | 1307 `CMD_STORAGE_INFO_HB3` (via `sendHB3DiskinfoReqCommand`) | Known number; read-only | Disk usage and health in Settings | `sensor.homebase_storage_used` / free, health |
| **Snooze notifications** | 1271 `APP_CMD_SET_SNOOZE_MODE` | Known (`setSnoozeMode:chl:userid:`) | "Snooze 30 min / 1 h / 8 h" on a camera | `eufynized.snooze` action; pairs with naptime |
| **Push-message mode** | 1252 `APP_CMD_DEV_PUSHMSG_MODE` | Known (the app calls it `setSmartNotificationMode:chl:userid:`) | Notification style picker | select entity |
| **Arming schedule** | 1211 (`setArmingSchedule:chl:…`) | Known; read first | Show the HomeBase's schedule mode | expose as attributes on the alarm panel |
| **Recent detected events (HB3)** | 1192 `CMD_GET_DETECTED_EVENTS_HB3` | Library name; worth comparing with the event query Eufynized already uses | Faster event list | same |

## Worth building after a short probe

| Feature | What's known | Why it matters |
|---|---|---|
| **Record only on AI detection** | 1275 `APP_CMD_SET_RECODER_ONLY_AI`: **not in eufy-security-client** | Fewer junk clips; saves HomeBase storage and camera battery |
| **Dual lens on Front360 (S340)** | `SWITCH_DUAL_CAM_STREAM`, `COMMAND_DUAL_SET_VIDEO_TYPE`, `DUALCAM_*` names; numbers not found yet | The S340 has wide and telephoto lenses; switching between them in live view is a major feature |
| **Panorama for pan/tilt** | `PANORAMA_IMAGE_DONE`, `SET_PANORAMA_INNER` | A 360° picture to tap where the S340 should point, instead of arrow nudges |
| **Digital zoom** | `SET_STREAM_ZOOM` | Zoom in live view on 2K/4K cameras |
| **HomeBase ↔ camera Wi-Fi and link quality** | `GET_HOMEBASE_LINK_INFO`, `GET_HOMEBASE_WIFI_TEST`, `GET_LINK_STATUS` | Explains dropouts (the gap counts seen in live view); a "signal" sensor per camera |
| **Battery and solar health** | `VOLTAGE_DETECT`, `VOLTAGE_ERROR`, `SOLAR_INTENSITY`, `SET_SOLAR_PANEL`, `POWER_SOURCE` | Battery-health sensors for S3 Pro and 2C |
| **Face recognition management** | 1231 `APP_CMD_SET_AI_PHOTO`, 1242 `APP_CMD_SET_AI_NICKNAME`, `CANDIDATE_FACE_TAG`, `DELETE_AI_PHOTO` | Name known faces from Eufynized; "Known person: Name" in alerts |
| **Pre-record** | `PRE_RECORD` | Clips that start a few seconds before the trigger |
| **Privacy masks** | `GET_PRIVACY_MASK`, `PRIVACY_ZONES_STATUS` | Show privacy zones on the live view; explains PTZ being locked |

## Probably not

- **Pairing, binding, migration and quick-bind** (1060 `HB3_BIND_CODE`, `DEVS_BIND`, `QUICK_BIND_*`,
  `GET_MIGRATION_DEVS`): setup flows, risky to experiment with, and the official app handles setup.
- **HomeKit activation** (`HK_*`): Eufynized already serves Home Assistant.
- **Wi-Fi credentials** (`SET_WIFI_PWD`, repeater 1263/1264): could disconnect cameras.
- **Locks and keypads** (`WIFILOCK_*`, `KEYPAD_*`, `BLE_LOCK_PAYLOAD`): no such eufy devices here.
- **Baby-monitor sock data** (`BBM_SOCK_*`): other eufy product lines.

## Next research passes

1. **SET_PAYLOAD inner commands.** Decompile the payload builders in `ESIotMegaKit` and `MegaMainFramework`, with the
   same scripts, to get the inner `cmd` numbers and JSON keys for dual lens, zoom, panorama, pre-record and record
   only on AI.
2. **Station → app messages.** The dispatcher `BCP2PClient::notify_callback:type:cvalue:…` (decompiles with a 1 GB
   payload limit) pairs incoming command numbers with log text, for example "1201/1202 alarm state", "1133/1134
   Solo OTA", "1135 SD card", "1187 HB3 bind payload", "3102 param sync", "7002/7004 param value and GPS". A full
   pass maps every event the HomeBase can push.
3. **Settings parameters.** Compare the app's parameter numbers with the settings catalog in
   `Sources/EufyKit/Settings/` to find settings that exist on these cameras but aren't in Eufynized yet.
