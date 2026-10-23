import Foundation

/// One per-camera setting, as the official app shows it: what it's called, where it's grouped, which param
/// holds it, and what values it takes. The catalog itself is generated (see `CameraSettingsCatalog.generated`).
public struct CameraSetting: Identifiable, @unchecked Sendable {
    public enum Kind {
        case toggle
        case choice([(value: Int, label: String)])
        case number(min: Double?, max: Double?, step: Double?, unit: String?)
        case text
    }

    public let id: String
    public let label: String
    public let group: String
    /// The param id the value is read from (`param_type` in the HomeBase's camera-info reply).
    public let key: Int
    /// The command id a change is written with, when it differs from `key`.
    public let writeKey: Int?
    public let kind: Kind
    /// Writable according to the library catalog. Eufynized only writes settings also proven on hardware
    /// (`CameraSettingsCatalog.verifiedWrites`).
    public let writable: Bool

    init(id: String, label: String, group: String, key: Int, writeKey: Int? = nil, kind: Kind, writable: Bool) {
        self.id = id; self.label = label; self.group = group; self.key = key
        self.writeKey = writeKey; self.kind = kind; self.writable = writable
    }

    public var commandID: Int { writeKey ?? key }
}

/// How to write one setting on one camera type: the frame(s) eufy-security-client sends, captured from its
/// own setters (see `scripts/generate-settings-recipes.js`). Bodies hold placeholders filled in at send time.
public enum CameraSettingWriteRecipe: Sendable {
    /// Exact frames per value (booleans as 1/0, choices by their option value).
    case perValue([Int: [CameraSettingWriteFrame]])
    /// The same frames for any value in the setting's range, with `{value}` in the body.
    case template([CameraSettingWriteFrame])

    /// The values this recipe can write, when it's limited to a set (nil: any value in range).
    public var supportedValues: [Int]? {
        if case .perValue(let map) = self { return map.keys.sorted() }
        return nil
    }

    func frames(for value: Int) -> [CameraSettingWriteFrame]? {
        switch self {
        case .perValue(let map): map[value] ?? Self.inferred(from: map, value: value)
        case .template(let frames): frames.map { $0.filling(["value": String(value)]) }
        }
    }

    /// A value the catalog doesn't list (a camera can report modes newer than the library knows, e.g. night
    /// vision 6): when every captured value is one JSON frame that differs only in a single field equal to that
    /// value, the same frame with the new number is what the app would send.
    static func inferred(from map: [Int: [CameraSettingWriteFrame]], value: Int) -> [CameraSettingWriteFrame]? {
        guard map.count >= 2, map.values.allSatisfy({ $0.count == 1 && $0[0].form != .direct }) else { return nil }
        // Keys whose number equals the captured value in every frame: the field carrying the setting.
        func fields(_ body: String) -> [String: Int] {
            guard let re = try? NSRegularExpression(pattern: "\"(\\w+)\":(-?\\d+)(?=[,}])") else { return [:] }
            var out: [String: Int] = [:]
            for m in re.matches(in: body, range: NSRange(body.startIndex..., in: body)) {
                guard let k = Range(m.range(at: 1), in: body), let v = Range(m.range(at: 2), in: body) else { continue }
                out[String(body[k])] = Int(body[v])
            }
            return out
        }
        var carriers: Set<String>?
        for (known, frames) in map {
            let keys = Set(fields(frames[0].body).filter { $0.value == known }.keys)
            carriers = carriers.map { $0.intersection(keys) } ?? keys
        }
        guard let carriers, carriers.count == 1, let key = carriers.first,
              let first = map.first, let f = first.value.first else { return nil }
        let body = f.body.replacingOccurrences(of: "\"\(key)\":\(first.key)", with: "\"\(key)\":\(value)")
        return [CameraSettingWriteFrame(form: f.form, command: f.command, body: body)]
    }
}

public struct CameraSettingWriteFrame: Sendable {
    public enum Form: Sendable {
        /// Level-2 direct value: outer = `command`, body `[u32 channel][u32 Int(body)][account id]`.
        case direct
        /// Level-2 CMD_SET_PAYLOAD (1350) with the JSON `body`.
        case setPayload
        /// Level-2 control payload (1700) with the JSON `body`.
        case control
        /// Level-2 station scalar: outer = `command`, body `[u32 Int(body)][account id]` (no channel field), sent
        /// on the camera's channel. eufy-sdk's form for the recording settings (1249/1250/1251, verified on T8170).
        case stationScalar
    }
    public let form: Form
    public let command: Int
    public let body: String

    init(form: Form, command: Int, body: String) { self.form = form; self.command = command; self.body = body }

    func filling(_ values: [String: String]) -> CameraSettingWriteFrame {
        var b = body
        for (key, value) in values { b = b.replacingOccurrences(of: "{\(key)}", with: value) }
        return CameraSettingWriteFrame(form: form, command: command, body: b)
    }

    /// Every command id this frame would invoke: its outer command, and the inner `cmd` / `commandType` of a
    /// JSON body. Checked against `forbiddenCommands` before anything is sent.
    var invokedCommands: Set<Int> {
        var ids: Set<Int> = [command]
        for key in ["cmd", "commandType"] {
            if let r = body.range(of: "\"\(key)\":"),
               let n = Int(body[r.upperBound...].prefix { $0.isNumber }) { ids.insert(n) }
        }
        return ids
    }
}

/// A setting's current value, decoded from its raw param text.
public enum CameraSettingValue: Equatable, Sendable {
    case bool(Bool)
    case int(Int)
    case text(String)

    public var intValue: Int? {
        switch self {
        case .bool(let b): b ? 1 : 0
        case .int(let i): i
        case .text(let s): Int(s)
        }
    }
}

public enum CameraSettingsCatalog {
    /// Section order, as the official app lays out a camera's settings. Status (battery, signal, state) is last.
    public static let groupOrder = ["General", "Video", "Detection", "Notifications", "Recording", "Audio",
                                    "Lights", "Pan & Tilt", "Power", "Network", "Status"]

    /// A value the camera reports rather than a setting: battery, signal, online state, charging — and on the
    /// SoloCam S340 its power source (it measures it) and on/off (the known command had no effect on Front360,
    /// and camera power isn't to be test-toggled). Shown as plain status, no control.
    public static func isStatus(_ setting: CameraSetting, deviceType: Int?) -> Bool {
        !setting.writable || (deviceType == 48 && ["powerSource", "enabled"].contains(setting.id))
    }

    /// Whether the app offers a control for this setting: anything with a write path that isn't status.
    /// Most are proven on hardware (`verifiedWrites`); every change is read back either way.
    public static func isEditable(_ setting: CameraSetting, deviceType: Int?) -> Bool {
        !isStatus(setting, deviceType: deviceType) && (isPacked(setting) || recipe(for: setting, deviceType: deviceType) != nil)
    }

    /// The name shown for a setting: plain words instead of the library's internal labels ("Light Brightness
    /// Manual", "Continuos Recording", …). Falls back to the catalog label.
    public static func displayLabel(_ setting: CameraSetting) -> String {
        labels[setting.id] ?? setting.label
    }

    static let labels: [String: String] = [
        "enabled": "Camera on", "antitheftDetection": "Anti-theft alarm", "state": "Status",
        "nightvision": "Night vision", "autoNightvision": "Auto night vision", "watermark": "Watermark",
        "imageMirrored": "Flip image vertically", "videoStreamingQuality": "Streaming quality",
        "videoRecordingQuality": "Recording quality", "dualCamWatchViewMode": "Dual-camera view",
        "powerSourceMode": "Power source",
        "motionDetection": "Motion detection", "motionDetectionSensitivity": "Motion sensitivity",
        "motionDetectionTypeHuman": "Detect people", "motionDetectionTypeVehicle": "Detect vehicles",
        "motionDetectionTypePet": "Detect pets", "motionDetectionTypeAllOtherMotions": "Detect all other motion",
        "soundDetection": "Sound detection", "soundDetectionType": "Sound type", "soundDetectionSensitivity": "Sound sensitivity",
        "notificationType": "Notification style", "notificationIntervalTime": "Notification interval (minutes)",
        "notificationPerson": "Notify for people", "notificationPet": "Notify for pets",
        "notificationAllOtherMotion": "Notify for other motion", "notificationAllSound": "Notify for sounds",
        "notificationCrying": "Notify for crying",
        "recordingClipLength": "Clip length (seconds)", "recordingRetriggerInterval": "Retrigger interval (seconds)",
        "recordingEndClipMotionStops": "End clip early when motion stops", "continuousRecording": "Continuous recording",
        "continuousRecordingType": "Continuous recording mode", "videoTypeStoreToNAS": "Save to NAS",
        "microphone": "Microphone", "speaker": "Speaker", "speakerVolume": "Speaker volume", "audioRecording": "Record audio",
        "statusLed": "Status light", "light": "Spotlight", "lightSettingsEnable": "Spotlight enabled",
        "lightSettingsBrightnessManual": "Spotlight brightness",
        "motionTracking": "Motion tracking", "rotationSpeed": "Rotation speed", "motionAutoCruise": "Auto-cruise",
        "autoCalibration": "Auto calibration", "soundDetectionRoundLook": "Turn toward sounds",
        "powerSource": "Power source", "powerWorkingMode": "Working mode", "battery": "Battery",
        "batteryTemperature": "Battery temperature", "chargingStatus": "Charging",
        "wifiRssi": "Wi-Fi signal", "rtspStream": "RTSP stream",
    ]

    /// The section a setting is shown in (status values gather under "Status").
    public static func group(of setting: CameraSetting, deviceType: Int?) -> String {
        isStatus(setting, deviceType: deviceType) ? "Status" : setting.group
    }

    /// Settings for a camera of this cloud `device_type` (empty when the type isn't catalogued).
    public static func settings(forDeviceType type: Int?) -> [CameraSetting] {
        guard let type, var list = generated[type] else { return [] }
        // On a HomeBase 3 the 2C and S3 Pro keep their detection types in the HB3 bits (1298) like the newer
        // cameras — Front door reads 1298 = human on, other off — and ignore the legacy 1252 setting.
        if type == 8 || type == 26 {
            list.removeAll { $0.id == "motionDetectionType" }
            let at = list.firstIndex { $0.id == "motionDetectionSensitivity" }.map { $0 + 1 } ?? list.endIndex
            list.insert(contentsOf: hb3DetectionSettings, at: at)
        }
        if type == 26 { list.append(contentsOf: eufyCam3PowerSettings) }
        return list
    }

    static let hb3DetectionSettings: [CameraSetting] = [
        CameraSetting(id: "motionDetectionTypeHuman", label: "Detect people", group: "Detection", key: 1298, kind: .toggle, writable: true),
        CameraSetting(id: "motionDetectionTypeVehicle", label: "Detect vehicles", group: "Detection", key: 1298, kind: .toggle, writable: true),
        CameraSetting(id: "motionDetectionTypePet", label: "Detect pets", group: "Detection", key: 1298, kind: .toggle, writable: true),
        CameraSetting(id: "motionDetectionTypeAllOtherMotions", label: "Detect all other motion", group: "Detection", key: 1298, kind: .toggle, writable: true),
    ]

    /// Command ids that must never be sent from a settings screen, whatever a catalog says: HomeBase restart
    /// (1034) and the factory resets (1036 hub, 1037 devices). eufy-sdk: "a slip of two here factory-resets
    /// the hub". 1035 (camera on/off) sits between them but is an ordinary setting.
    public static let forbiddenCommands: Set<Int> = [1034, 1036, 1037]

    /// Commands that must not go out in the direct form. (The recording settings 1249/1250/1251 stalled the
    /// HomeBase as direct values; they're rewritten to the station-scalar form instead — see `recipe(for:)`.)
    public static let unsupportedCommands: Set<Int> = []

    /// The recording settings eufy-sdk writes as station scalars; 1251 ("end clip early") is stored inverted.
    static let stationScalarCommands: Set<Int> = [1249, 1250, 1251]

    /// The write recipe for a setting on a camera type, if eufy-security-client defines one.
    public static func recipe(for setting: CameraSetting, deviceType: Int?) -> CameraSettingWriteRecipe? {
        // Motion detection type (1252 CMD_DEV_PUSHMSG_MODE) on the 2C / S3 Pro: eufy-security-client lists it as
        // writable but refuses to send it; its int-command family goes out as a station scalar on a HomeBase 3.
        if setting.id == "motionDetectionType", setting.key == 1252, deviceType == 8 || deviceType == 26 {
            return .template([CameraSettingWriteFrame(form: .stationScalar, command: 1252, body: "{value}")])
        }
        if deviceType == 26, let extra = eufyCam3PowerRecipes[setting.id] { return extra }
        guard let recipe = deviceType.flatMap({ recipes[$0]?[setting.id] }) else { return nil }
        return asStationScalar(recipe)
    }

    /// eufy-security-client sends the recording settings as plain ints, which this HomeBase 3 choked on (it
    /// stopped answering). eufy-sdk's verified form is the station scalar, with 1251 inverted (0 = end early).
    static func asStationScalar(_ recipe: CameraSettingWriteRecipe) -> CameraSettingWriteRecipe {
        func convert(_ f: CameraSettingWriteFrame, appValue: Int?) -> CameraSettingWriteFrame {
            guard f.form == .direct, stationScalarCommands.contains(f.command) else { return f }
            var body = f.body
            if f.command == 1251, let v = appValue { body = v == 1 ? "0" : "1" }
            return CameraSettingWriteFrame(form: .stationScalar, command: f.command, body: body)
        }
        switch recipe {
        case .perValue(let map):
            return .perValue(Dictionary(uniqueKeysWithValues: map.map { value, frames in
                (value, frames.map { convert($0, appValue: value) })
            }))
        case .template(let frames):
            return .template(frames.map { convert($0, appValue: nil) })
        }
    }

    /// The frames to send to set `setting` to `value` on `channel`, or nil if there's no recipe for that value or
    /// any frame would invoke a forbidden command.
    public static func writeFrames(for setting: CameraSetting, deviceType: Int?, value: Int, channel: UInt8,
                                   accountID: String) -> [CameraSettingWriteFrame]? {
        guard !accountID.isEmpty, let frames = recipe(for: setting, deviceType: deviceType)?.frames(for: value) else { return nil }
        let filled = frames.map {
            $0.filling(["account": accountID, "channel": String(channel),
                        "transaction": String(Int(Date().timeIntervalSince1970 * 1000))])
        }
        guard filled.allSatisfy({ $0.invokedCommands.isDisjoint(with: forbiddenCommands.union(unsupportedCommands)) }),
              filled.allSatisfy({ ($0.form != .direct && $0.form != .stationScalar) || Int($0.body) != nil }) else { return nil }
        return filled
    }

    /// Settings whose write has been confirmed on real hardware (set → read back → restore), per device type.
    /// Only these are editable in the app; everything else is shown read-only.
    public static var verifiedWrites: [Int: Set<String>] { verified }

    // MARK: Decoding

    /// Decodes a setting from a camera's params. Packed settings share one param and are read bit by bit,
    /// the way eufy-security-client does for HomeBase 3 cameras.
    /// With `deviceType`, a value stored as a device code (the 2C's motion sensitivity keeps 192/118/…/14 for
    /// steps 1…7) is mapped back to the step through the same write recipe.
    /// Where a camera reports a setting under another number: the S340 reports its dual-cam view mode (written with
    /// 6243) as 2700, CMD_DOORBELL_DUAL_VIEW_MODE (seen on firmware 3.3.5.4).
    static let fallbackKeys: [Int: Int] = [6243: 2700]

    public static func value(of setting: CameraSetting, in params: [Int: String], deviceType: Int? = nil) -> CameraSettingValue? {
        guard let raw = (params[setting.key] ?? fallbackKeys[setting.key].flatMap { params[$0] })?
            .trimmingCharacters(in: .whitespaces), !raw.isEmpty else { return nil }
        if let code = Int(raw), let step = stepForDeviceCode(code, setting: setting, deviceType: deviceType) {
            return .int(step)
        }
        if let bit = packedBit(setting.id) {
            guard let v = Int(raw) else { return nil }
            return .bool(bit(v))
        }
        // CMD_SET_AUDIO_MUTE_RECORD (1288) stores "mute", so "0" means recording is on (as eufy-security-client
        // reads it for the 2C / S3 Pro families).
        if setting.key == 1288, let v = Int(raw) { return .bool(v == 0) }
        // Camera on/off (1035 CMD_DEVS_SWITCH, 6250 privacy mode): "0" means the camera is ON.
        if setting.id == "enabled", [1035, 6250].contains(setting.key), let v = Int(raw) { return .bool(v == 0) }
        // SET_RECORD_AUTO_STOP (1251) too: "0" means the clip ends early when motion stops (eufy-sdk).
        if setting.key == 1251, let v = Int(raw) { return .bool(v == 0) }
        switch setting.kind {
        case .toggle:
            if raw == "true" { return .bool(true) }
            if raw == "false" { return .bool(false) }
            return Int(raw).map { .bool($0 != 0) }
        case .choice, .number:
            if let i = Int(raw) { return .int(i) }
            if let d = Double(raw) { return .int(Int(d)) }
            return .text(raw)
        case .text:
            return .text(raw)
        }
    }

    /// The app value whose recipe writes `code` as its single direct value, when the recipe maps values to codes
    /// (and `code` isn't itself one of the app values).
    static func stepForDeviceCode(_ code: Int, setting: CameraSetting, deviceType: Int?) -> Int? {
        guard case .perValue(let map)? = recipe(for: setting, deviceType: deviceType), map[code] == nil else { return nil }
        let matches = map.filter { $0.value.count >= 1 && $0.value.allSatisfy { $0.form == .direct } && $0.value[0].body == String(code) }
        guard matches.count == 1, let step = matches.first?.key, map.contains(where: { $0.value[0].body != String($0.key) }) else { return nil }
        return step
    }

    /// Bit tests for the packed settings (HB3 detection types in 1298, Indoor S350/E30 notifications in 6027).
    static func packedBit(_ id: String) -> ((Int) -> Bool)? {
        func has(_ type: Int) -> (Int) -> Bool { { v in v & type == type } }
        func notify(_ bit: Int) -> (Int) -> Bool { { v in v >= 800 && (v - 800) & bit != 0 } }
        switch id {
        case "motionDetectionTypeHuman": return { v in v & 2 == 2 && v & 1 == 1 }
        case "motionDetectionTypeVehicle": return has(4)
        case "motionDetectionTypePet": return has(8)
        case "motionDetectionTypeAllOtherMotions": return has(32768)
        case "notificationAllOtherMotion": return notify(1)
        case "notificationPerson": return notify(2)
        case "notificationPet": return notify(4)
        case "notificationCrying": return notify(8)
        case "notificationAllSound": return notify(16)
        default: return nil
        }
    }

    /// Settings that share one packed param: written by flipping their bit in the camera's current value.
    public static func isPacked(_ setting: CameraSetting) -> Bool { packedBit(setting.id) != nil }

    /// The bits a packed setting owns in its param. Detection types (1298) use the HomeBase 3 layout the
    /// reads already decode (human 1+2, vehicle 4, pet 8, other 32768); E30 notification types (6027) are
    /// 800 + a bit per type (other 1, person 2, pet 4, crying 8, sound 16) — Kodi Cam reads 831 with all on.
    static func packedMask(_ id: String) -> Int? {
        switch id {
        case "motionDetectionTypeHuman": 3
        case "motionDetectionTypeVehicle": 4
        case "motionDetectionTypePet": 8
        case "motionDetectionTypeAllOtherMotions": 32768
        case "notificationAllOtherMotion": 1
        case "notificationPerson": 2
        case "notificationPet": 4
        case "notificationCrying": 8
        case "notificationAllSound": 16
        default: nil
        }
    }

    /// The frame that turns one packed setting on or off, starting from the camera's current raw value.
    /// The frame shapes are eufy-security-client's (its bit math is not used: it sends the same value for on
    /// and off on some models).
    public static func packedWriteFrame(for setting: CameraSetting, on: Bool, currentRaw: Int, channel: UInt8,
                                        accountID: String) -> CameraSettingWriteFrame? {
        guard !accountID.isEmpty, let mask = packedMask(setting.id) else { return nil }
        switch setting.key {
        case 1298:
            let new = on ? currentRaw | mask : currentRaw & ~mask
            return CameraSettingWriteFrame(form: .setPayload, command: 1350, body:
                "{\"account_id\":\"\(accountID)\",\"cmd\":1298,\"mChannel\":0,\"mValue3\":0,\"payload\":{\"ai_detect_type\":\(new),\"channel\":\(channel)}}")
        case 6027:
            let bits = currentRaw >= 800 ? (currentRaw - 800) & 31 : 0
            let new = 800 + (on ? bits | mask : bits & ~mask)
            return CameraSettingWriteFrame(form: .setPayload, command: 1350, body:
                "{\"account_id\":\"\(accountID)\",\"cmd\":6027,\"mChannel\":\(channel),\"mValue3\":0,\"payload\":{\"onoff\":\(new)}}")
        default:
            return nil
        }
    }

    /// Parses a camera-info / notify reply `{"params":[{"param_type":…,"param_value":…},…]}`.
    public static func paramReport(_ plaintext: Data) -> [Int: String]? {
        let text = String(decoding: plaintext.prefix { $0 != 0 }, as: UTF8.self)
        guard let json = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else { return nil }
        let list = (json["params"] ?? (json["payload"] as? [String: Any])?["params"]) as? [[String: Any]]
        guard let list else { return nil }
        var out: [Int: String] = [:]
        for entry in list {
            guard let key = (entry["param_type"] as? NSNumber)?.intValue, let value = entry["param_value"] else { continue }
            out[key] = "\(value)"
        }
        return out.isEmpty ? nil : out
    }

    // MARK: Writing

    /// The level-2 direct-binary body for a setting write: `[u32 channel][u32 value][account id, ASCII, 128]`
    /// (eufy-sdk `buildDirectBinaryBody`). The account field must not be empty; the HomeBase rejects that.
    /// `channel: nil` gives the 132-byte station-scalar body `[u32 value][account id]`.
    public static func directBinaryBody(channel: UInt8?, value: Int, accountID: String) -> Data? {
        guard !accountID.isEmpty else { return nil }
        var body = Data()
        if let channel {
            var ch = UInt32(channel).littleEndian
            body.append(Data(bytes: &ch, count: 4))
        }
        var v = UInt32(bitPattern: Int32(truncatingIfNeeded: value)).littleEndian
        body.append(Data(bytes: &v, count: 4))
        var account = Data(accountID.utf8.prefix(128))
        account.append(Data(count: 128 - account.count))
        body.append(account)
        return body
    }
}
