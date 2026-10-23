import Foundation

/// A camera Eufynized can show, plus how to start, play and stop its stream.
public struct Camera: Identifiable, Hashable, Sendable {
    public var id: String
    public var name: String
    /// Human-readable model, e.g. "eufyCam S3 Pro", when the serial prefix is known.
    public var model: String?
    /// Stream name in go2rtc; nil when no playable stream was found.
    public var streamName: String?
    /// Home Assistant `camera.*` entity, used for snapshots.
    public var cameraEntity: String?
    /// Home Assistant buttons that start/stop the Eufy P2P stream (battery cameras need this).
    public var startButton: String?
    public var stopButton: String?
    public var batteryPercent: Int?

    public init(id: String, name: String, model: String? = nil, streamName: String? = nil,
                cameraEntity: String? = nil, startButton: String? = nil, stopButton: String? = nil,
                batteryPercent: Int? = nil) {
        self.id = id
        self.name = name
        self.model = model
        self.streamName = streamName
        self.cameraEntity = cameraEntity
        self.startButton = startButton
        self.stopButton = stopButton
        self.batteryPercent = batteryPercent
    }

    public var isBatteryPowered: Bool { batteryPercent != nil }
}

/// Eufy model codes (the start of a device serial number) mapped to product names.
public enum EufyModel {
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

    /// Looks up a name from a serial such as `T8162T0000000001` or a model code such as `T8113-V`.
    public static func name(forSerialOrModel value: String) -> String? {
        guard value.count >= 5 else { return nil }
        return names[String(value.prefix(5)).uppercased()]
    }
}
