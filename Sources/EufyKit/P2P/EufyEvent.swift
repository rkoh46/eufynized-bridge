import Foundation

/// One recorded event from the HomeBase's own event database (`history_record_info`): when it happened,
/// which camera, what triggered it, and where the clip and its snapshot live on the HomeBase's disk.
public struct EufyEvent: Sendable, Hashable, Identifiable, Codable {
    public var id: Int64 { recordID }
    public var recordID: Int64
    public var deviceSerial: String
    /// The camera's channel on the HomeBase, from the `CameraNN` folder of the clip's path.
    public var channel: Int?
    public var startTime: Date
    public var endTime: Date
    /// The station's trigger bits: 4 person, 1/2 motion, 8 doorbell ring, 16 sensor.
    public var triggerType: Int
    public var storagePath: String
    public var thumbnailPath: String?
    public var frameCount: Int
    public var byteSize: Int

    public enum Kind: String, Sendable, CaseIterable { case person, motion, ring, sensor, other }

    public var kind: Kind {
        if triggerType & 4 != 0 { return .person }
        if triggerType & 8 != 0 { return .ring }
        if triggerType & 16 != 0 { return .sensor }
        if triggerType <= 2 { return .motion }
        return .other
    }

    public var kindLabel: String {
        switch kind {
        case .person: "Person"
        case .motion: "Motion"
        case .ring: "Doorbell"
        case .sensor: "Sensor"
        case .other: "Event"
        }
    }

    public var duration: TimeInterval { max(0, endTime.timeIntervalSince(startTime)) }

    public init(recordID: Int64, deviceSerial: String, channel: Int?, startTime: Date, endTime: Date, triggerType: Int,
                storagePath: String, thumbnailPath: String?, frameCount: Int, byteSize: Int) {
        self.recordID = recordID
        self.deviceSerial = deviceSerial
        self.channel = channel
        self.startTime = startTime
        self.endTime = endTime
        self.triggerType = triggerType
        self.storagePath = storagePath
        self.thumbnailPath = thumbnailPath
        self.frameCount = frameCount
        self.byteSize = byteSize
    }

    /// Parses a `CMD_DATABASE` (1306) query reply: NUL-terminated JSON `{cmd, mIntRet, data:[rows]}`.
    /// Returns nil when the text isn't a complete reply yet (it can span frames).
    public static func parseQueryReply(_ text: Data) -> (result: Int, events: [EufyEvent])? {
        let json = text.prefix { $0 != 0 }
        guard let object = try? JSONSerialization.jsonObject(with: json) as? [String: Any] else { return nil }
        let result = (object["mIntRet"] as? Int) ?? 0
        let rows = object["data"] as? [[String: Any]] ?? []
        return (result, rows.compactMap(Self.init(row:)))
    }

    init?(row: [String: Any]) {
        func int(_ key: String) -> Int64? {
            if let n = row[key] as? NSNumber { return n.int64Value }
            return (row[key] as? String).flatMap { Int64($0) }
        }
        guard let recordID = int("record_id"), let serial = row["device_sn"] as? String,
              let path = row["storage_path"] as? String, !path.isEmpty,
              let start = row["start_time"] as? String else { return nil }
        let zone = Self.timeZone(row["time_zone"] as? String)
        guard let startTime = Self.date(start, zone: zone) else { return nil }
        self.recordID = recordID
        deviceSerial = serial
        channel = Self.channel(inPath: path)
        self.startTime = startTime
        endTime = (row["end_time"] as? String).flatMap { Self.date($0, zone: zone) } ?? startTime
        triggerType = Int(int("trigger_type") ?? 0)
        storagePath = path
        thumbnailPath = (row["thumb_path"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        frameCount = Int(int("frame_num") ?? 0)
        byteSize = Int(int("folder_size") ?? 0)
    }

    /// `-0700` → a fixed-offset zone; falls back to the Mac's own zone.
    static func timeZone(_ text: String?) -> TimeZone {
        guard let text, text.count == 5, let sign = text.first, sign == "+" || sign == "-",
              let hours = Int(text.dropFirst().prefix(2)), let minutes = Int(text.suffix(2)) else { return .current }
        let seconds = (hours * 3600 + minutes * 60) * (sign == "-" ? -1 : 1)
        return TimeZone(secondsFromGMT: seconds) ?? .current
    }

    static func date(_ text: String, zone: TimeZone) -> Date? {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = zone
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f.date(from: text)
    }

    static func channel(inPath path: String) -> Int? {
        guard let r = path.range(of: "/Camera") else { return nil }
        return Int(path[r.upperBound...].prefix(2))
    }
}
