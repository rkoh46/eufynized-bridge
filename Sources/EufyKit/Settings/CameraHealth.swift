import Foundation

/// Facts a camera reports alongside its settings (the same parameter read), named after eufy-security-client's
/// `DeviceDetectionStatistics*` properties and the eufy app's tables. Read-only.
public struct CameraHealth: Sendable, Equatable {
    public struct BatterySample: Sendable, Equatable {
        public let date: Date
        public let percent: Int
    }

    public var firmware: String?
    /// Days the camera has been working (1191 `CMD_GET_WORKING_DAYS_HB3`).
    public var workingDays: Int?
    /// Events it detected (1192) and recorded (1193), lifetime.
    public var detectedEvents: Int?
    public var recordedEvents: Int?
    /// Parameter 1309, unnamed in eufy's table. Reads 0–100ish on cameras with a solar panel (83 on a Front360 in
    /// daylight, 0 on an S3 Pro at the same time): most likely the panel's charging level. Shown as a raw reading
    /// until its meaning is confirmed.
    public var solarReading: Int?
    /// Daily battery level for about the last month (3100), oldest first.
    public var batteryHistory: [BatterySample] = []

    public init(params: [Int: String]) {
        firmware = params[7013].flatMap { $0.isEmpty ? nil : $0 }
        workingDays = params[1191].flatMap { Int($0) }
        detectedEvents = params[1192].flatMap { Int($0) }
        recordedEvents = params[1193].flatMap { Int($0) }
        solarReading = params[1309].flatMap { Int($0) }
        if let raw = params[3100]?.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: raw) as? [String: Any],
           let detail = json["battery_data_detail"] as? [[String: Any]] {
            batteryHistory = detail.compactMap { d in
                guard let t = (d["time_stamp"] as? NSNumber)?.doubleValue, let p = (d["battery_power"] as? NSNumber)?.intValue,
                      t > 0 else { return nil }
                return BatterySample(date: Date(timeIntervalSince1970: t), percent: p)
            }.sorted { $0.date < $1.date }
        }
    }

    /// Battery change per day over the history (negative: draining), or nil with under a week of samples.
    public var batteryTrendPerDay: Double? {
        guard let first = batteryHistory.first, let last = batteryHistory.last else { return nil }
        let days = last.date.timeIntervalSince(first.date) / 86_400
        guard days >= 7 else { return nil }
        return Double(last.percent - first.percent) / days
    }

    public var json: [String: Any] {
        var out: [String: Any] = [:]
        out["firmware"] = firmware
        out["workingDays"] = workingDays
        out["detectedEvents"] = detectedEvents
        out["recordedEvents"] = recordedEvents
        out["solarReading"] = solarReading
        if !batteryHistory.isEmpty {
            out["batteryHistory"] = batteryHistory.map { ["date": Int($0.date.timeIntervalSince1970), "percent": $0.percent] }
        }
        out["batteryTrendPerDay"] = batteryTrendPerDay.map { ($0 * 10).rounded() / 10 }
        return out
    }
}

/// The HomeBase 3's storage report (CMD_STORAGE_INFO_HB3 1307): its internal eMMC and the hard drive or SSD.
public struct HomeBaseStorage: Sendable, Equatable {
    public struct Disk: Sendable, Equatable {
        /// Video space in MB, and how much of it is used.
        public let videoTotalMB: Int
        public let videoUsedMB: Int
        /// 0 is healthy (the app shows anything else as a problem).
        public let health: Int
        public let temperature: Int?
        public let model: String?

        public var usedFraction: Double { videoTotalMB > 0 ? Double(videoUsedMB) / Double(videoTotalMB) : 0 }
        public var freeMB: Int { max(0, videoTotalMB - videoUsedMB) }
    }

    public let drive: Disk?
    public let emmc: Disk?
    /// Days of recordings kept, and how many events.
    public let storageDays: Int?
    public let storageEvents: Int?

    public init?(json: [String: Any]) {
        func disk(_ key: String, total: String, used: String) -> Disk? {
            guard let d = json[key] as? [String: Any], let t = (d[total] as? NSNumber)?.intValue, t > 0 else { return nil }
            return Disk(videoTotalMB: t, videoUsedMB: (d[used] as? NSNumber)?.intValue ?? 0,
                        health: (d["health"] as? NSNumber)?.intValue ?? 0,
                        temperature: (d["cur_temperate"] as? NSNumber)?.intValue,
                        model: (d["device_module"] as? String).flatMap { $0.isEmpty ? nil : $0 })
        }
        drive = disk("hdd_info", total: "video_size", used: "video_used")
        emmc = disk("emmc_info", total: "video_size", used: "video_used")
        storageDays = (json["storage_days"] as? NSNumber)?.intValue
        storageEvents = (json["storage_events"] as? NSNumber)?.intValue
        if drive == nil && emmc == nil { return nil }
    }
}
