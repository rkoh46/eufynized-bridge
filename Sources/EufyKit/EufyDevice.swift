import Foundation

/// A device on the Eufy account, from `/app/house/get_devs_list`.
public struct EufyDevice: Identifiable, Hashable, Sendable {
    public var id: String { serial }
    public var serial: String
    public var name: String
    /// Model code, e.g. "T8162".
    public var model: String
    /// The HomeBase (station) this device belongs to; equals `serial` for standalone devices.
    public var stationSerial: String
    /// P2P id used to reach the station.
    public var p2pDID: String?
    /// The station's LAN address from the device list, when present.
    public var localIP: String?
    /// The camera's channel on its HomeBase — what the live-stream command addresses.
    public var channel: Int?
    public var deviceType: Int?
    /// Firmware: `main_sw_version` and `sec_sw_version` from the device list (e.g. "3.7.4.3").
    public var firmwareVersion: String?
    public var secondaryFirmwareVersion: String?
    /// Names of every field the cloud returned for this device (values aren't kept here), for debugging.
    public var rawFieldNames: [String] = []
    /// The device's settings from the list's `params` array: `param_type` → `param_value` (as text).
    public var params: [Int: String] = [:]

    public var isStation: Bool { serial == stationSerial && model.uppercased().hasPrefix("T80") }

    /// Whether a privacy zone is set: param 1295 (CMD_SET_PRIVACYPARAM) is base64 JSON
    /// `{"points":[{"LeftPointX":…,"LeftPointY":…,"RightPointX":…,"RightPointY":…}, …]}`, one rectangle per
    /// masked area; `{"points":[]}` when none. Confirmed on two Indoor Cam E30s: masked one won't pan.
    public var hasPrivacyZone: Bool? {
        guard let raw = params[1295] else { return nil }
        guard let data = Data(base64Encoded: raw),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let points = json["points"] as? [Any] else { return nil }
        return !points.isEmpty
    }

    /// Product name for the model code, when known.
    public var productName: String? { EufyModels.name(for: model) }

    public init(serial: String, name: String, model: String, stationSerial: String, p2pDID: String? = nil,
                localIP: String? = nil, deviceType: Int? = nil) {
        self.serial = serial
        self.name = name
        self.model = model
        self.stationSerial = stationSerial
        self.p2pDID = p2pDID
        self.localIP = localIP
        self.deviceType = deviceType
    }

    /// Parses one entry of `devices`; nil when it has no serial.
    init?(json: [String: Any]) {
        guard let serial = json["device_sn"] as? String, !serial.isEmpty else { return nil }
        self.serial = serial
        name = (json["device_name"] ?? json["device_alias_name"] ?? json["alias_name"]) as? String ?? serial
        model = json["device_model"] as? String ?? String(serial.prefix(5))
        // `parent_sn` is what's filled in for HomeBase-attached cameras; `station_sn` is often empty.
        let candidates = ["parent_sn", "station_sn", "hub_sn"].compactMap { json[$0] as? String }
        stationSerial = candidates.first { !$0.isEmpty && $0 != serial } ?? serial
        p2pDID = json["p2p_did"] as? String
        localIP = ["local_ip", "ip_addr"].lazy.compactMap { json[$0] as? String }.first { !$0.isEmpty }
        channel = (json["device_channel"] as? NSNumber)?.intValue
        deviceType = json["device_type"] as? Int
        firmwareVersion = (json["main_sw_version"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        secondaryFirmwareVersion = (json["sec_sw_version"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        rawFieldNames = json.keys.sorted()
        for entry in json["params"] as? [[String: Any]] ?? [] {
            guard let type = (entry["param_type"] as? NSNumber)?.intValue else { continue }
            params[type] = (entry["param_value"]).map { "\($0)" } ?? ""
        }
    }
}

/// Eufy model codes (the first five characters of a serial) to product names.
public enum EufyModels {
    public static let names: [String: String] = [
        "T8030": "HomeBase 3",
        "T8010": "HomeBase 2",
        "T8113": "eufyCam 2C",
        "T8114": "eufyCam 2",
        "T8140": "eufyCam 2 Pro",
        "T8142": "eufyCam 2C Pro",
        "T8160": "eufyCam 3",
        "T8161": "eufyCam 3C",
        "T8162": "eufyCam S3 Pro",
        "T8170": "SoloCam S340",
        "T8172": "eufyCam S4",
        "T8173": "SoloCam E42",
        "T8417": "Indoor Cam E30",
        "T8419": "Indoor Cam C210",
    ]

    public static func name(for modelOrSerial: String) -> String? {
        guard modelOrSerial.count >= 5 else { return nil }
        return names[String(modelOrSerial.prefix(5)).uppercased()]
    }

    /// Model prefixes that pan and tilt (take PTZ commands) — the fallback when no device type is known.
    /// T8417 is the Indoor Cam E30, device type 105 (INDOOR_PT_CAMERA_E30).
    static let panTiltPrefixes: Set<String> = ["T8170", "T8171", "T8410", "T8414", "T8416", "T8417", "T8423", "T8425"]

    /// Cloud `device_type` values for pan-tilt cameras (eufy-sdk's device-type table, plus the E30 and
    /// S350 indoor PT types its PTZ detection list leaves out).
    static let panTiltDeviceTypes: Set<Int> = [
        31,   // INDOOR_PT_CAMERA
        35,   // INDOOR_PT_CAMERA_1080
        47,   // FLOODLIGHT_CAMERA_8425
        48,   // OUTDOOR_PT_CAMERA
        104,  // INDOOR_PT_CAMERA_S350
        105,  // INDOOR_PT_CAMERA_E30
        111,  // CAMERA_4G_S330
        10008, 10009, 10010, 10011,  // INDOOR_PT_CAMERA_C220 / C210 / C220_V2 / C220_V3
    ]

    /// Whether a camera pans and tilts: by its device type when known, else by its model/serial prefix.
    public static func isPanTilt(_ modelOrSerial: String, deviceType: Int? = nil) -> Bool {
        if let deviceType, panTiltDeviceTypes.contains(deviceType) { return true }
        guard modelOrSerial.count >= 5 else { return false }
        return panTiltPrefixes.contains(String(modelOrSerial.prefix(5)).uppercased())
    }
}
