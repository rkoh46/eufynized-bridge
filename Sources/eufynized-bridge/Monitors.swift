import Foundation
import EufyKit

/// Alerts that don't come from the HomeBase's own events: a camera that went quiet, a low battery, a weak
/// link, a full drive (health); someone who has been on a camera for minutes (loitering); and the morning
/// digest. They go out through the same alert stream as camera events, so Home Assistant, the page and the
/// Mac app treat them alike (kinds `health`, `loitering`, `digest`).
///
/// Health readings come from the settings reads the bridge already does for Home Assistant and the apps
/// (`Bridge.noteSettings`), so watching costs no extra HomeBase sessions.
final class Monitors {
    private let bridge: Bridge
    private let alerts: AlertCenter
    private let lock = NSLock()
    /// Last settings read per channel, and when.
    private var readings: [UInt8: (params: [Int: String], at: Date)] = [:]
    /// Failed settings reads in a row per channel.
    private var failures: [UInt8: Int] = [:]
    /// When a camera was first seen offline in its current stretch (nil once anything from it succeeds).
    private var offlineSince: [UInt8: Date] = [:]
    /// Health conditions currently raised, by key ("battery-2", "offline-2", "storage"), so each alerts once on
    /// entering and once on clearing.
    private var raised: [String: Date] = [:]
    /// Person-event runs per channel for loitering: when the run started, the last event, and whether it alerted.
    private var runs: [Int: (start: Date, last: Date, alerted: Bool)] = [:]
    private var lastDigestDay: String?

    init(bridge: Bridge, alerts: AlertCenter) {
        self.bridge = bridge
        self.alerts = alerts
        lastDigestDay = bridge.prefs.all["lastDigestDay"] as? String
    }

    func start() {
        Thread.detachNewThread { [self] in
            while true {
                Thread.sleep(forTimeInterval: 60)
                checkHealth()
                checkLoiteringTimeouts()
                checkDigest()
            }
        }
    }

    // MARK: Readings

    func noteSettings(_ channel: UInt8, _ params: [Int: String]?) {
        lock.withLock {
            if let params { readings[channel] = (params, Date()); failures[channel] = 0; offlineSince[channel] = nil }
            else { failures[channel, default: 0] += 1 }
        }
    }

    /// Something from the camera arrived (video, a picture): it's not offline.
    func noteAlive(_ channel: UInt8) {
        lock.withLock { failures[channel] = 0; offlineSince[channel] = nil }
    }

    // MARK: Health

    private struct Thresholds {
        static let batteryLow = 20, batteryRecovered = 30
        static let signalWeak = -75, signalRecovered = -68
        static let storageFull = 0.90, storageRecovered = 0.85
        static let offlineAfter: TimeInterval = 15 * 60
    }

    private func checkHealth() {
        let now = Date()
        for camera in bridge.config.cameras {
            let ch = UInt8(camera.channel)
            // Offline: the HomeBase said so, or settings reads keep failing. Only after a quarter of an hour of that,
            // and only cleared once something from the camera actually arrives (a read, video, a picture), so an
            // unplugged camera says so once, not every time the HomeBase's answer is asked for again.
            let unavailable = bridge.knownUnavailable(ch)
            let reading = lock.withLock { readings[ch] }
            let offlineFor: TimeInterval? = lock.withLock {
                let seen = unavailable != nil || (failures[ch] ?? 0) >= 3
                if seen, offlineSince[ch] == nil { offlineSince[ch] = now }
                return offlineSince[ch].map { now.timeIntervalSince($0) }
            }
            _ = reading
            condition("offline-\(ch)", active: (offlineFor ?? 0) >= Thresholds.offlineAfter,
                      raise: "\(camera.name) is \(unavailable?.title.lowercased() ?? "not answering")",
                      clear: "\(camera.name) is back")
            guard let params = reading?.params else { continue }
            if let battery = params[1101].flatMap({ Int($0) }), params[2111].flatMap({ Int($0) }) != 1 {
                hysteresis("battery-\(ch)", value: battery, bad: { $0 <= Thresholds.batteryLow }, good: { $0 >= Thresholds.batteryRecovered },
                           raise: "\(camera.name) battery is at \(battery)%", clear: "\(camera.name) battery is back to \(battery)%")
            }
            if let rssi = params[1142].flatMap({ Int($0) }), rssi > -100 {
                hysteresis("signal-\(ch)", value: rssi, bad: { $0 <= Thresholds.signalWeak }, good: { $0 >= Thresholds.signalRecovered },
                           raise: "\(camera.name) has a weak link to the HomeBase (\(rssi) dBm)", clear: "\(camera.name)'s link is fine again (\(rssi) dBm)")
            }
        }
        // Storage: once an hour is plenty (it asks the HomeBase).
        let lastStorage = lock.withLock { raised["storage-checked"] }
        if lastStorage == nil || now.timeIntervalSince(lastStorage!) > 3600 {
            lock.withLock { raised["storage-checked"] = now }
            if let json = alerts.storageInfo(), let storage = HomeBaseStorage(json: json), let drive = storage.drive ?? storage.emmc {
                let pct = Int((drive.usedFraction * 100).rounded())
                hysteresis("storage", value: drive.usedFraction, bad: { $0 >= Thresholds.storageFull }, good: { $0 <= Thresholds.storageRecovered },
                           raise: "HomeBase drive is \(pct)% full; the oldest recordings go first", clear: "HomeBase drive is back to \(pct)% full")
                condition("drive-health", active: drive.health != 0, raise: "HomeBase drive reports a problem (code \(drive.health))",
                          clear: "HomeBase drive is healthy again")
            }
        }
    }

    private func hysteresis<T>(_ key: String, value: T, bad: (T) -> Bool, good: (T) -> Bool, raise: String, clear: String) {
        let isRaised = lock.withLock { raised[key] != nil }
        if !isRaised && bad(value) { condition(key, active: true, raise: raise, clear: clear) }
        else if isRaised && good(value) { condition(key, active: false, raise: raise, clear: clear) }
    }

    /// Alerts when `active` flips: once on entering, once on clearing.
    private func condition(_ key: String, active: Bool, raise: String, clear: String) {
        let changed: Bool? = lock.withLock {
            let was = raised[key] != nil
            if active == was { return nil }
            raised[key] = active ? Date() : nil
            return active
        }
        guard let entering = changed else { return }
        let channel = Int(key.split(separator: "-").last.flatMap { Int($0) } ?? -1)
        alerts.deliverExtra(kind: "health", title: entering ? "Health" : "Health: resolved", detail: entering ? raise : clear,
                            channel: channel, camera: bridge.camera(UInt8(clamping: max(0, channel)))?.name ?? "HomeBase")
    }

    // MARK: Loitering

    static let loiterAfter: TimeInterval = 120
    static let loiterGap: TimeInterval = 120

    /// Called for every person event. A run is person events on one camera with no gap longer than two minutes;
    /// a run older than two minutes raises "someone has been there" once.
    func notePerson(channel: Int, at time: Date, camera: String) {
        let minutes: Int? = lock.withLock {
            var run = runs[channel] ?? (time, time, false)
            if time.timeIntervalSince(run.last) > Self.loiterGap { run = (time, time, false) }
            run.last = time
            defer { runs[channel] = run }
            guard !run.alerted, time.timeIntervalSince(run.start) >= Self.loiterAfter else { return nil }
            run.alerted = true
            return Int((time.timeIntervalSince(run.start) / 60).rounded())
        }
        if let minutes {
            alerts.deliverExtra(kind: "loitering", title: "Someone is still there",
                                detail: "Someone has been at \(camera) for \(minutes) minutes", channel: channel, camera: camera)
        }
    }

    private func checkLoiteringTimeouts() {
        lock.withLock { runs = runs.filter { Date().timeIntervalSince($0.value.last) < Self.loiterGap } }
    }

    // MARK: Daily digest

    func sendDigestNow() { Thread.detachNewThread { [self] in sendDigest(upTo: Date()) } }

    private func checkDigest() {
        let time = (bridge.prefs.all["digestTime"] as? String) ?? "07:00"
        guard time != "off" else { return }
        let now = Date()
        let f = DateFormatter(); f.dateFormat = "HH:mm"
        let day = DateFormatter(); day.dateFormat = "yyyy-MM-dd"
        let today = day.string(from: now)
        guard f.string(from: now) >= time, lastDigestDay != today else { return }
        lastDigestDay = today
        bridge.prefs.merge(["lastDigestDay": today])
        Thread.detachNewThread { [self] in sendDigest(upTo: now) }
    }

    private func sendDigest(upTo now: Date) {
        let since = now.addingTimeInterval(-24 * 3600)
        var lines: [String] = []
        let serials = bridge.config.cameras.map(\.serial)
        let recordings = bridge.recordings
        if let events = blocking({ try? await recordings.events(cameraSerials: serials, from: since, to: now) }) {
            var byCamera: [String: (people: Int, other: Int)] = [:]
            for e in events {
                let name = bridge.config.cameras.first { $0.serial == e.deviceSerial }?.name ?? e.deviceSerial
                var c = byCamera[name] ?? (0, 0)
                if e.kind == .person { c.people += 1 } else { c.other += 1 }
                byCamera[name] = c
            }
            let total = events.count
            lines.append("\(total) recording\(total == 1 ? "" : "s") in the last 24 h" + (total == 0 ? "." : ":"))
            for (name, c) in byCamera.sorted(by: { $0.value.people + $0.value.other > $1.value.people + $1.value.other }) {
                lines.append("• \(name): \(c.people) people, \(c.other) other")
            }
        } else {
            lines.append("Couldn't count the day's recordings (HomeBase didn't answer).")
        }
        let readings = lock.withLock { self.readings }
        var batteries: [String] = []
        for camera in bridge.config.cameras.sorted(by: { $0.channel < $1.channel }) {
            guard let p = readings[UInt8(camera.channel)]?.params, let b = p[1101].flatMap({ Int($0) }) else { continue }
            let charging = p[2111].flatMap { Int($0) } ?? 0
            batteries.append("\(camera.name) \(b)%\(charging != 0 ? " ⚡" : "")")
        }
        if !batteries.isEmpty { lines.append("Batteries: " + batteries.joined(separator: ", ")) }
        if let json = alerts.storageInfo(), let storage = HomeBaseStorage(json: json), let drive = storage.drive ?? storage.emmc {
            lines.append("Drive \(Int((drive.usedFraction * 100).rounded()))% full, \(storage.storageDays.map { "\($0) days kept" } ?? "")")
        }
        let raisedNow = lock.withLock { raised.keys.filter { $0 != "storage-checked" } }
        if !raisedNow.isEmpty { lines.append("Open health issues: \(raisedNow.count)") }
        alerts.deliverExtra(kind: "digest", title: "Morning digest", detail: lines.joined(separator: "\n"), channel: -1, camera: "HomeBase")
    }
}
