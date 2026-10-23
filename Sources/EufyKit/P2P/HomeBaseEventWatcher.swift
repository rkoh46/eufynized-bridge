import Foundation

/// An event the HomeBase announces the moment it happens, over the direct session — no cloud, no polling.
/// It arrives as a `CMD_NOTIFY_PAYLOAD` (1351) on the station channel: `{"cmd":2037,"payload":"<JSON string>"}`
/// with `event_type`, the camera's serial / name / channel, trigger time, and the clip and snapshot paths.
/// (Seen on a HomeBase 3 for a Living Room person event; event codes from eufy-security-client.)
public struct HomeBaseLiveEvent: Sendable, Hashable {
    public var eventType: Int
    public var deviceSerial: String
    public var cameraName: String
    public var channel: Int
    public var triggerTime: Date
    public var clipPath: String?
    public var snapshotPath: String?

    public enum Kind: String, Sendable, CaseIterable, Codable {
        case motion, person, pet, vehicle, sound, doorbell
    }

    /// The broad kind, for filtering and the banner title.
    public var kind: Kind {
        switch eventType {
        case 3102, 3111, 3112: .person   // person, known person, stranger
        case 3103: .doorbell
        case 3104, 3105: .sound          // crying, sound
        case 3106, 3108, 3109, 3110: .pet
        case 3107: .vehicle
        default: .motion                 // 3101 and anything newer
        }
    }

    public var title: String {
        switch eventType {
        case 3111: "Known person"
        case 3112: "Stranger"
        case 3104: "Crying"
        default:
            switch kind {
            case .motion: "Motion"
            case .person: "Person"
            case .pet: "Pet"
            case .vehicle: "Vehicle"
            case .sound: "Sound"
            case .doorbell: "Doorbell"
            }
        }
    }

    /// Parses a decrypted 1351 notification; nil unless it's an event announcement (cmd 2037).
    public static func parse(_ plaintext: Data) -> HomeBaseLiveEvent? {
        let text = plaintext.prefix { $0 != 0 }
        guard let outer = try? JSONSerialization.jsonObject(with: text) as? [String: Any],
              (outer["cmd"] as? NSNumber)?.intValue == 2037 else { return nil }
        // The payload is itself a JSON string.
        let inner: [String: Any]?
        if let s = outer["payload"] as? String { inner = try? JSONSerialization.jsonObject(with: Data(s.utf8)) as? [String: Any] }
        else { inner = outer["payload"] as? [String: Any] }
        guard let p = inner, let type = (p["event_type"] as? NSNumber)?.intValue,
              let serial = p["device_sn"] as? String, let channel = (p["channel"] as? NSNumber)?.intValue else { return nil }
        let ms = (p["trigger_time"] as? NSNumber)?.doubleValue ?? (p["create_time"] as? NSNumber)?.doubleValue
        func path(_ key: String) -> String? { (p[key] as? String).flatMap { $0.isEmpty ? nil : $0 } }
        return HomeBaseLiveEvent(eventType: type, deviceSerial: serial, cameraName: p["name"] as? String ?? serial,
                                 channel: channel, triggerTime: ms.map { Date(timeIntervalSince1970: $0 / 1000) } ?? Date(),
                                 clipPath: path("file_path"), snapshotPath: path("pic_filepath"))
    }
}

/// Keeps one quiet control session open to the HomeBase (no video) and reports each event it announces.
/// Reconnects with backoff whenever the HomeBase drops or stops answering, and drops repeats of an event.
public final class HomeBaseEventWatcher: @unchecked Sendable {
    private let homeBaseIP: String?
    private let context: EufyLiveStream.Level2Context
    private let lock = NSLock()
    private var task: Task<Void, Never>?
    private var seen: [String] = []   // recent event keys, oldest first
    private var session: HomeBaseSession?
    private var pendingReply: CheckedContinuation<Int?, Never>?
    private var listeners: [UUID: @Sendable (UInt16, Data) -> Void] = [:]

    /// The HomeBase's guard mode as it reports it (CMD_GET_ALARM_MODE 1151, sent when it changes): 0 Away,
    /// 1 Home, 2 Schedule, 3–5 Custom, 6 Off, 47 Geofencing, 63 Disarmed.
    public var onGuardMode: (@Sendable (Int) -> Void)?
    public private(set) var guardMode: Int?

    public enum GuardMode: Int, Sendable { case away = 0, home = 1, schedule = 2, off = 6, geo = 47, disarmed = 63 }

    /// Sets the guard mode (CMD_SET_ARMING 1224 inside SET_PAYLOAD, as eufy-security-client does for a HomeBase 3).
    /// Returns the HomeBase's result code (0 = done), or nil if it's not connected or didn't answer.
    public func setGuardMode(_ mode: Int) async -> Int? {
        guard let session = lock.withLock({ self.session }) else { return nil }
        let code = await withCheckedContinuation { (c: CheckedContinuation<Int?, Never>) in
            let previous = lock.withLock { () -> CheckedContinuation<Int?, Never>? in defer { pendingReply = c }; return pendingReply }
            previous?.resume(returning: nil)
            session.sendSetPayload(cmd: 1224, channel: PPPPMessage.stationChannel, mValue3: 0,
                                   payloadJSON: "{\"mode_type\":\(mode),\"user_name\":\"Eufynized\"}")
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(8))
                self?.finishReply(nil)
            }
        }
        // Accepted: that's the mode now (the HomeBase announces only actual changes, not a repeat of the same mode).
        if code == 0 {
            lock.withLock { guardMode = mode }
            onGuardMode?(mode)
        }
        return code
    }

    /// The HomeBase's storage (CMD_STORAGE_INFO_HB3 1307 inside SET_PAYLOAD, inner cmd 11001, as eufy-security-client
    /// asks a HomeBase 3). It answers with a 1351 notify `{"cmd":1307,"payload":{"body":{…}}}`; returns that body.
    public func storageInfo() async -> [String: Any]? {
        let reply = await request(timeout: 8, matching: { (cmd: UInt16, plain: Data) -> [String: Any]? in
            guard cmd == 1351, let json = Self.json(plain), (json["cmd"] as? NSNumber)?.intValue == 1307 else { return nil }
            return ((json["payload"] as? [String: Any])?["body"] as? [String: Any]) ?? (json["payload"] as? [String: Any]) ?? json
        }) { session in
            session.sendSetPayload(cmd: 1307, channel: 0, mValue3: 0, payloadJSON: "{\"version\":0,\"cmd\":11001}")
        }
        return reply
    }

    /// The HomeBase's own report (CMD_CAMERA_INFO 1103 on channel 255): its firmware versions and its parameters
    /// (dev_type 255), e.g. 1257 the mode it falls back to outside the arming schedule.
    public func stationInfo() async -> (params: [Int: String], firmware: String?, secondaryFirmware: String?)? {
        await request(timeout: 8, matching: { (cmd: UInt16, plain: Data) -> ([Int: String], String?, String?)? in
            guard cmd == 1103, plain.count > 100, let json = Self.json(plain), let list = json["params"] as? [[String: Any]] else { return nil }
            var params: [Int: String] = [:]
            for p in list where (p["dev_type"] as? NSNumber)?.intValue == 255 {
                if let k = (p["param_type"] as? NSNumber)?.intValue { params[k] = p["param_value"] as? String ?? "" }
            }
            return (params, json["main_sw_version"] as? String, json["sec_sw_version"] as? String)
        }) { session in
            guard let key = session.level2Key else { return }
            session.connection.sendLevel2Command(1103, channel: 255, plaintext: Data([255, 0, 0, 0, 0, 0, 0, 0]), level2Key: key)
        }.map { (params: $0.0, firmware: $0.1, secondaryFirmware: $0.2) }
    }

    /// Snoozes a camera's notifications for `seconds` (APP_CMD_SET_SNOOZE_MODE 1271, the JSON eufy-security-client
    /// sends, level-2 on the camera's channel). 0 ends a snooze. Returns the result code if the HomeBase answered.
    public func snooze(channel: UInt8, seconds: Int) async -> Int? {
        let json = "{\"account_id\":\"\(context.accountID)\",\"snooze_time\":\(max(0, seconds))," +
            "\"startTime\":\"\(Int(Date().timeIntervalSince1970))\",\"chime_onoff\":0,\"motion_notify_onoff\":1,\"homebase_onoff\":0}"
        return await request(timeout: 6, matching: { (cmd: UInt16, plain: Data) -> Int? in
            guard cmd == 1271, plain.count >= 4 else { return nil }
            return Self.int32(plain)
        }) { session in
            guard let key = session.level2Key else { return }
            session.connection.sendLevel2Command(1271, channel: channel, plaintext: Data(json.utf8), level2Key: key)
        }
    }

    /// Sends something on the watcher's session and waits for the first frame `matching` turns into a value.
    private func request<T>(timeout: TimeInterval, matching: @escaping @Sendable (UInt16, Data) -> T?,
                            send: (HomeBaseSession) -> Void) async -> T? {
        guard let session = lock.withLock({ self.session }) else { return nil }
        let id = UUID()
        let box = ReplyBox<T>()
        let result: T? = await withCheckedContinuation { (c: CheckedContinuation<T?, Never>) in
            box.set(c)
            lock.withLock { listeners[id] = { cmd, plain in if let v = matching(cmd, plain) { box.finish(v) } } }
            send(session)
            Task { try? await Task.sleep(for: .seconds(timeout)); box.finish(nil) }
        }
        _ = lock.withLock { listeners.removeValue(forKey: id) }
        return result
    }

    /// Every frame the session receives, decrypted, for `seconds` after sending (probing unknown replies).
    public func capture(seconds: TimeInterval, send: (HomeBaseSession) -> Void) async -> [(cmd: UInt16, plain: Data)]? {
        guard let session = lock.withLock({ self.session }) else { return nil }
        let id = UUID()
        let frames = FrameLog()
        lock.withLock { listeners[id] = { cmd, plain in if cmd != 1139 { frames.add(cmd, plain) } } }
        send(session)
        try? await Task.sleep(for: .seconds(seconds))
        _ = lock.withLock { listeners.removeValue(forKey: id) }
        return frames.all
    }

    static func json(_ plain: Data) -> [String: Any]? {
        guard let start = plain.firstIndex(of: UInt8(ascii: "{")) else { return nil }
        let text = plain[start...].prefix { $0 != 0 }
        return try? JSONSerialization.jsonObject(with: Data(text)) as? [String: Any]
    }

    static func int32(_ plain: Data) -> Int {
        let b = [UInt8](plain.prefix(4))
        return Int(Int32(bitPattern: UInt32(b[0]) | UInt32(b[1]) << 8 | UInt32(b[2]) << 16 | UInt32(b[3]) << 24))
    }

    private func finishReply(_ code: Int?) {
        let c = lock.withLock { () -> CheckedContinuation<Int?, Never>? in defer { pendingReply = nil }; return pendingReply }
        c?.resume(returning: code)
    }

    /// Connection state, for the UI (e.g. "Alerts: connected").
    public enum Status: Sendable, Equatable { case connecting, listening, retrying(seconds: Int) }

    public init(homeBaseIP: String?, context: EufyLiveStream.Level2Context) {
        self.homeBaseIP = homeBaseIP
        self.context = context
    }

    public func start(onEvent: @escaping @Sendable (HomeBaseLiveEvent) -> Void,
                      onStatus: @escaping @Sendable (Status) -> Void = { _ in }) {
        stop()
        task = Task { [weak self] in
            var backoff = 5
            while !Task.isCancelled, let self {
                onStatus(.connecting)
                if await self.listenOnce(onEvent: onEvent, onListening: { onStatus(.listening); backoff = 5 }) {
                    backoff = 5   // the session ran and then dropped: reconnect promptly
                } else {
                    onStatus(.retrying(seconds: backoff))
                    try? await Task.sleep(for: .seconds(backoff))
                    backoff = min(backoff * 2, 120)
                }
            }
        }
    }

    public func stop() {
        task?.cancel()
        task = nil
    }

    /// One session: open, listen until it goes quiet, close. Returns true if it got as far as listening.
    private func listenOnce(onEvent: @escaping @Sendable (HomeBaseLiveEvent) -> Void, onListening: () -> Void) async -> Bool {
        guard let session = try? HomeBaseSession(homeBaseIP: homeBaseIP, context: context) else { return false }
        defer { session.close() }
        let debug = ProcessInfo.processInfo.environment["EUFYNIZED_WATCH_DEBUG"] == "1"
        let token = session.addFrameHandler { [weak self] kind, cmd, signCode, body in
            guard let self, let cmd else { return }
            let listeners = self.lock.withLock { Array(self.listeners.values) }
            if !listeners.isEmpty {
                let plain = session.decryptControl(body, signCode: signCode)
                listeners.forEach { $0(cmd, plain) }
            }
            switch cmd {
            case 1351:
                let plain = session.decryptControl(body, signCode: signCode)
                if let event = HomeBaseLiveEvent.parse(plain) {
                    if self.isNew(event) { onEvent(event) }
                } else if debug {
                    FileHandle.standardError.write(Data("[watcher] 1351 \(String(decoding: plain.prefix { $0 != 0 }.prefix(300), as: UTF8.self))\n".utf8))
                }
            case 1151:
                // CMD_GET_ALARM_MODE: the first byte is the new guard mode.
                let plain = session.decryptControl(body, signCode: signCode)
                guard let mode = plain.first.map(Int.init) else { return }
                self.lock.withLock { self.guardMode = mode }
                self.onGuardMode?(mode)
            case 1350:
                // The answer to SET_PAYLOAD: a little-endian Int32 result code.
                let plain = session.decryptControl(body, signCode: signCode)
                guard plain.count >= 4 else { return }
                let b = [UInt8](plain.prefix(4))
                self.finishReply(Int(Int32(bitPattern: UInt32(b[0]) | UInt32(b[1]) << 8 | UInt32(b[2]) << 16 | UInt32(b[3]) << 24)))
            default:
                if debug, cmd != 1139 {
                    let plain = session.decryptControl(body, signCode: signCode)
                    FileHandle.standardError.write(Data("[watcher] cmd=\(cmd) kind=\(kind) sign=\(signCode) \(plain.prefix(48).map { String(format: "%02x", $0) }.joined())\n".utf8))
                }
            }
        }
        defer { session.removeFrameHandler(token) }
        do { try await session.open() } catch { return false }
        lock.withLock { self.session = session }
        defer { lock.withLock { if self.session === session { self.session = nil } } }
        onListening()
        // The HomeBase answers the session's heartbeat; when it stops for a while, the session is gone.
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(10))
            if let last = session.connection.lastContact, Date().timeIntervalSince(last) > 45 { break }
        }
        return true
    }

    /// The same event can be announced more than once (and again after a reconnect).
    private func isNew(_ event: HomeBaseLiveEvent) -> Bool {
        let key = "\(event.channel)-\(event.eventType)-\(Int(event.triggerTime.timeIntervalSince1970 * 1000))"
        return lock.withLock {
            if seen.contains(key) { return false }
            seen.append(key)
            if seen.count > 200 { seen.removeFirst(seen.count - 200) }
            return true
        }
    }
}

/// One reply for `HomeBaseEventWatcher.request`: resumes its continuation once, whichever comes first.
private final class ReplyBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T?, Never>?
    func set(_ c: CheckedContinuation<T?, Never>) { lock.withLock { continuation = c } }
    func finish(_ value: T?) {
        let c = lock.withLock { () -> CheckedContinuation<T?, Never>? in defer { continuation = nil }; return continuation }
        c?.resume(returning: value)
    }
}

private final class FrameLog: @unchecked Sendable {
    private let lock = NSLock()
    private var frames: [(cmd: UInt16, plain: Data)] = []
    func add(_ cmd: UInt16, _ plain: Data) { lock.withLock { frames.append((cmd, plain)) } }
    var all: [(cmd: UInt16, plain: Data)] { lock.withLock { frames } }
}
