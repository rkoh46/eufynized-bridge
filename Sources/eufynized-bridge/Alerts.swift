import Foundation
import EufyKit

/// Camera events as the HomeBase announces them over the LAN (the same watcher as the Mac app's banners):
/// kept for the web page's alert list and live toasts. The Home Assistant integration reads every event
/// (`api/alerts/stream?all=1`) to fire `eufynized_event` and send phone pushes.
final class AlertCenter {
    struct Alert {
        var id: String
        var title: String
        var kind: String
        var camera: String
        var channel: Int
        var time: Date
        /// The HomeBase's event type: 3101 motion, 3102/3111/3112 person, 3103 doorbell, 3104 crying, 3105 sound,
        /// 3106/3108–3110 pet, 3107 vehicle.
        var eventType: Int = 0
        /// A sentence or a few lines for health, loitering and digest alerts (camera events have none).
        var detail: String?

        var json: [String: Any] {
            var out: [String: Any] = ["id": id, "title": title, "kind": kind, "camera": camera, "channel": channel,
                                      "time": time.timeIntervalSince1970 * 1000, "eventType": eventType]
            if let detail { out["detail"] = detail }
            return out
        }
    }

    private let bridge: Bridge
    private let lock = NSLock()
    private var recent: [Alert] = []
    private var listeners: [UUID: (Alert) -> Void] = [:]
    /// Every event, with whether it passes the alert settings (and so should notify).
    private var rawListeners: [UUID: ([String: Any]) -> Void] = [:]
    private var watcher: HomeBaseEventWatcher?
    private(set) var status = "starting"

    /// Health, loitering and digest alerts; set by main.
    var monitors: Monitors?

    init(bridge: Bridge) { self.bridge = bridge }

    var settings: [String: Any] {
        let all = bridge.prefs.all
        return ["enabled": all["alertsEnabled"] as? Bool ?? true,
                "kinds": all["alertKinds"] as? [String] ?? HomeBaseLiveEvent.Kind.allCases.map(\.rawValue),
                "mutedChannels": all["alertMutedChannels"] as? [Int] ?? [],
                "push": all["alertPush"] as? Bool ?? false,
                "notifyService": all["notifyService"] as? String ?? "",
                // Quiet hours ("22:00"–"07:00", or absent), per-camera alert windows {"2": {"start","end"}}, digest time.
                "quietHours": all["quietHours"] as? [String: String] ?? NSNull(),
                "schedules": all["alertSchedules"] as? [String: [String: String]] ?? [:],
                "digestTime": all["digestTime"] as? String ?? "07:00",
                "falseAlarms": (all["falseAlarms"] as? [String])?.count ?? 0]
    }

    /// "HH:mm" windows that may wrap midnight; nil window = always.
    static func within(_ window: [String: String]?, at date: Date = Date()) -> Bool {
        guard let window, let start = window["start"], let end = window["end"], start != end else { return true }
        let f = DateFormatter(); f.dateFormat = "HH:mm"
        let now = f.string(from: date)
        return start < end ? (now >= start && now < end) : (now >= start || now < end)
    }

    /// Camera-event alerts are held during quiet hours and outside a camera's own window. Health and digest
    /// alerts ignore both.
    func alertsAllowed(channel: Int, at date: Date = Date()) -> Bool {
        let all = bridge.prefs.all
        if let quiet = all["quietHours"] as? [String: String], Self.within(quiet, at: date) { return false }
        let schedule = (all["alertSchedules"] as? [String: [String: String]])?[String(channel)]
        return Self.within(schedule, at: date)
    }

    /// Marks an alert as a false alarm (from a notification button). Kept for the record and shown in settings;
    /// later detection work can learn from it.
    func markFalseAlarm(_ id: String) {
        var list = (bridge.prefs.all["falseAlarms"] as? [String]) ?? []
        list.append("\(id)@\(Int(Date().timeIntervalSince1970))")
        if list.count > 200 { list.removeFirst(list.count - 200) }
        bridge.prefs.merge(["falseAlarms": list])
    }

    /// An alert made here (health, loitering, digest) rather than announced by the HomeBase. Goes through the
    /// mute and snooze checks for its camera, never the quiet hours.
    func deliverExtra(kind: String, title: String, detail: String, channel: Int, camera: String) {
        if channel >= 0, (settings["mutedChannels"] as? [Int])?.contains(channel) == true || snoozedUntil(channel) != nil { return }
        log("\(kind): \(detail.split(separator: "\n").first ?? "")")
        deliver(Alert(id: "\(kind)-\(Int(Date().timeIntervalSince1970 * 1000))", title: title, kind: kind, camera: camera,
                      channel: channel, time: Date(), detail: detail))
    }

    /// The HomeBase's guard mode (0 Away, 1 Home, 63 Disarmed, …), as it last reported it. The HomeBase only
    /// announces changes, so the last one seen is kept across restarts.
    var guardMode: Int? { watcher?.guardMode ?? bridge.prefs.all["guardMode"] as? Int }

    /// The HomeBase's storage report, asked over the event session (nil when it's not connected or didn't answer).
    func storageInfo() -> [String: Any]? {
        guard let watcher else { return nil }
        return blocking { await watcher.storageInfo() }
    }

    func snooze(channel: UInt8, seconds: Int) -> Int? {
        guard let watcher else { return nil }
        return blocking { await watcher.snooze(channel: channel, seconds: seconds) }
    }

    /// When a camera's snooze ends (nil when it isn't snoozed). Kept in prefs so a restart doesn't end it.
    func snoozedUntil(_ channel: some BinaryInteger) -> Date? {
        guard let t = (bridge.prefs.all["snoozedUntil"] as? [String: Double])?[String(channel)] else { return nil }
        let until = Date(timeIntervalSince1970: t)
        return until > Date() ? until : nil
    }

    func noteSnooze(channel: UInt8, until: Date?) {
        var all = (bridge.prefs.all["snoozedUntil"] as? [String: Double]) ?? [:]
        all = all.filter { $0.value > Date().timeIntervalSince1970 }
        all[String(channel)] = until?.timeIntervalSince1970
        bridge.prefs.merge(["snoozedUntil": all])
    }

    var eventWatcher: HomeBaseEventWatcher? { watcher }

    func setGuardMode(_ mode: Int) -> Int? {
        guard let watcher else { return nil }
        return blocking { await watcher.setGuardMode(mode) }
    }

    func start() {
        let watcher = HomeBaseEventWatcher(homeBaseIP: bridge.homeBaseIP, context: bridge.context)
        self.watcher = watcher
        watcher.onGuardMode = { [weak self] mode in
            log("guard mode: \(mode)")
            self?.bridge.prefs.merge(["guardMode": mode])
            self?.broadcastRaw(["type": "guard", "mode": mode])
        }
        watcher.start(onEvent: { [weak self] event in self?.handle(event) }, onStatus: { [weak self] status in
            let text: String
            switch status {
            case .connecting: text = "connecting"
            case .listening: text = "listening"
            case .retrying(let seconds): text = "retrying in \(seconds)s"
            }
            self?.lock.withLock { self?.status = text }
            log("alerts: \(text)")
        })
    }

    var recentJSON: [[String: Any]] { lock.withLock { recent.map(\.json) } }

    func listen(_ handler: @escaping (Alert) -> Void) -> UUID {
        let id = UUID()
        lock.withLock { listeners[id] = handler }
        return id
    }

    func stopListening(_ id: UUID) { _ = lock.withLock { listeners.removeValue(forKey: id); rawListeners.removeValue(forKey: id) } }

    func listenToAll(_ handler: @escaping ([String: Any]) -> Void) -> UUID {
        let id = UUID()
        lock.withLock { rawListeners[id] = handler }
        return id
    }

    private func handle(_ event: HomeBaseLiveEvent) {
        let name = bridge.camera(UInt8(clamping: event.channel))?.name ?? event.cameraName
        let alert = Alert(id: "\(event.channel)-\(Int(event.triggerTime.timeIntervalSince1970 * 1000))",
                          title: event.title, kind: event.kind.rawValue, camera: name, channel: event.channel,
                          time: event.triggerTime, eventType: event.eventType)
        log("event: \(alert.title) · \(name)")
        let s = settings
        let passes = s["enabled"] as? Bool == true && (s["kinds"] as? [String])?.contains(alert.kind) == true
            && (s["mutedChannels"] as? [Int])?.contains(alert.channel) != true
            && snoozedUntil(alert.channel) == nil
            && alertsAllowed(channel: alert.channel)
        if passes { deliver(alert) } else { broadcastRaw(alert, notify: false) }
        if event.kind == .person { monitors?.notePerson(channel: event.channel, at: event.triggerTime, camera: name) }
    }

    /// Runs a made-up HomeBase event (the same JSON a real announcement carries) through the normal handling, so
    /// the whole chain — Home Assistant's sensors, pictures and automations — can be tested on demand.
    @discardableResult
    func simulate(channel: Int, eventType: Int) -> Bool {
        guard let camera = bridge.camera(UInt8(clamping: channel)) else { return false }
        let payload: [String: Any] = ["event_type": eventType, "device_sn": camera.serial, "channel": channel,
                                      "name": camera.name, "trigger_time": Int(Date().timeIntervalSince1970 * 1000)]
        guard let inner = try? JSONSerialization.data(withJSONObject: payload),
              let outer = try? JSONSerialization.data(withJSONObject: ["cmd": 2037, "payload": String(decoding: inner, as: UTF8.self)]),
              let event = HomeBaseLiveEvent.parse(outer) else { return false }
        log("simulated event \(eventType) on ch\(channel)")
        handle(event)
        return true
    }

    /// A sample alert from the first camera, so alerts can be checked without waiting for motion.
    func sendTest() {
        guard let camera = bridge.config.cameras.first else { return }
        deliver(Alert(id: "test-\(Int(Date().timeIntervalSince1970))", title: "Test alert", kind: "motion",
                      camera: camera.name, channel: camera.channel, time: Date()))
    }

    private func broadcastRaw(_ json: [String: Any]) {
        let handlers = lock.withLock { Array(rawListeners.values) }
        handlers.forEach { $0(json) }
    }

    private func broadcastRaw(_ alert: Alert, notify: Bool) {
        var json = alert.json
        json["alert"] = notify
        json["push"] = notify && settings["push"] as? Bool == true
        let handlers = lock.withLock { Array(rawListeners.values) }
        handlers.forEach { $0(json) }
    }

    private func deliver(_ alert: Alert) {
        let handlers = lock.withLock { () -> [(Alert) -> Void] in
            recent.insert(alert, at: 0)
            if recent.count > 100 { recent.removeLast(recent.count - 100) }
            return Array(listeners.values)
        }
        handlers.forEach { $0(alert) }
        broadcastRaw(alert, notify: true)
    }

}
