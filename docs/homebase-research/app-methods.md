# What the official app sends, by method

Each `BCP2PSession` method of the eufy Security app (6.1.11) with the command numbers found in its code and the Objective-C blocks it creates. Constants that appear in most methods (stack offsets) are filtered out; a method can still list a neighbour's number, so treat more than one number as *candidates*. Names come from eufy's own table, else eufy-security-client.

| Method | Command(s) |
|---|---|
| `RTCNeedReSendCmd:Result:Sn:` | 1000 `CMD_BIND_BROADCAST`, 1003 `APP_CMD_START_REALTIME_MEDIA`, 1004 `APP_CMD_STOP_REALTIME_MEDIA`, 1025 `APP_CMD_RECORD_VIEW`, 1026 `APP_CMD_RECORD_PLAY_CTRL`, 6001 `CMD_SMARTLOCK_QUERY_BATTERY_LEVEL` |
| `StartFileVideoStream:` | 1025 `APP_CMD_RECORD_VIEW` |
| `StartFileVideoStreamResult:result:` | 1025 `APP_CMD_RECORD_VIEW`, 1120 `APP_CMD_GET_GATEWAY_LOCK` |
| `StartRTVideoStream:` | 1003 `APP_CMD_START_REALTIME_MEDIA`, 1400 `APP_CMD_SET_FLOODLIGHT_MANUAL_SWITCH` |
| `StopFileVideoStream:` | 1026 `APP_CMD_RECORD_PLAY_CTRL` |
| `StopVideoStream:` | 1004 `APP_CMD_STOP_REALTIME_MEDIA` |
| `StopVideoStreamBy:` | 1004 `APP_CMD_STOP_REALTIME_MEDIA` |
| `addGeofenceInfo:task:` | 900 `APP_CMD_START_REC_BROADCASE`, 1259 `APP_CMD_GEO_ADD_USER_INFO`, 1504 `CMD_DOOR_SENSOR_LOW_POWER_REPORT` |
| `addGeofenceInfo:userid:chl:` | 1259 `APP_CMD_GEO_ADD_USER_INFO` |
| `addGeofenceSetStatus:task:` | 1258 `APP_CMD_GEO_SET_USER_STATUS` |
| `addGeofenceSetStatus:userid:chl:` | 1258 `APP_CMD_GEO_SET_USER_STATUS` |
| `batchDeleteRecord:chl:recordids:userid:` | 1049 `APP_CMD_BATCH_RECORD`, 6600 `CMD_SMARTLOCK_AUTO_LOCK_TIMER` |
| `batchDeleteRecord:recordids:task:` | 1049 `APP_CMD_BATCH_RECORD` |
| `bindToSetDeviceName:task:` | 1217 `APP_CMD_SET_DEVS_NAME` |
| `cancelDownload:` | 1051 `APP_CMD_DOWNLOAD_CANCEL` |
| `cancelDownloadWithChl:` | 1051 `APP_CMD_DOWNLOAD_CANCEL` |
| `checkUpgradeResult:` | 1043 `APP_CMD_GET_UPGRADE_RESULT` |
| `checkUpgradeResultBy:chl:` | 1043 `APP_CMD_GET_UPGRADE_RESULT` |
| `collect:chl:path:recordid:userid:` | 1047 `APP_CMD_COLLECT_RECORD` |
| `collect:path:recordid:task:` | 1047 `APP_CMD_COLLECT_RECORD` |
| `db_setChargeModeDic:task:` | 1714 `CMD_BAT_DOORBELL_SET_AC_VALUE` |
| `db_setChargeModeDic:userid:chl:` | 1350 `CMD_SET_PAYLOAD` |
| `dc_setTossMusicSettingWithDic:userid:chl:` | 1350 `CMD_SET_PAYLOAD` |
| `delAiUserBy:Chl:userid:` | 1232 `APP_CMD_DEL_USER_PHOTO` |
| `delAiUserBy:task:` | 1216 `APP_CMD_SET_HUB_NAME`, 1232 `APP_CMD_DEL_USER_PHOTO` |
| `deleteGeofenceInfo:task:` | 1261 `APP_CMD_GEO_DEL_USER_INFO`, 1604 `APP_CMD_MOTION_SENSOR_GET_INFO` |
| `deleteGeofenceInfo:userid:chl:` | 1261 `APP_CMD_GEO_DEL_USER_INFO` |
| `deleteRecord:chl:recordid:userid:` | 1027 `APP_CMD_DELLETE_RECORD` |
| `deleteRecord:recordid:task:` | 1027 `APP_CMD_DELLETE_RECORD` |
| `ec_setRecordingWithoutAudioDic:userid:chl:` | 1350 `CMD_SET_PAYLOAD` |
| `endRecordVideo:` | 1010 `APP_CMD_STOP_RECORD` |
| `endRecordVideo:userid:` | 1010 `APP_CMD_STOP_RECORD` |
| `eufylink_send_commandWithChl:cmd:v1:v2:v3:` | 1104 `APP_CMD_GET_RECORD_TIME` |
| `eventVideoStop:randomNum:chl:` | 1026 `APP_CMD_RECORD_PLAY_CTRL` |
| `factoryDev:` | 1037 `APP_CMD_DEVS_TO_FACTORY` |
| `factoryDevBy:` | 1037 `APP_CMD_DEVS_TO_FACTORY` |
| `factoryHubBy:chl:` | 1036 `APP_CMD_HUB_TO_FACTORY` |
| `fl_responseToGetDevicePingTask:` | 1152 `APP_CMD_GET_DEVICE_PING` |
| `fl_responseToGetDevicePingUserid:chl:` | 1152 `APP_CMD_GET_DEVICE_PING` |
| `fl_sendLocateInfo:open:chl:userid:` | 1016 `APP_CMD_CLOSE_EAS`, 1136 `CMD_GET_CHARGE_STATUS`, 1414 `APP_CMD_SET_LIGHT_CTRL_SUNRISE_SWITCH` |
| `fl_sendLocateInfo:open:task:` | 1200 `APP_CMD_SET_LANGUAGE`, 1414 `APP_CMD_SET_LIGHT_CTRL_SUNRISE_SWITCH` |
| `fl_setDeviceAlarmVolumn:chl:userid:` | 1230 `APP_CMD_SET_DEV_SPEAKER_VOLUME` |
| `fl_setLampLightValue:chl:userid:` | 1410 `APP_CMD_SET_LIGHT_CTRL_LAMP_VALUE` |
| `fl_setLampLightValue:task:` | 1410 `APP_CMD_SET_LIGHT_CTRL_LAMP_VALUE` |
| `fl_setMotionLevel:chl:userid:` | 1272 `APP_CMD_SET_MDSENSITIVITY` |
| `fl_setMotionLevel:task:` | 1272 `APP_CMD_SET_MDSENSITIVITY` |
| `fl_setPirLightSwith:chl:userid:` | 1408 `APP_CMD_SET_LIGHT_CTRL_PIR_SWITCH` |
| `fl_setPirLightSwith:task:` | 1408 `APP_CMD_SET_LIGHT_CTRL_PIR_SWITCH` |
| `fl_setPirLightTime:chl:userid:` | 1409 `APP_CMD_SET_LIGHT_CTRL_PIR_TIME` |
| `fl_setPirLightTime:task:` | 1409 `APP_CMD_SET_LIGHT_CTRL_PIR_TIME` |
| `fl_setRecordingWithoutAudioDic:userid:chl:` | 1350 `CMD_SET_PAYLOAD` |
| `fl_setSpeakerVolume:task:` | 2100 `CMD_SMART_DROP_OPEN_LID` |
| `fl_setSpeakerVolume:userid:chl:` | 1230 `APP_CMD_SET_DEV_SPEAKER_VOLUME` |
| `fl_setTotalLightSwitch:chl:userid:` | 1403 `APP_CMD_SET_FLOODLIGHT_TOTAL_SWITCH` |
| `fl_setTotalLightSwitch:task:` | 1403 `APP_CMD_SET_FLOODLIGHT_TOTAL_SWITCH` |
| `formatSDCard:` | 1029 `APP_CMD_FORMAT_SD` |
| `formatSDCardBy:chl:` | 1029 `APP_CMD_FORMAT_SD` |
| `getCameraNSAOpenSwitch:channel:userid:` | 1146 `APP_CMD_NAS_TEST` |
| `getCameraNSAOpenSwitch:task:` | 1146 `APP_CMD_NAS_TEST` |
| `getCameraNSAURLSwitch:channel:userid:` | 1145 `APP_CMD_NAS_SWITCH` |
| `getCameraNSAURLSwitch:task:` | 1145 `APP_CMD_NAS_SWITCH` |
| `getDeviceBatteryInfo:` | 1101 `APP_CMD_GET_BATTERY` |
| `getDeviceBatteryInfoBy:` | 1101 `APP_CMD_GET_BATTERY` |
| `getDeviceInfo:` | 1103 `APP_CMD_CAMERA_INFO` |
| `getDeviceInfoType:` | 1103 `APP_CMD_CAMERA_INFO` |
| `getDoorBellHomeBaseWifi:` | 1192 `CMD_GET_DETECTED_EVENTS_HB3` |
| `getFloodLightWiFiListTask:` | 1405 `APP_CMD_GET_FLOODLIGHT_WIFI_LIST` |
| `getFloodLightWiFiListWithUserid:chl:` | 1405 `APP_CMD_GET_FLOODLIGHT_WIFI_LIST` |
| `getHomeBaseDevRssiList:` | 1274 `APP_CMD_GET_DEVS_RSSI_LIST` |
| `getHomeBaseDevRssiListWithUserid:chl:` | 1274 `APP_CMD_GET_DEVS_RSSI_LIST` |
| `getHomeBaseWanLinkStatusTask:` | 1268 `APP_CMD_GET_WAN_LINK_STATUS`, 2100 `CMD_SMART_DROP_OPEN_LID` |
| `getHomeBaseWanLinkStatusWithUserid:chl:` | 1268 `APP_CMD_GET_WAN_LINK_STATUS` |
| `getHomeBaseWiFiListTask:` | 1263 `APP_CMD_GET_REPEATER_SITE_LIST` |
| `getHomeBaseWiFiListWithUserid:chl:` | 1263 `APP_CMD_GET_REPEATER_SITE_LIST` |
| `getHubLog:chl:type:userid:` | 1132 `APP_CMD_GET_HUB_LOG` |
| `getHubLog:type:task:` | 1132 `APP_CMD_GET_HUB_LOG` |
| `getRepeaterConnResult:` | 1270 `CMD_GET_REPEATER_CONN_TEST_RESULT` |
| `getRepeaterConnResultBy:chl:` | 1270 `CMD_GET_REPEATER_CONN_TEST_RESULT` |
| `getSDCardFormatStatus:` | 1143 `CMD_GET_TFCARD_FORMAT_STATUS` |
| `getSDCardFormatStatusBy:chl:` | 1143 `CMD_GET_TFCARD_FORMAT_STATUS` |
| `getSDCardInfo:` | 1102 `APP_CMD_SDINFO` |
| `getSDCardInfoBy:chl:` | 1102 `APP_CMD_SDINFO` |
| `getSDCardInfoEX:` | 1144 `CMD_SDINFO_EX` |
| `getSDCardInfoEXBy:chl:` | 1144 `CMD_SDINFO_EX` |
| `getSDCardRepairStatus:` | 1153 `CMD_GET_TFCARD_REPAIR_STATUS` |
| `getSDCardRepairStatusBy:chl:` | 1153 `CMD_GET_TFCARD_REPAIR_STATUS` |
| `getSunriseLocationJson:` | 1415 `APP_CMD_SET_LIGHT_CTRL_SUNRISE_INFO` |
| `getSunriseLocationJson:userid:` | 1415 `APP_CMD_SET_LIGHT_CTRL_SUNRISE_INFO` |
| `handleTask:logparam:cmd:cb:` | 1000 `CMD_BIND_BROADCAST`, 1003 `APP_CMD_START_REALTIME_MEDIA`, 1004 `APP_CMD_STOP_REALTIME_MEDIA`, 1016 `APP_CMD_CLOSE_EAS`, 1024 `APP_CMD_DOWNLOAD_VIDEO`, 1025 `APP_CMD_RECORD_VIEW`, 1026 `APP_CMD_RECORD_PLAY_CTRL`, 1040 `APP_CMD_DEVS_UNBIND`, 1056 `APP_CMD_LIVEVIEW_LED_SWITCH`, 1072 `CMD_SET_CROSS_TRACKING_CAMERA_LIST`, 1120 `APP_CMD_GET_GATEWAY_LOCK`, 1139 `CMD_PING`, 6001 `CMD_SMARTLOCK_QUERY_BATTERY_LEVEL` |
| `homebaseUpdate:` | 1238 `APP_CMD_SET_UPGRADE` |
| `homebaseUpdateBy:chl:` | 1238 `APP_CMD_SET_UPGRADE` |
| `hubClearEMMCVolume:` | 1800 `CMD_HUB_CLEAR_EMMC_VOLUME` |
| `hubClearEMMCVolumeBy:chl:` | 1800 `CMD_HUB_CLEAR_EMMC_VOLUME` |
| `isValidJSONObject:` | 1120 `APP_CMD_GET_GATEWAY_LOCK` |
| `localVideoStream:userid:chl:` | 1024 `APP_CMD_DOWNLOAD_VIDEO` |
| `localVideoStreamDownload:` | 1024 `APP_CMD_DOWNLOAD_VIDEO`, 1120 `APP_CMD_GET_GATEWAY_LOCK` |
| `localVideoStreamDownloadResult:result:` | 1024 `APP_CMD_DOWNLOAD_VIDEO` |
| `localVideoStreamResult:userid:chl:publicKey:` | 1024 `APP_CMD_DOWNLOAD_VIDEO`, 1216 `APP_CMD_SET_HUB_NAME` |
| `logTaskResult:isRtc:cmd:code:result:msg:connectTime:commandTime:connectSuc:initSuc:sessionId:logparam:` | 1008 `APP_CMD_STOP_VOICECALL`, 1408 `APP_CMD_SET_LIGHT_CTRL_PIR_SWITCH`, 1504 `CMD_DOOR_SENSOR_LOW_POWER_REPORT` |
| `motionSensorExitTestModeByUserid:chl:` | 1610 `APP_CMD_MOTION_SENSOR_EXIT_USER_TEST_MODE` |
| `motionSensorExitTestModeTask:` | 1056 `APP_CMD_LIVEVIEW_LED_SWITCH`, 1610 `APP_CMD_MOTION_SENSOR_EXIT_USER_TEST_MODE` |
| `notifyHandlerMan` | 1112 `APP_CMD_GET_MIRRORMODE` |
| `p2pSendBindHub3RequestWithPayload:userid:chl:` | 1060 `APP_CMD_HB3_BIND_CODE` |
| `p2pSendRequestWithPayload:cmd:logParam:task:` | 1003 `APP_CMD_START_REALTIME_MEDIA`, 1008 `APP_CMD_STOP_VOICECALL`, 1072 `CMD_SET_CROSS_TRACKING_CAMERA_LIST`, 1664 `CMD_KEYPAD_PSW_OPEN` |
| `p2pSendRequestWithPayloadExt:cmd:logParam:task:` | 1003 `APP_CMD_START_REALTIME_MEDIA`, 1008 `APP_CMD_STOP_VOICECALL`, 1072 `CMD_SET_CROSS_TRACKING_CAMERA_LIST`, 1664 `CMD_KEYPAD_PSW_OPEN` |
| `p2p_handleTask:logparam:cmd:cb:` | 1032 `APP_CMD_WIFI_CONFIG`, 1152 `APP_CMD_GET_DEVICE_PING`, 1216 `APP_CMD_SET_HUB_NAME`, 1248 `APP_CMD_SET_NOTFACE_PUSHMSG`, 1280 `CMD_SET_HUB_ALARM_AUTO_END`, 1408 `APP_CMD_SET_LIGHT_CTRL_PIR_SWITCH` |
| `p2p_sendCommandWithChl:cmd:param1:param2:param3:task:` | 1120 `APP_CMD_GET_GATEWAY_LOCK` |
| `pirTestmode:chl:userid:` | 1243 `APP_CMD_SET_PIR_TEST_MODE` |
| `pirTestmode:task:` | 1243 `APP_CMD_SET_PIR_TEST_MODE` |
| `receiveCameraBroadcast:Chl:devType:userid:` | 1038 `APP_CMD_DEVS_BIND_BROADCASE` |
| `receiveCameraBroadcast:devType:dele:task:` | 1038 `APP_CMD_DEVS_BIND_BROADCASE`, 1128 `APP_CMD_GET_HUB_NAME` |
| `repairSDCard:` | 1057 `APP_CMD_REPAIR_SD` |
| `repairSDCardBy:Chl:` | 1057 `APP_CMD_REPAIR_SD` |
| `repeaterRssiTest:task:` | 1269 `APP_CMD_REPEATER_RSSI_TEST` |
| `repeaterRssiTest:userid:chl:` | 1269 `APP_CMD_REPEATER_RSSI_TEST` |
| `resetDeviceBychl:chl:` | 1037 `APP_CMD_DEVS_TO_FACTORY` |
| `resetFloodLightWifi:bssid:wifiPwd:authType:security:task:` | 1208 `APP_CMD_SET_IRMODE` |
| `resetFloodLightWifi:bssid:wifiPwd:authType:task:` | 1406 `APP_CMD_SET_FLOODLIGHT_WIFI_CONNECT` |
| `resetFloodLightWifi:bssid:wifiPwd:userid:authType:chl:` | 1406 `APP_CMD_SET_FLOODLIGHT_WIFI_CONNECT` |
| `resetFloodLightWifi:bssid:wifiPwd:userid:authType:security:chl:` | 1406 `APP_CMD_SET_FLOODLIGHT_WIFI_CONNECT` |
| `resetFloodLightWifi:bssid:wifiPwd:userid:chl:` | 1406 `APP_CMD_SET_FLOODLIGHT_WIFI_CONNECT` |
| `resetHubByUserid:chl:` | 1036 `APP_CMD_HUB_TO_FACTORY` |
| `restartHub:` | 1034 `APP_CMD_HUB_REBOOT` |
| `restartHubByUserid:chl:` | 1034 `APP_CMD_HUB_REBOOT` |
| `rtc_handleTask:logparam:cmd:cb:` | 1000 `CMD_BIND_BROADCAST`, 1003 `APP_CMD_START_REALTIME_MEDIA`, 1072 `CMD_SET_CROSS_TRACKING_CAMERA_LIST`, 1280 `CMD_SET_HUB_ALARM_AUTO_END`, 1408 `APP_CMD_SET_LIGHT_CTRL_PIR_SWITCH`, 1664 `CMD_KEYPAD_PSW_OPEN` |
| `sendBindCamWithSupportV2RequestWithPayload:task:` | 1001 `APP_CMD_BIND_SYNC_ACCOUNT_INFO`, 1008 `APP_CMD_STOP_VOICECALL`, 1040 `APP_CMD_DEVS_UNBIND` |
| `sendBindHub3RequestWithPayload:task:` | 1000 `CMD_BIND_BROADCAST`, 1040 `APP_CMD_DEVS_UNBIND`, 1060 `APP_CMD_HB3_BIND_CODE`, 1176 `CMD_GET_HUB_LAN_IP` |
| `sendDoorBellCommand:` | 1000 `CMD_BIND_BROADCAST`, 1008 `APP_CMD_STOP_VOICECALL`, 1072 `CMD_SET_CROSS_TRACKING_CAMERA_LIST`, 1152 `APP_CMD_GET_DEVICE_PING`, 1608 `APP_CMD_MOTION_SENSOR_ALARM_ENABLE`, 1664 `CMD_KEYPAD_PSW_OPEN`, 1700 `CMD_DOORBELL_SET_PAYLOAD`, 6001 `CMD_SMARTLOCK_QUERY_BATTERY_LEVEL` |
| `sendDoorBellData:ivalue:chl:` | 1016 `APP_CMD_CLOSE_EAS`, 1700 `CMD_DOORBELL_SET_PAYLOAD` |
| `sendDoorBellHomeBaseWifi:chl:` | 1016 `APP_CMD_CLOSE_EAS` |
| `sendHB3DetectionType:type:channel:` | 1008 `APP_CMD_STOP_VOICECALL`, 1298 `CMD_SET_MOTION_DETECTION_TYPE_HB3` |
| `sendHB3DiskinfoReqCommand:version:payload:cmd:` | 1008 `APP_CMD_STOP_VOICECALL`, 1307 `CMD_STORAGE_INFO_HB3` |
| `sendNewHB3Type:pub_key:` | 1008 `APP_CMD_STOP_VOICECALL`, 1350 `CMD_SET_PAYLOAD` |
| `sendPayloadCommand:` | 1152 `APP_CMD_GET_DEVICE_PING`, 1350 `CMD_SET_PAYLOAD` |
| `sendPayloadCommand:ivalue:chl:` | 1016 `APP_CMD_CLOSE_EAS`, 1350 `CMD_SET_PAYLOAD` |
| `sendPingToDeviceChannel:userid:isRTC:` | 1139 `CMD_PING` |
| `sendPingToDeviceTask:` | 1139 `CMD_PING` |
| `sendVoiceTalkStatus:channel:isRTC:` | 1005 `APP_CMD_START_TALKBACK`, 1006 `APP_CMD_STOP_TALKBACK` |
| `sendVoiceTalkStatus:task:` | 1005 `APP_CMD_START_TALKBACK` |
| `sessionWith:sn:initStr:` | 1000 `CMD_BIND_BROADCAST`, 1056 `APP_CMD_LIVEVIEW_LED_SWITCH`, 2700 `CMD_DOORBELL_DUAL_VIEW_MODE` |
| `setAIDetectionSwith:chl:userid:` | 1236 `APP_CMD_SET_AI_SWITCH` |
| `setAIDetectionSwith:task:` | 1236 `APP_CMD_SET_AI_SWITCH` |
| `setAINicknamefaceuser:Chl:faceid:nickname:notify:userid:` | 1242 `APP_CMD_SET_AI_NICKNAME` |
| `setAINicknamefaceuser:faceid:nickname:notify:task:` | 1242 `APP_CMD_SET_AI_NICKNAME` |
| `setAIPhoto:Chl:faceuser:faceid:groupid:nickname:notify:facepoint:userid:` | 1231 `APP_CMD_SET_AI_PHOTO` |
| `setAIPhoto:faceuser:faceid:groupid:nickname:notify:facepoint:task:` | 1231 `APP_CMD_SET_AI_PHOTO` |
| `setAlarm:chl:userid:` | 1202 `APP_CMD_SET_DEVS_TONE_FILE` |
| `setAlarm:task:` | 1202 `APP_CMD_SET_DEVS_TONE_FILE` |
| `setAllPIRAction:task:` | 1255 `APP_CMD_SET_ALL_ACTION`, 1280 `CMD_SET_HUB_ALARM_AUTO_END` |
| `setAllPIRAction:userid:chl:` | 1255 `APP_CMD_SET_ALL_ACTION` |
| `setAntiTheft:chl:userid:` | 1015 `APP_CMD_EAS_SWITCH` |
| `setAntiTheft:task:` | 1015 `APP_CMD_EAS_SWITCH` |
| `setArmingSchedule:chl:sereverConfig:userid:chl:` | 1211 `APP_CMD_SET_ARMING_SCHEDULE` |
| `setArmingSchedule:sereverConfig:task:` | 1211 `APP_CMD_SET_ARMING_SCHEDULE` |
| `setAsServer:chl:server:` | 1237 `APP_CMD_SET_AS_SERVER` |
| `setAsServer:task:` | 1237 `APP_CMD_SET_AS_SERVER` |
| `setAudioDetect:chl:userid:` | 1017 `APP_CMD_AUDDEC_SWITCH` |
| `setAudioDetect:task:` | 1017 `APP_CMD_AUDDEC_SWITCH`, 1152 `APP_CMD_GET_DEVICE_PING` |
| `setAudiosensiBysens:task:` | 1227 `APP_CMD_SET_AUDIOSENSITIVITY` |
| `setAudiosensiBysens:userid:chl:` | 1227 `APP_CMD_SET_AUDIOSENSITIVITY` |
| `setBSArming:task:` | 1224 `APP_CMD_SET_ALARM_MODE` |
| `setBSArming:userid:chl:` | 1224 `APP_CMD_SET_ALARM_MODE` |
| `setBVDCHIME_SWITCH:chl:userid:` | 1702 `CMD_BAT_DOORBELL_CHIME_SWITCH` |
| `setBVDCHIME_SWITCH:task:` | 1702 `CMD_BAT_DOORBELL_CHIME_SWITCH` |
| `setBVDELECTRONIC_RINGTONE_TIME:chl:userid:` | 1709 `CMD_BAT_DOORBELL_SET_ELECTRONIC_RINGTONE_TIME` |
| `setBVDELECTRONIC_RINGTONE_TIME:task:` | 1709 `CMD_BAT_DOORBELL_SET_ELECTRONIC_RINGTONE_TIME` |
| `setBVDMECHANICAL_CHIME_SWITCH:chl:userid:` | 1703 `CMD_BAT_DOORBELL_MECHANICAL_CHIME_SWITCH` |
| `setBVDMECHANICAL_CHIME_SWITCH:task:` | 1703 `CMD_BAT_DOORBELL_MECHANICAL_CHIME_SWITCH` |
| `setBVDNotificationOnOff:chl:userid:` | 1710 `CMD_BAT_DOORBELL_SET_NOTIFICATION_MODE` |
| `setBVDNotificationOnOff:task:` | 1710 `CMD_BAT_DOORBELL_SET_NOTIFICATION_MODE` |
| `setBVDQUICK_RESPONSE:chl:userid:` | 1706 `CMD_BAT_DOORBELL_QUICK_RESPONSE` |
| `setBVDQUICK_RESPONSE:task:` | 1706 `CMD_BAT_DOORBELL_QUICK_RESPONSE` |
| `setBVDRINGTONE_VOLUME:chl:userid:` | 1708 `CMD_BAT_DOORBELL_SET_RINGTONE_VOLUME` |
| `setBVDRINGTONE_VOLUME:task:` | 1708 `CMD_BAT_DOORBELL_SET_RINGTONE_VOLUME` |
| `setBVDUPDATE_QUICK_RESPONSE:mediaUrl:chl:userid:` | 1707 `CMD_BAT_DOORBELL_UPDATE_QUICK_RESPONSE` |
| `setBVDUPDATE_QUICK_RESPONSE:mediaUrl:task:` | 1707 `CMD_BAT_DOORBELL_UPDATE_QUICK_RESPONSE` |
| `setBVDVIDEO_QUALITY:chl:userid:` | 1705 `CMD_BAT_DOORBELL_VIDEO_QUALITY` |
| `setBVDVIDEO_QUALITY:task:` | 1705 `CMD_BAT_DOORBELL_VIDEO_QUALITY` |
| `setBVDWDR_SWITCH:chl:userid:` | 1704 `CMD_BAT_DOORBELL_WDR_SWITCH` |
| `setBVDWDR_SWITCH:task:` | 1704 `CMD_BAT_DOORBELL_WDR_SWITCH` |
| `setBitrate:task:` | 1206 `APP_CMD_SET_BITRATE` |
| `setBitrateByUserid:chl:type:` | 1206 `APP_CMD_SET_BITRATE` |
| `setCamArmMode:chl:userid:` | 1233 `APP_CMD_SET_PIR_ACTION` |
| `setCamArmMode:task:` | 1233 `APP_CMD_SET_PIR_ACTION` |
| `setCameraActivityZones:channel:userid:` | 1204 `APP_CMD_SET_MDETECTPARAM` |
| `setCameraActivityZones:task:` | 1204 `APP_CMD_SET_MDETECTPARAM`, 1216 `APP_CMD_SET_HUB_NAME` |
| `setCameraPushInterval:task:` | 1552 `CMD_ENTRY_SENSOR_BAT_STATE` |
| `setCameraRecordAutoStop:chl:userid:` | 1251 `APP_CMD_DEV_RECORD_AUTOSTOP` |
| `setCameraRecordAutoStop:task:` | 1251 `APP_CMD_DEV_RECORD_AUTOSTOP` |
| `setCameraRecordInterval:chl:userid:` | 1250 `APP_CMD_DEV_RECORD_INTERVAL` |
| `setCameraRecordInterval:task:` | 1250 `APP_CMD_DEV_RECORD_INTERVAL`, 1260 `APP_CMD_GEO_UPDATE_USER_INFO` |
| `setCameraRecordTimeout:chl:userid:` | 1249 `APP_CMD_DEV_RECORD_TIMEOUT` |
| `setCameraRecordTimeout:task:` | 1249 `APP_CMD_DEV_RECORD_TIMEOUT` |
| `setCameraSwith:chl:userid:` | 1011 `APP_CMD_PIR_SWITCH` |
| `setCameraSwith:task:` | 1011 `APP_CMD_PIR_SWITCH` |
| `setCameraVideoQaulity:chl:userid:` | 1705 `CMD_BAT_DOORBELL_VIDEO_QUALITY` |
| `setCameraVideoQaulity:task:` | 1705 `CMD_BAT_DOORBELL_VIDEO_QUALITY` |
| `setCloudStorageDate:chl:userid:` | 1228 `CMD_SET_DEV_STORAGE_TYPE` |
| `setCloudStorageDate:task:` | 1228 `CMD_SET_DEV_STORAGE_TYPE` |
| `setCustMode:task:` | 1120 `APP_CMD_GET_GATEWAY_LOCK`, 1256 `APP_CMD_SET_CUSTOM_MODE` |
| `setCustMode:userid:chl:` | 1256 `APP_CMD_SET_CUSTOM_MODE` |
| `setDefaultPIRMode:task:` | 1257 `APP_CMD_SET_SCHEDULE_DEFAULT` |
| `setDefaultPIRMode:userid:chl:` | 1257 `APP_CMD_SET_SCHEDULE_DEFAULT` |
| `setDeviceName:chl:userid:` | 1217 `APP_CMD_SET_DEVS_NAME` |
| `setDeviceName:task:` | 1217 `APP_CMD_SET_DEVS_NAME` |
| `setDeviceSwitch:chl:userid:` | 1035 `APP_CMD_DEVS_SWITCH` |
| `setDeviceSwitch:task:` | 1035 `APP_CMD_DEVS_SWITCH` |
| `setDevsOSDLogo:userid:chl:` | 1214 `APP_CMD_SET_DEVS_OSD` |
| `setDevsOSDMode:userid:chl:` | 1214 `APP_CMD_SET_DEVS_OSD` |
| `setDevsOSDStatus:userid:chl:` | 1214 `APP_CMD_SET_DEVS_OSD` |
| `setDoorbellDeviceVolume:userID:chl:` | 1230 `APP_CMD_SET_DEV_SPEAKER_VOLUME` |
| `setFLSearchLight:flMod:task:` | 1400 `APP_CMD_SET_FLOODLIGHT_MANUAL_SWITCH` |
| `setFLSearchLight:userid:flMod:` | 1400 `APP_CMD_SET_FLOODLIGHT_MANUAL_SWITCH` |
| `setFLStreetLampSwitch:task:` | 1402 `APP_CMD_SET_FLOODLIGHT_STREET_LAMP` |
| `setFLStreetLampSwitch:userid:chl:` | 1402 `APP_CMD_SET_FLOODLIGHT_STREET_LAMP` |
| `setFloodlightActivityZones:task:` | 1204 `APP_CMD_SET_MDETECTPARAM`, 1216 `APP_CMD_SET_HUB_NAME` |
| `setFloodlightActivityZones:userid:chl:` | 1204 `APP_CMD_SET_MDETECTPARAM` |
| `setFloodlightLightSchedule:sereverConfig:task:` | 1404 `APP_CMD_SET_FLOODLIGHT_LIGHT_SCHEDULE` |
| `setFloodlightLightSchedule:sereverConfig:userid:chl:` | 1404 `APP_CMD_SET_FLOODLIGHT_LIGHT_SCHEDULE` |
| `setFloodlightLightScheduleJson:task:` | 1404 `APP_CMD_SET_FLOODLIGHT_LIGHT_SCHEDULE` |
| `setFloodlightLightScheduleJson:userid:chl:` | 1404 `APP_CMD_SET_FLOODLIGHT_LIGHT_SCHEDULE` |
| `setGSsensiBysens:task:` | 1226 `APP_CMD_SET_GSSENSITIVITY` |
| `setGSsensiBysens:userid:chl:` | 1226 `APP_CMD_SET_GSSENSITIVITY` |
| `setGlobalPirStatus:task:` | 1218 `APP_CMD_SET_HUB_PIR_STATUS` |
| `setGlobalPirStatusByUserid:chl:oepn:` | 1218 `APP_CMD_SET_HUB_PIR_STATUS` |
| `setGlobalRecordTime:task:` | 1203 `APP_CMD_SET_RECORDTIME` |
| `setGlobalRecordTimeByUserid:chl:sec:` | 1203 `APP_CMD_SET_RECORDTIME` |
| `setGlobalStorageType:task:` | 1223 `APP_CMD_SET_STORGE_TYPE` |
| `setGlobalStorageTypeByUserid:type:chl:` | 1223 `APP_CMD_SET_STORGE_TYPE` |
| `setHomeBaseRepeaterEnable:ssid:bssid:security:password:task:` | 1264 `APP_CMD_SET_REPEATER_PARAMS` |
| `setHomeBaseRepeaterEnable:ssid:bssid:security:password:userid:chl:` | 1016 `APP_CMD_CLOSE_EAS`, 1264 `APP_CMD_SET_REPEATER_PARAMS` |
| `setHubAudioVolumn:chl:vol:` | 1235 `APP_CMD_SET_HUB_SPK_VOLUME` |
| `setHubAudioVolumn:task:` | 1235 `APP_CMD_SET_HUB_SPK_VOLUME` |
| `setHubName:Chl:userid:` | 1216 `APP_CMD_SET_HUB_NAME` |
| `setHubName:task:` | 1216 `APP_CMD_SET_HUB_NAME` |
| `setHubOSD24H:task:` | 1056 `APP_CMD_LIVEVIEW_LED_SWITCH`, 1253 `APP_CMD_SET_HUB_OSD` |
| `setHubOSD24H:userid:chl:` | 1253 `APP_CMD_SET_HUB_OSD` |
| `setIDCMirrormode:task:` | 1207 `APP_CMD_SET_MIRRORMODE` |
| `setIDCMirrormodeByUserid:chl:type:` | 1207 `APP_CMD_SET_MIRRORMODE` |
| `setIndoorCamNightVisionSwith:task:` | 1013 `APP_CMD_IRCUT_SWITCH` |
| `setIndoorNightVisionSwith:chl:userid:` | 1013 `APP_CMD_IRCUT_SWITCH` |
| `setJsonSchedule:task:` | 1254 `APP_CMD_SET_JSON_SCHEDULE` |
| `setJsonSchedule:userid:chl:` | 1254 `APP_CMD_SET_JSON_SCHEDULE` |
| `setLEDSwith:chl:userid:` | 1045 `APP_CMD_DEV_LED_SWITCH` |
| `setLEDSwith:task:` | 1045 `APP_CMD_DEV_LED_SWITCH` |
| `setLanguageBySystem:` | 1112 `APP_CMD_GET_MIRRORMODE`, 1152 `APP_CMD_GET_DEVICE_PING`, 1200 `APP_CMD_SET_LANGUAGE` |
| `setLanguageBySystemBy:chl:` | 1200 `APP_CMD_SET_LANGUAGE` |
| `setLiveViewLedSwitch:chl:userid:` | 1056 `APP_CMD_LIVEVIEW_LED_SWITCH` |
| `setLiveViewLedSwitch:task:` | 1056 `APP_CMD_LIVEVIEW_LED_SWITCH`, 1256 `APP_CMD_SET_CUSTOM_MODE` |
| `setLockState:chl:userid:` | 1019 `APP_CMD_DEVS_LOCK_SWITCH` |
| `setLockState:task:` | 1019 `APP_CMD_DEVS_LOCK_SWITCH` |
| `setMicrophoneGain:task:` | 1229 `APP_CMD_SET_DEV_MIC_VOLUME` |
| `setMicrophoneGain:userid:chl:` | 1229 `APP_CMD_SET_DEV_MIC_VOLUME` |
| `setMicrophoneOFF:task:` | 1216 `APP_CMD_SET_HUB_NAME`, 1240 `APP_CMD_SET_DEV_MIC_MUTE` |
| `setMicrophoneOFF:userid:chl:` | 1240 `APP_CMD_SET_DEV_MIC_MUTE` |
| `setMirrormode:task:` | 1207 `APP_CMD_SET_MIRRORMODE` |
| `setMirrormodeByUserid:chl:type:` | 1207 `APP_CMD_SET_MIRRORMODE` |
| `setMotionSensorBysens:task:` | 1609 `APP_CMD_MOTION_SENSOR_SET_PIR_SENSITIVITY` |
| `setMotionSensorPIRByUserid:chl:sens:` | 1609 `APP_CMD_MOTION_SENSOR_SET_PIR_SENSITIVITY` |
| `setNOFacePushMSGSwith:task:` | 1248 `APP_CMD_SET_NOTFACE_PUSHMSG` |
| `setNightVisionSwith:chl:userid:` | 1013 `APP_CMD_IRCUT_SWITCH` |
| `setNightVisionSwith:task:` | 1013 `APP_CMD_IRCUT_SWITCH` |
| `setNotFacePushMSGSwith:chl:userid:` | 1248 `APP_CMD_SET_NOTFACE_PUSHMSG` |
| `setOutsiderDetectedVideoClips:channel:userid:` | 1273 `APP_CMD_SET_DEV_MD_RECORD` |
| `setOutsiderDetectedVideoClips:task:` | 1248 `APP_CMD_SET_NOTFACE_PUSHMSG`, 1273 `APP_CMD_SET_DEV_MD_RECORD` |
| `setPIR:chl:userid:` | 1011 `APP_CMD_PIR_SWITCH` |
| `setPIR:task:` | 1011 `APP_CMD_PIR_SWITCH` |
| `setPIRPowerMode:chl:userid:` | 1246 `APP_CMD_SET_PIR_POWERMODE` |
| `setPIRPowerMode:task:` | 1246 `APP_CMD_SET_PIR_POWERMODE` |
| `setPIRsensi:task:` | 1210 `APP_CMD_SET_PIRSENSITIVITY`, 1236 `APP_CMD_SET_AI_SWITCH` |
| `setPIRsensiByUserid:chl:sens:` | 1210 `APP_CMD_SET_PIRSENSITIVITY` |
| `setParamCommondFunc:logParam:task:` | 1912 `CMD_DOORLOCK_GET_STATE` |
| `setPirSpotLightSwitch:chl:userid:` | 1408 `APP_CMD_SET_LIGHT_CTRL_PIR_SWITCH` |
| `setPirSpotLightSwitch:task:` | 1408 `APP_CMD_SET_LIGHT_CTRL_PIR_SWITCH` |
| `setRecodeMute:task:` | 1288 `CMD_SET_AUDIO_MUTE_RECORD` |
| `setRecodeMute:userid:chl:` | 1288 `CMD_SET_AUDIO_MUTE_RECORD` |
| `setRepeatWifiConfig:task:` | 1264 `APP_CMD_SET_REPEATER_PARAMS` |
| `setRepeatWifiConfig:userid:chl:` | 1264 `APP_CMD_SET_REPEATER_PARAMS` |
| `setResolution:task:` | 1205 `APP_CMD_SET_RESOLUTION` |
| `setResolutionByUserid:chl:type:` | 1205 `APP_CMD_SET_RESOLUTION` |
| `setSensorAlarm:chl:userid:` | 1506 `CMD_DOOR_SENSOR_ALARM_ENABLE` |
| `setSensorAlarm:task:` | 1506 `CMD_DOOR_SENSOR_ALARM_ENABLE`, 2712 `CMD_DOORBELL_DUAL_PACKAGE_STRAND_SWITCH` |
| `setSensorAlarmChirp:chl:userid:` | 1507 `CMD_SENSOR_SET_CHIRP_TONE` |
| `setSensorAlarmChirp:task:` | 1507 `CMD_SENSOR_SET_CHIRP_TONE` |
| `setSmartNotificationMode:chl:userid:` | 1252 `APP_CMD_DEV_PUSHMSG_MODE` |
| `setSmartNotificationMode:task:` | 1252 `APP_CMD_DEV_PUSHMSG_MODE` |
| `setSnoozeMode:chl:userid:` | 1008 `APP_CMD_STOP_VOICECALL`, 1271 `APP_CMD_SET_SNOOZE_MODE` |
| `setSnoozeMode:task:` | 1271 `APP_CMD_SET_SNOOZE_MODE` |
| `setSpeakerOFF:task:` | 1241 `APP_CMD_SET_DEV_SPEAKER_MUTE` |
| `setSpeakerOFF:userid:chl:` | 1241 `APP_CMD_SET_DEV_SPEAKER_MUTE` |
| `setSpotLight:chl:userid:` | 1400 `APP_CMD_SET_FLOODLIGHT_MANUAL_SWITCH` |
| `setSpotLight:task:` | 1400 `APP_CMD_SET_FLOODLIGHT_MANUAL_SWITCH` |
| `setTimeZone:Chl:userid:` | 1215 `APP_CMD_SET_TIMEZONE` |
| `setTimeZone:task:` | 1215 `APP_CMD_SET_TIMEZONE` |
| `setWatermarkSwith:chl:userid:` | 1214 `APP_CMD_SET_DEVS_OSD` |
| `startFileVideoStream:userid:chl:` | 1025 `APP_CMD_RECORD_VIEW` |
| `startFileVideoStreamReulst:chnnel:userid:publicKey:` | 1025 `APP_CMD_RECORD_VIEW`, 1216 `APP_CMD_SET_HUB_NAME` |
| `startRTVideoStream:modStr:` | 1003 `APP_CMD_START_REALTIME_MEDIA`, 1032 `APP_CMD_WIFI_CONFIG` |
| `startRecordVideo:` | 1009 `APP_CMD_START_RECORD` |
| `startRecordVideo:userid:` | 1009 `APP_CMD_START_RECORD` |
| `synAccount:chl:` | 1001 `APP_CMD_BIND_SYNC_ACCOUNT_INFO` |
| `synAccountEx:Chl:userid:asDomain:name:timezone:` | 1054 `APP_CMD_BIND_SYNC_ACCOUNT_INFO_EX` |
| `synAccountEx:asDomain:name:timezone:task:` | 1040 `APP_CMD_DEVS_UNBIND`, 1054 `APP_CMD_BIND_SYNC_ACCOUNT_INFO_EX` |
| `synAccountExConnectType:asDomain:name:timezone:task:` | 1040 `APP_CMD_DEVS_UNBIND`, 1054 `APP_CMD_BIND_SYNC_ACCOUNT_INFO_EX`, 1664 `CMD_KEYPAD_PSW_OPEN` |
| `syncAccountInfo:` | 1001 `APP_CMD_BIND_SYNC_ACCOUNT_INFO` |
| `telnetOn:task:` | 1024 `APP_CMD_DOWNLOAD_VIDEO`, 1247 `APP_CMD_SET_TELNET` |
| `telnetOn:userid:chl:` | 1247 `APP_CMD_SET_TELNET` |
| `unbindAccount:task:` | 1002 `APP_CMD_UNBIND_ACCOUNT` |
| `unbindAccount:userid:chl:` | 1002 `APP_CMD_UNBIND_ACCOUNT` |
| `unbindDeviceBychl:userid:` | 1040 `APP_CMD_DEVS_UNBIND` |
| `unbindDeviceBytask:` | 1040 `APP_CMD_DEVS_UNBIND` |
| `updateFLMotionLightBrightness:task:` | 1412 `APP_CMD_SET_LIGHT_CTRL_BRIGHT_PIR`, 1664 `CMD_KEYPAD_PSW_OPEN` |
| `updateFLMotionLightBrightness:userid:chl:` | 1412 `APP_CMD_SET_LIGHT_CTRL_BRIGHT_PIR` |
| `updateFLScheduleLightBrightness:task:` | 1413 `APP_CMD_SET_LIGHT_CTRL_BRIGHT_SCH` |
| `updateFLScheduleLightBrightness:userid:chl:` | 1413 `APP_CMD_SET_LIGHT_CTRL_BRIGHT_SCH` |
| `updateFLSearchLight:chl:userid:value:` | 1401 `APP_CMD_SET_FLOODLIGHT_BRIGHT_VALUE` |
| `updateFLSearchLight:value:task:` | 1401 `APP_CMD_SET_FLOODLIGHT_BRIGHT_VALUE`, 1408 `APP_CMD_SET_LIGHT_CTRL_PIR_SWITCH` |
| `updateGeofenceInfo:task:` | 1252 `APP_CMD_DEV_PUSHMSG_MODE`, 1260 `APP_CMD_GEO_UPDATE_USER_INFO` |
| `updateGeofenceInfo:userid:chl:` | 1260 `APP_CMD_GEO_UPDATE_USER_INFO` |
| `updateGeofencoLocSetting:task:` | 1262 `APP_CMD_GEO_UPDATE_LOC_SETTING` |
| `updateGeofencoLocSetting:userid:chl:` | 1262 `APP_CMD_GEO_UPDATE_LOC_SETTING` |
| `updateSpotLightBrightness:chl:userid:` | 1401 `APP_CMD_SET_FLOODLIGHT_BRIGHT_VALUE` |
| `updateSpotLightBrightness:task:` | 1401 `APP_CMD_SET_FLOODLIGHT_BRIGHT_VALUE`, 1408 `APP_CMD_SET_LIGHT_CTRL_PIR_SWITCH` |
| `videoStreamSlidControl:` | 1026 `APP_CMD_RECORD_PLAY_CTRL` |
| `videoStreamSlidControl:frameNumber:chl:` | 1026 `APP_CMD_RECORD_PLAY_CTRL` |
| `waitForRTCDevice:timeout:` | 1072 `CMD_SET_CROSS_TRACKING_CAMERA_LIST` |
