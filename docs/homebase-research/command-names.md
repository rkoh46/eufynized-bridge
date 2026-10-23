# Command numbers and eufy's own names

From `rtc_get_command_str_info` in the eufy Security app's `BC_P2PClient` (6.1.11): eufy's lookup from a P2P command number to its internal name. **New** = not in eufy-security-client. *Sent by* lists app methods whose only command constant is that number (static evidence; see README).

| # | eufy name | Library | Sent by (app method) |
|---:|---|---|---|
| 900 | `APP_CMD_START_REC_BROADCASE` |  |  |
| 901 | `APP_CMD_STOP_REC_BROADCASE` |  |  |
| 1001 | `APP_CMD_BIND_SYNC_ACCOUNT_INFO` |  | synAccount:chl:, syncAccountInfo: |
| 1002 | `APP_CMD_UNBIND_ACCOUNT` |  | unbindAccount:userid:chl: |
| 1003 | `APP_CMD_START_REALTIME_MEDIA` |  |  |
| 1004 | `APP_CMD_STOP_REALTIME_MEDIA` |  | StopVideoStream:, StopVideoStreamBy: |
| 1005 | `APP_CMD_START_TALKBACK` |  |  |
| 1006 | `APP_CMD_STOP_TALKBACK` |  |  |
| 1007 | `APP_CMD_START_VOICECALL` |  |  |
| 1008 | `APP_CMD_STOP_VOICECALL` |  |  |
| 1009 | `APP_CMD_START_RECORD` |  | startRecordVideo:, startRecordVideo:userid: |
| 1010 | `APP_CMD_STOP_RECORD` |  | endRecordVideo:, endRecordVideo:userid: |
| 1011 | `APP_CMD_PIR_SWITCH` |  | setCameraSwith:chl:userid:, setPIR:chl:userid: |
| 1012 | `APP_CMD_CLOSE_PIR` |  |  |
| 1013 | `APP_CMD_IRCUT_SWITCH` |  | setIndoorNightVisionSwith:chl:userid:, setNightVisionSwith:chl:userid: |
| 1014 | `APP_CMD_CLOSE_IRCUT` |  |  |
| 1015 | `APP_CMD_EAS_SWITCH` |  | setAntiTheft:chl:userid: |
| 1016 | `APP_CMD_CLOSE_EAS` |  | sendDoorBellHomeBaseWifi:chl: |
| 1017 | `APP_CMD_AUDDEC_SWITCH` |  | setAudioDetect:chl:userid: |
| 1018 | `APP_CMD_CLOSE_AUDDEC` |  |  |
| 1019 | `APP_CMD_DEVS_LOCK_SWITCH` | calls it `CMD_DEVS_LOCK` / `CMD_ENABLE_HDR` | setLockState:chl:userid: |
| 1020 | `APP_CMD_DEVS_UNLOCK` |  |  |
| 1021 | `APP_CMD_RECORD_IMG` |  |  |
| 1022 | `APP_CMD_RECORD_IMG_STOP` |  |  |
| 1023 | `APP_CMD_STOP_SHARE` |  |  |
| 1024 | `APP_CMD_DOWNLOAD_VIDEO` |  | localVideoStream:userid:chl:, localVideoStreamDownloadResult:result: |
| 1025 | `APP_CMD_RECORD_VIEW` |  | StartFileVideoStream:, startFileVideoStream:userid:chl: |
| 1026 | `APP_CMD_RECORD_PLAY_CTRL` |  | StopFileVideoStream:, eventVideoStop:randomNum:chl:, videoStreamSlidControl:, videoStreamSlidControl:frameNumber:chl: |
| 1027 | `APP_CMD_DELLETE_RECORD` |  | deleteRecord:chl:recordid:userid: |
| 1028 | `APP_CMD_SNAPSHOT` |  |  |
| 1029 | `APP_CMD_FORMAT_SD` |  | formatSDCard:, formatSDCardBy:chl: |
| 1030 | `APP_CMD_CHANGE_PWD` |  |  |
| 1031 | `APP_CMD_CHANGE_WIFI_PWD` |  |  |
| 1032 | `APP_CMD_WIFI_CONFIG` |  |  |
| 1033 | `APP_CMD_TIME_SYCN` |  |  |
| 1034 | `APP_CMD_HUB_REBOOT` |  | restartHub:, restartHubByUserid:chl: |
| 1035 | `APP_CMD_DEVS_SWITCH` |  | setDeviceSwitch:chl:userid: |
| 1036 | `APP_CMD_HUB_TO_FACTORY` |  | factoryHubBy:chl:, resetHubByUserid:chl: |
| 1037 | `APP_CMD_DEVS_TO_FACTORY` |  | factoryDev:, factoryDevBy:, resetDeviceBychl:chl: |
| 1038 | `APP_CMD_DEVS_BIND_BROADCASE` |  | receiveCameraBroadcast:Chl:devType:userid: |
| 1039 | `APP_CMD_DEVS_BIND_NOTIFY` |  |  |
| 1040 | `APP_CMD_DEVS_UNBIND` |  | unbindDeviceBychl:userid: |
| 1041 | `APP_CMD_RECORDDATE_SEARCH` |  |  |
| 1042 | `APP_CMD_RECORDLIST_SEARCH` |  |  |
| 1043 | `APP_CMD_GET_UPGRADE_RESULT` |  | checkUpgradeResult:, checkUpgradeResultBy:chl: |
| 1044 | `APP_CMD_P2P_DISCONNECT` |  |  |
| 1045 | `APP_CMD_DEV_LED_SWITCH` |  | setLEDSwith:chl:userid: |
| 1046 | `APP_CMD_CLOSE_DEV_LED` |  |  |
| 1047 | `APP_CMD_COLLECT_RECORD` |  | collect:chl:path:recordid:userid: |
| 1048 | `APP_CMD_DECOLLECT_RECORD` |  |  |
| 1049 | `APP_CMD_BATCH_RECORD` |  |  |
| 1050 | `APP_CMD_STRESS_TEST_OPER` |  |  |
| 1051 | `APP_CMD_DOWNLOAD_CANCEL` |  | cancelDownload:, cancelDownloadWithChl: |
| 1054 | `APP_CMD_BIND_SYNC_ACCOUNT_INFO_EX` |  | synAccountEx:Chl:userid:asDomain:name:timezone: |
| 1056 | `APP_CMD_LIVEVIEW_LED_SWITCH` |  | setLiveViewLedSwitch:chl:userid: |
| 1057 | `APP_CMD_REPAIR_SD` |  | repairSDCard:, repairSDCardBy:Chl: |
| 1060 | `APP_CMD_HB3_BIND_CODE` | **New** | p2pSendBindHub3RequestWithPayload:userid:chl: |
| 1066 | `APP_CMD_SWITCH_TO_BASE` | **New** |  |
| 1100 | `APP_CMD_GET_ASEKEY` | calls it `CMD_GATEWAYINFO` |  |
| 1101 | `APP_CMD_GET_BATTERY` |  | getDeviceBatteryInfo:, getDeviceBatteryInfoBy: |
| 1102 | `APP_CMD_SDINFO` |  | getSDCardInfo:, getSDCardInfoBy:chl: |
| 1103 | `APP_CMD_CAMERA_INFO` |  | getDeviceInfo:, getDeviceInfoType: |
| 1104 | `APP_CMD_GET_RECORD_TIME` |  | eufylink_send_commandWithChl:cmd:v1:v2:v3: |
| 1105 | `APP_CMD_GET_MDETECT_PARAM` |  |  |
| 1106 | `APP_CMD_MDETECTINFO` |  |  |
| 1107 | `APP_CMD_GET_ARMING_INFO` |  |  |
| 1108 | `APP_CMD_GET_ARMING_STATUS` |  |  |
| 1109 | `APP_CMD_GET_AUDDEC_INFO` |  |  |
| 1110 | `APP_CMD_GET_AUDDEC_SENSITIVITY` |  |  |
| 1111 | `APP_CMD_GET_AUDDE_CSTATUS` |  |  |
| 1112 | `APP_CMD_GET_MIRRORMODE` |  | notifyHandlerMan |
| 1113 | `APP_CMD_GET_IRMODE` |  |  |
| 1114 | `APP_CMD_GET_IRCUTSENSITIVITY` |  |  |
| 1115 | `APP_CMD_GET_PIRINFO` |  |  |
| 1116 | `APP_CMD_GET_PIRCTRL` |  |  |
| 1117 | `APP_CMD_GET_PIRSENSITIVITY` |  |  |
| 1118 | `APP_CMD_GET_EAS_STATUS` |  |  |
| 1119 | `APP_CMD_GET_CAMERA_LOCK` |  |  |
| 1120 | `APP_CMD_GET_GATEWAY_LOCK` |  | isValidJSONObject: |
| 1121 | `APP_CMD_GET_UPDATE_STATUS` |  |  |
| 1122 | `APP_CMD_GET_ADMIN_PWD` |  |  |
| 1123 | `APP_CMD_GET_WIFI_PWD` |  |  |
| 1124 | `APP_CMD_GET_EXCEPTION_LOG` |  |  |
| 1125 | `APP_CMD_GET_NEWVESION` |  |  |
| 1126 | `APP_CMD_GET_HUB_TONE_INFO` |  |  |
| 1127 | `APP_CMD_GET_DEV_TONE_INFO` |  |  |
| 1128 | `APP_CMD_GET_HUB_NAME` |  |  |
| 1129 | `APP_CMD_GET_DEVS_NAME` |  |  |
| 1130 | `APP_CMD_GET_P2P_CONN_STATUS` |  |  |
| 1132 | `APP_CMD_GET_HUB_LOG` |  | getHubLog:chl:type:userid: |
| 1145 | `APP_CMD_NAS_SWITCH` |  | getCameraNSAURLSwitch:channel:userid: |
| 1146 | `APP_CMD_NAS_TEST` |  | getCameraNSAOpenSwitch:channel:userid: |
| 1152 | `APP_CMD_GET_DEVICE_PING` |  | fl_responseToGetDevicePingTask:, fl_responseToGetDevicePingUserid:chl: |
| 1200 | `APP_CMD_SET_LANGUAGE` |  | setLanguageBySystemBy:chl: |
| 1201 | `APP_CMD_SET_TONE_FILE` |  |  |
| 1202 | `APP_CMD_SET_DEVS_TONE_FILE` |  | setAlarm:chl:userid: |
| 1203 | `APP_CMD_SET_RECORDTIME` |  | setGlobalRecordTimeByUserid:chl:sec: |
| 1204 | `APP_CMD_SET_MDETECTPARAM` |  | setCameraActivityZones:channel:userid:, setFloodlightActivityZones:userid:chl: |
| 1205 | `APP_CMD_SET_RESOLUTION` |  | setResolutionByUserid:chl:type: |
| 1206 | `APP_CMD_SET_BITRATE` |  | setBitrateByUserid:chl:type: |
| 1207 | `APP_CMD_SET_MIRRORMODE` |  | setIDCMirrormodeByUserid:chl:type:, setMirrormodeByUserid:chl:type: |
| 1208 | `APP_CMD_SET_IRMODE` |  |  |
| 1209 | `APP_CMD_SET_PIR_INFO` |  |  |
| 1210 | `APP_CMD_SET_PIRSENSITIVITY` |  | setPIRsensiByUserid:chl:sens: |
| 1211 | `APP_CMD_SET_ARMING_SCHEDULE` |  | setArmingSchedule:chl:sereverConfig:userid:chl: |
| 1212 | `APP_CMD_SET_AUDDEC_INFO` |  |  |
| 1213 | `APP_CMD_SET_AUDDEC_SENSITIVITY` |  |  |
| 1214 | `APP_CMD_SET_DEVS_OSD` |  | setDevsOSDLogo:userid:chl:, setDevsOSDMode:userid:chl:, setDevsOSDStatus:userid:chl:, setWatermarkSwith:chl:userid: |
| 1215 | `APP_CMD_SET_TIMEZONE` |  | setTimeZone:Chl:userid: |
| 1216 | `APP_CMD_SET_HUB_NAME` |  | setHubName:Chl:userid: |
| 1217 | `APP_CMD_SET_DEVS_NAME` |  | setDeviceName:chl:userid: |
| 1218 | `APP_CMD_SET_HUB_PIR_STATUS` |  | setGlobalPirStatusByUserid:chl:oepn: |
| 1219 | `APP_CMD_SET_HUB_IRCUT_STATUS` |  |  |
| 1220 | `APP_CMD_SET_HUB_GS_STATUS` |  |  |
| 1221 | `APP_CMD_SET_HUB_MVDEC_STATUS` |  |  |
| 1222 | `APP_CMD_SET_HUB_AUDEC_STATUS` |  |  |
| 1223 | `APP_CMD_SET_STORGE_TYPE` |  | setGlobalStorageTypeByUserid:type:chl: |
| 1224 | `APP_CMD_SET_ALARM_MODE` | calls it `CMD_SET_ARMING` | setBSArming:userid:chl: |
| 1226 | `APP_CMD_SET_GSSENSITIVITY` |  | setGSsensiBysens:userid:chl: |
| 1227 | `APP_CMD_SET_AUDIOSENSITIVITY` |  | setAudiosensiBysens:userid:chl: |
| 1229 | `APP_CMD_SET_DEV_MIC_VOLUME` |  | setMicrophoneGain:userid:chl: |
| 1230 | `APP_CMD_SET_DEV_SPEAKER_VOLUME` |  | fl_setDeviceAlarmVolumn:chl:userid:, fl_setSpeakerVolume:userid:chl:, setDoorbellDeviceVolume:userID:chl: |
| 1231 | `APP_CMD_SET_AI_PHOTO` |  | setAIPhoto:Chl:faceuser:faceid:groupid:nickname:notify:facepoint:userid: |
| 1232 | `APP_CMD_DEL_USER_PHOTO` |  | delAiUserBy:Chl:userid: |
| 1233 | `APP_CMD_SET_PIR_ACTION` | calls it `CMD_SET_PRI_ACTION` | setCamArmMode:chl:userid: |
| 1234 | `APP_CMD_DEL_FACE_PHOTO` |  |  |
| 1235 | `APP_CMD_SET_HUB_SPK_VOLUME` |  | setHubAudioVolumn:chl:vol: |
| 1236 | `APP_CMD_SET_AI_SWITCH` |  | setAIDetectionSwith:chl:userid: |
| 1237 | `APP_CMD_SET_AS_SERVER` |  | setAsServer:chl:server: |
| 1238 | `APP_CMD_SET_UPGRADE` |  | homebaseUpdate:, homebaseUpdateBy:chl: |
| 1240 | `APP_CMD_SET_DEV_MIC_MUTE` |  | setMicrophoneOFF:userid:chl: |
| 1241 | `APP_CMD_SET_DEV_SPEAKER_MUTE` |  | setSpeakerOFF:userid:chl: |
| 1242 | `APP_CMD_SET_AI_NICKNAME` |  | setAINicknamefaceuser:Chl:faceid:nickname:notify:userid: |
| 1243 | `APP_CMD_SET_PIR_TEST_MODE` |  | pirTestmode:chl:userid: |
| 1246 | `APP_CMD_SET_PIR_POWERMODE` |  | setPIRPowerMode:chl:userid: |
| 1247 | `APP_CMD_SET_TELNET` |  | telnetOn:userid:chl: |
| 1248 | `APP_CMD_SET_NOTFACE_PUSHMSG` |  | setNotFacePushMSGSwith:chl:userid: |
| 1249 | `APP_CMD_DEV_RECORD_TIMEOUT` |  | setCameraRecordTimeout:chl:userid: |
| 1250 | `APP_CMD_DEV_RECORD_INTERVAL` |  | setCameraRecordInterval:chl:userid: |
| 1251 | `APP_CMD_DEV_RECORD_AUTOSTOP` |  | setCameraRecordAutoStop:chl:userid: |
| 1252 | `APP_CMD_DEV_PUSHMSG_MODE` |  | setSmartNotificationMode:chl:userid: |
| 1253 | `APP_CMD_SET_HUB_OSD` |  | setHubOSD24H:userid:chl: |
| 1254 | `APP_CMD_SET_JSON_SCHEDULE` |  | setJsonSchedule:userid:chl: |
| 1255 | `APP_CMD_SET_ALL_ACTION` |  | setAllPIRAction:userid:chl: |
| 1256 | `APP_CMD_SET_CUSTOM_MODE` |  | setCustMode:userid:chl: |
| 1257 | `APP_CMD_SET_SCHEDULE_DEFAULT` |  | setDefaultPIRMode:userid:chl: |
| 1258 | `APP_CMD_GEO_SET_USER_STATUS` |  | addGeofenceSetStatus:userid:chl: |
| 1259 | `APP_CMD_GEO_ADD_USER_INFO` |  | addGeofenceInfo:userid:chl: |
| 1260 | `APP_CMD_GEO_UPDATE_USER_INFO` |  | updateGeofenceInfo:userid:chl: |
| 1261 | `APP_CMD_GEO_DEL_USER_INFO` |  | deleteGeofenceInfo:userid:chl: |
| 1262 | `APP_CMD_GEO_UPDATE_LOC_SETTING` |  | updateGeofencoLocSetting:userid:chl: |
| 1263 | `APP_CMD_GET_REPEATER_SITE_LIST` |  | getHomeBaseWiFiListTask:, getHomeBaseWiFiListWithUserid:chl: |
| 1264 | `APP_CMD_SET_REPEATER_PARAMS` |  | setRepeatWifiConfig:userid:chl: |
| 1265 | `APP_CMD_GET_WAN_MODE` |  |  |
| 1266 | `APP_CMD_GET_REPEATER_RSSI` |  |  |
| 1268 | `APP_CMD_GET_WAN_LINK_STATUS` |  | getHomeBaseWanLinkStatusWithUserid:chl: |
| 1269 | `APP_CMD_REPEATER_RSSI_TEST` |  | repeaterRssiTest:userid:chl: |
| 1271 | `APP_CMD_SET_SNOOZE_MODE` |  |  |
| 1272 | `APP_CMD_SET_MDSENSITIVITY` |  | fl_setMotionLevel:chl:userid: |
| 1273 | `APP_CMD_SET_DEV_MD_RECORD` |  | setOutsiderDetectedVideoClips:channel:userid: |
| 1274 | `APP_CMD_GET_DEVS_RSSI_LIST` |  | getHomeBaseDevRssiList:, getHomeBaseDevRssiListWithUserid:chl: |
| 1275 | `APP_CMD_SET_RECODER_ONLY_AI` | **New** |  |
| 1400 | `APP_CMD_SET_FLOODLIGHT_MANUAL_SWITCH` |  | setFLSearchLight:userid:flMod:, setSpotLight:chl:userid: |
| 1401 | `APP_CMD_SET_FLOODLIGHT_BRIGHT_VALUE` |  | updateFLSearchLight:chl:userid:value:, updateSpotLightBrightness:chl:userid: |
| 1402 | `APP_CMD_SET_FLOODLIGHT_STREET_LAMP` |  | setFLStreetLampSwitch:userid:chl: |
| 1403 | `APP_CMD_SET_FLOODLIGHT_TOTAL_SWITCH` |  | fl_setTotalLightSwitch:chl:userid: |
| 1404 | `APP_CMD_SET_FLOODLIGHT_LIGHT_SCHEDULE` |  | setFloodlightLightSchedule:sereverConfig:userid:chl:, setFloodlightLightScheduleJson:userid:chl: |
| 1405 | `APP_CMD_GET_FLOODLIGHT_WIFI_LIST` |  | getFloodLightWiFiListTask:, getFloodLightWiFiListWithUserid:chl: |
| 1406 | `APP_CMD_SET_FLOODLIGHT_WIFI_CONNECT` |  | resetFloodLightWifi:bssid:wifiPwd:userid:authType:chl:, resetFloodLightWifi:bssid:wifiPwd:userid:authType:security:chl:, resetFloodLightWifi:bssid:wifiPwd:useri |
| 1407 | `APP_CMD_SET_FLOODLIGHT_DETECTION_AREA` |  |  |
| 1408 | `APP_CMD_SET_LIGHT_CTRL_PIR_SWITCH` |  | fl_setPirLightSwith:chl:userid:, setPirSpotLightSwitch:chl:userid: |
| 1409 | `APP_CMD_SET_LIGHT_CTRL_PIR_TIME` |  | fl_setPirLightTime:chl:userid: |
| 1410 | `APP_CMD_SET_LIGHT_CTRL_LAMP_VALUE` |  | fl_setLampLightValue:chl:userid: |
| 1411 | `APP_CMD_SET_LIGHT_CRUISE_SCHEDULE` | calls it `CMD_SET_LIGHT_CTRL_TRIGGER` |  |
| 1412 | `APP_CMD_SET_LIGHT_CTRL_BRIGHT_PIR` |  | updateFLMotionLightBrightness:userid:chl: |
| 1413 | `APP_CMD_SET_LIGHT_CTRL_BRIGHT_SCH` |  | updateFLScheduleLightBrightness:userid:chl: |
| 1414 | `APP_CMD_SET_LIGHT_CTRL_SUNRISE_SWITCH` |  |  |
| 1415 | `APP_CMD_SET_LIGHT_CTRL_SUNRISE_INFO` |  | getSunriseLocationJson:, getSunriseLocationJson:userid: |
| 1604 | `APP_CMD_MOTION_SENSOR_GET_INFO` | **New** |  |
| 1608 | `APP_CMD_MOTION_SENSOR_ALARM_ENABLE` | **New** |  |
| 1609 | `APP_CMD_MOTION_SENSOR_SET_PIR_SENSITIVITY` |  | setMotionSensorPIRByUserid:chl:sens: |
| 1610 | `APP_CMD_MOTION_SENSOR_EXIT_USER_TEST_MODE` |  | motionSensorExitTestModeByUserid:chl: |
