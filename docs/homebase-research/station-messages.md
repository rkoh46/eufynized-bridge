# What the HomeBase can send to the app

From the app's message dispatcher (`BCP2PClient::notify_callback:…`, two overloads, decompiled with Ghidra):
each number the dispatcher checks for, with the log text the app writes when it arrives. "Name" is eufy's
own name (or eufy-security-client's) where one is known. Numbers with no name are the interesting ones.

| Number | Name | What the app logs |
|---|---|---|
| 1000 | `` |  printparam 1000receivebroadcastsn    channel  d version   ; binddevice        |
| 1029 | `APP_CMD_FORMAT_SD` | idc APP CMD FORMAT SDgetstatus   d sn     |
| 1039 | `APP_CMD_DEVS_BIND_NOTIFY` | binddeviceAPP CMD DEVS BIND NOTIFYsn    ivalue  d;  printparam 1039receivebind notifysn    channel  d version    |
| 1044 | `APP_CMD_P2P_DISCONNECT` | sn        ; deviceofflinenotifysn    |
| 1100 | `APP_CMD_GET_ASEKEY` | PPCS ENC EECFailedtoallocatememoryforsafeBuffer |
| 1103 | `APP_CMD_CAMERA_INFO` | params; param type; param value; dev type |
| 1133 | `` |  SoloOTA  1133fromp2p notifysn    ivalue  d ivalue2  d channel  d |
| 1134 | `` |  SoloOTA  1134fromp2p notifysn    ivalue  d ivalue2  d channel  d |
| 1135 | `` |  idcsdcard 1135p2pnotifysn    ivalue  d |
| 1143 | `` | idc APP CMD GET TFCARD FORMAT STATUSgetstatus   d sn     |
| 1164 | `` | 1351     ; notify callback    1351cvalue1   ; notify callback    1351errorcvalue1   ; payload |
| 1231 | `APP_CMD_SET_AI_PHOTO` | status |
| 1232 | `APP_CMD_DEL_USER_PHOTO` | status |
| 1263 | `APP_CMD_GET_REPEATER_SITE_LIST` | BC CMD GET HOMEBASE WIFI LIST   |
| 1268 | `APP_CMD_GET_WAN_LINK_STATUS` | wan mode; password; repeater enable; enable |
| 1270 | `` | channel; result |
| 1297 | `` | status |
| 1308 | `` | device sn; KHB DOWN IMAGE NOTI |
| 1701 | `` | commandType |
| 1970 | `` | station sn |
| 2700 | `` | status; currentRecordId; format |
| 6001 | `` | stationSn |
| 6205 | `` | videoType; APP CMD COMMAND DUAL SET VIDEO TYPEAPP CMD COMMAND DUAL SET VIDEO TYPE |
| 7002 | `` | param value; 81507002paramvalue    sn    |
| 7004 | `` | param value |

## Notes

- The dispatcher's two overloads were decompiled whole (190 KB of pseudocode). Most of its branches compare the
  incoming number against constants that Ghidra shows as hex; the table lists those with log text within reach.
- Eufynized already handles 1151 (guard mode), 1350 (command replies), 1351 (events and storage), 1103
  (parameters). New here: **1133/1134** (camera firmware update progress), **1135** (SD card), **1143** (card
  format status), **1308** (image download done), **2700** (current recording id), **6205** (the camera
  confirming a dual-lens video-type change), **7002/7004** (a parameter's value pushed without being asked).
- Worth building: a "firmware update in progress" state from 1133/1134, and following 7002 so settings views
  update when the eufy app changes something.
