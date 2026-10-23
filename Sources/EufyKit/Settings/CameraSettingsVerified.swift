extension CameraSettingsCatalog {
    /// Writes confirmed on the user's hardware with `eufynized-settings --verify` (set → read back → restore),
    /// keyed by cloud device_type. A setting not listed here is shown read-only.
    /// - 105 Indoor Cam E30 (Kodi Cam, 2026-10-21): verified with the generated recipes, including the ones
    ///   written with a different command than they're read from (status LED → 1045, motion detection → 1011,
    ///   auto night vision → 1013). Sensitivity, audio recording and notification type are recipe-ready but
    ///   unconfirmed: the HomeBase stopped answering reads mid-run (every value was restored and re-read).
    /// - 26 eufyCam S3 Pro (Front door, 2026-10-21): status LED, motion detection, watermark, mic, speaker,
    ///   volume and motion sensitivity set/read/restored; audio recording (stored as "mute", decoded inverted)
    ///   and night vision (incl. the app-only mode 6) confirmed while repairing the camera to its snapshot.
    /// - 48 SoloCam S340 (Front360, 2026-10-21): 10 settings set/read/restored; snapshot compared afterwards.
    /// - 8 eufyCam 2C (Back_laundry, 2026-10-21): 10 settings set/read/restored, plus motion sensitivity, which
    ///   stores device codes (step 4 = 46) and is decoded back to steps; snapshot compared afterwards.
    /// Recording clip length / retrigger interval / end-clip-early (1249/1250/1251) and the E30's notification
    /// interval (1250) verified on all four types once sent as station scalars (eufy-sdk's form); as direct
    /// values they had stalled the HomeBase.
    /// Not tested on purpose (the user asked that camera power not be toggled), so not listed here; the app
    /// still offers them and reads the result back: camera on/off on every type, and the 2C's power source.
    static let verified: [Int: Set<String>] = [
        105: ["watermark", "microphone", "speaker", "speakerVolume", "imageMirrored", "autoNightvision",
              "motionDetection", "statusLed", "notificationIntervalTime", "motionDetectionSensitivity", "audioRecording",
              "motionDetectionTypeHuman", "motionDetectionTypePet", "motionDetectionTypeAllOtherMotions",
              "notificationType", "notificationPerson", "notificationPet", "notificationAllOtherMotion",
              "notificationAllSound", "notificationCrying", "continuousRecording", "continuousRecordingType",
              "rtspStream", "videoTypeStoreToNAS"],
        26: ["statusLed", "motionDetection", "watermark", "microphone", "speaker", "speakerVolume",
             "motionDetectionSensitivity", "audioRecording", "nightvision", "recordingClipLength",
             "recordingRetriggerInterval", "recordingEndClipMotionStops", "antitheftDetection", "rtspStream",
             "powerSource", "powerWorkingMode", "notificationType", "videoStreamingQuality", "videoRecordingQuality",
             "lightSettingsEnable", "lightSettingsBrightnessManual", "light", "motionDetectionTypeHuman",
             "motionDetectionTypeVehicle", "motionDetectionTypePet", "motionDetectionTypeAllOtherMotions"],
        48: ["nightvision", "motionDetection", "watermark", "statusLed", "lightSettingsBrightnessManual",
             "microphone", "speaker", "speakerVolume", "audioRecording", "notificationType", "recordingClipLength",
             "recordingRetriggerInterval", "recordingEndClipMotionStops", "light", "lightSettingsEnable",
             "motionDetectionTypeHuman", "motionDetectionTypeVehicle", "motionDetectionTypeAllOtherMotions",
             "powerWorkingMode"],
        8: ["nightvision", "statusLed", "motionDetection", "watermark", "microphone", "speaker", "speakerVolume",
            "audioRecording", "notificationType", "lightSettingsBrightnessManual", "motionDetectionSensitivity",
            "recordingClipLength", "recordingRetriggerInterval", "recordingEndClipMotionStops", "antitheftDetection",
            "rtspStream", "motionDetectionTypeHuman", "motionDetectionTypeVehicle", "motionDetectionTypePet",
            "motionDetectionTypeAllOtherMotions", "powerWorkingMode", "light"],
    ]
}
