import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import EufyKit

func log(_ message: String) {
    let stamp = ISO8601DateFormatter().string(from: Date())
    FileHandle.standardError.write(Data("\(stamp) \(message)\n".utf8))
}

/// Runs async work from a request thread and waits for it.
func blocking<T>(_ body: @escaping () async -> T) -> T {
    let done = DispatchSemaphore(value: 0)
    var result: T?
    Task { result = await body(); done.signal() }
    done.wait()
    return result!
}

/// What the bridge needs to reach the HomeBase, exported once from the Mac app (`scripts/export-ha-config.sh`):
/// no Eufy password or cloud session, just the account id and the station's ECC key.
struct BridgeConfig: Codable {
    var homeBaseIP: String
    var stationSerial: String
    var accountID: String
    var eccPrivateKeyHex: String
    var cameras: [CameraInfo]
}

/// The Home Assistant add-on's options (`/data/options.json`).
struct AddonOptions: Codable {
    var homebase_ip: String?
}

/// Viewer preferences shared by every browser (phone and desktop see the same order and layout).
final class Prefs {
    private let file: URL
    private let lock = NSLock()
    private var values: [String: Any]

    init(file: URL) {
        self.file = file
        values = (try? Data(contentsOf: file)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
    }

    var all: [String: Any] { lock.withLock { values } }

    /// Merges the given keys in and saves.
    func merge(_ update: [String: Any]) {
        lock.withLock {
            for (k, v) in update { values[k] = v is NSNull ? nil : v }
            if let data = try? JSONSerialization.data(withJSONObject: values, options: [.sortedKeys]) { try? data.write(to: file) }
        }
    }

    /// The camera's live quality: the viewer's pick, else the highest it can do (the user wants full resolution).
    func quality(_ channel: UInt8) -> StreamQuality? {
        ((all["quality"] as? [String: String])?[String(channel)]).flatMap(StreamQuality.init(rawValue:)) ?? .max
    }

    /// Values of write-only settings (the camera never reports them) as last written, by channel then key.
    func remembered(_ channel: UInt8) -> [Int: Int] {
        ((all["remembered"] as? [String: [String: Int]])?[String(channel)] ?? [:])
            .reduce(into: [:]) { out, item in if let k = Int(item.key) { out[k] = item.value } }
    }

    func remember(_ value: Int, key: Int, channel: UInt8) {
        var all = (self.all["remembered"] as? [String: [String: Int]]) ?? [:]
        var mine = all[String(channel)] ?? [:]
        mine[String(key)] = value
        all[String(channel)] = mine
        merge(["remembered": all])
    }

    // Preset positions a pan-tilt camera has saved (we can't ask the camera; we note what we told it), and the
    // "home" preset to return to a few minutes after any move.
    func presets(_ channel: UInt8) -> [Int] { ((all["presets"] as? [String: [Int]])?[String(channel)] ?? []).sorted() }
    func notePreset(channel: UInt8, index: Int, saved: Bool) {
        var all = (self.all["presets"] as? [String: [Int]]) ?? [:]
        var mine = Set(all[String(channel)] ?? [])
        if saved { mine.insert(index) } else { mine.remove(index) }
        all[String(channel)] = Array(mine).sorted()
        merge(["presets": all])
    }
    func home(_ channel: UInt8) -> [String: Int]? { (all["ptzHome"] as? [String: [String: Int]])?[String(channel)] }
    func setHome(channel: UInt8, index: Int?, minutes: Int) {
        var all = (self.all["ptzHome"] as? [String: [String: Int]]) ?? [:]
        all[String(channel)] = index.map { ["index": $0, "minutes": max(1, minutes)] }
        merge(["ptzHome": all])
    }

    func setQuality(_ quality: StreamQuality, channel: UInt8) {
        var q = (all["quality"] as? [String: String]) ?? [:]
        q[String(channel)] = quality.rawValue
        merge(["quality": q])
    }
}

final class Bridge {
    let config: BridgeConfig
    let options: AddonOptions
    let dataDir: URL
    let wwwDir: URL
    let port: UInt16
    let prefs: Prefs
    let context: EufyLiveStream.Level2Context
    private(set) lazy var hub = LiveHub(bridge: self)
    let recordings: HomeBaseRecordings
    private let lock = NSLock()
    private var availability: [UInt8: (state: CameraAvailability, at: Date)] = [:]
    private var snapshotTimes: [UInt8: Date] = [:]

    var homeBaseIP: String { (options.homebase_ip?.isEmpty == false ? options.homebase_ip : nil) ?? config.homeBaseIP }

    init(config: BridgeConfig, options: AddonOptions, dataDir: URL, wwwDir: URL, port: UInt16) {
        self.config = config
        self.options = options
        self.dataDir = dataDir
        self.wwwDir = wwwDir
        self.port = port
        prefs = Prefs(file: dataDir.appendingPathComponent("prefs.json"))
        context = .init(stationSerial: config.stationSerial, accountID: config.accountID, eccPrivateKeyHex: config.eccPrivateKeyHex)
        recordings = HomeBaseRecordings(homeBaseIP: (options.homebase_ip?.isEmpty == false ? options.homebase_ip : nil) ?? config.homeBaseIP,
                                        context: context)
        try? FileManager.default.createDirectory(at: snapshotDir, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
    }

    var snapshotDir: URL { dataDir.appendingPathComponent("snapshots", isDirectory: true) }
    var cacheDir: URL { URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("eufynized", isDirectory: true) }

    func camera(_ channel: UInt8) -> CameraInfo? { config.cameras.first { $0.channel == Int(channel) } }

    func streamConfig(channel: UInt8, video: Bool) -> EufyLiveStream.Config {
        // The quality table is keyed by model code (the serial's first five characters), not the model name.
        var c = EufyLiveStream.Config(homeBaseIP: homeBaseIP, channel: channel, level2: context, audio: true,
                                      model: camera(channel)?.serial)
        c.video = video
        return c
    }

    /// Told when a camera shows signs of life (video, a picture, "online"); health monitoring listens.
    var onAlive: ((UInt8) -> Void)?

    func noteAvailability(_ channel: UInt8, _ state: CameraAvailability) {
        lock.withLock { availability[channel] = (state, Date()) }
        if state == .online { onAlive?(channel) }
    }

    func availabilityOf(_ channel: UInt8) -> CameraAvailability? { lock.withLock { availability[channel]?.state } }

    /// The HomeBase said in the last two minutes that this camera can't stream (offline, off, flat battery). Live
    /// requests then don't open a session for it: the HomeBase allows only so many at once, and an unplugged
    /// camera would take one from a camera that can stream.
    func knownUnavailable(_ channel: UInt8) -> CameraAvailability? {
        lock.withLock {
            guard let (state, at) = availability[channel], state != .online, Date().timeIntervalSince(at) < 120 else { return nil }
            return state
        }
    }

    // MARK: Snapshots

    private static let snapshotSlots = DispatchSemaphore(value: 2)

    /// The camera's latest picture: the saved one when it's younger than `maxAge`, else a fresh keyframe
    /// from the camera, decoded by ffmpeg.
    func snapshot(_ channel: UInt8, maxAge: TimeInterval) -> Data? {
        let file = snapshotDir.appendingPathComponent("ch\(channel).jpg")
        let saved = try? Data(contentsOf: file)
        let age = (try? FileManager.default.attributesOfItem(atPath: file.path)[.modificationDate] as? Date)
            .map { Date().timeIntervalSince($0) } ?? .infinity
        if let saved, age < maxAge { return saved }
        // Offline per the HomeBase a moment ago: don't spend one of its few sessions on it.
        if knownUnavailable(channel) != nil { return saved }
        // Thumbnails for several cameras tend to be asked for together (Home Assistant starting, a dashboard
        // opening). Opening a session for each at once can exceed what the HomeBase allows and stall a stream
        // someone is watching, so cameras nobody is watching take turns, two at a time.
        let borrowed = hub.feed(channel) == nil
        if borrowed { Self.snapshotSlots.wait() }
        defer { if borrowed { Self.snapshotSlots.signal() } }
        guard let (ts, _) = hub.keyframe(channel),
              let jpeg = FFmpeg.run(["-f", "mpegts", "-i", "pipe:0", "-frames:v", "1", "-vf", "scale='min(960,iw)':-2",
                                     "-q:v", "5", "-f", "image2", "-c:v", "mjpeg", "pipe:1"], input: ts),
              jpeg.count > 100 else { return saved }
        try? jpeg.write(to: file)
        noteAvailability(channel, .online)
        return jpeg
    }

    /// A fresh frame at the camera's full resolution and high JPEG quality, for alert pictures. Waits a moment
    /// for a sharper keyframe when the stream starts small (Auto quality ramps up over the first seconds).
    func fullSnapshot(_ channel: UInt8, settle: TimeInterval = 6) -> Data? {
        if knownUnavailable(channel) != nil { return nil }
        guard let ts = hub.sharpestKeyframe(channel, within: settle) else { return nil }
        return FFmpeg.run(["-f", "mpegts", "-i", "pipe:0", "-frames:v", "1", "-q:v", "2", "-f", "image2", "-c:v", "mjpeg", "pipe:1"],
                          input: ts)
    }

    func snapshotDate(_ channel: UInt8) -> Date? {
        let file = snapshotDir.appendingPathComponent("ch\(channel).jpg")
        return try? FileManager.default.attributesOfItem(atPath: file.path)[.modificationDate] as? Date
    }

    // MARK: Return home

    private var returnHome: [UInt8: DispatchWorkItem] = [:]

    /// After a pan (or a jump to another preset), goes back to the camera's home preset once it has been left
    /// alone for the configured minutes. Each new move restarts the clock.
    func scheduleReturnHome(_ channel: UInt8, movedTo index: Int?) {
        guard let home = prefs.home(channel), let homeIndex = home["index"], index != homeIndex else {
            lock.withLock { returnHome[channel]?.cancel(); returnHome[channel] = nil }
            return
        }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let (stream, fresh) = controlStream(channel)
            if fresh { Thread.sleep(forTimeInterval: 2.5) }
            stream.preset(.go, index: homeIndex)
            log("ptz ch\(channel): back to home preset \(homeIndex + 1)")
        }
        lock.withLock { returnHome[channel]?.cancel(); returnHome[channel] = work }
        DispatchQueue.global().asyncAfter(deadline: .now() + Double((home["minutes"] ?? 5) * 60), execute: work)
    }

    // MARK: Time-lapses

    private var timelapses: [String: Timelapse] = [:]

    func timelapse(_ channel: UInt8, date: String) -> Timelapse {
        lock.withLock {
            let key = "\(channel)-\(date)"
            if let t = timelapses[key] { return t }
            let t = Timelapse(bridge: self, channel: channel, date: date)
            timelapses[key] = t
            return t
        }
    }

    // MARK: Panoramas

    private var panoramas: [UInt8: Panorama] = [:]

    func panorama(_ channel: UInt8) -> Panorama {
        lock.withLock {
            if let p = panoramas[channel] { return p }
            let p = Panorama(bridge: self, channel: channel)
            panoramas[channel] = p
            return p
        }
    }

    // MARK: Settings sessions

    private var controlSessions: [UInt8: (stream: EufyLiveStream, lastUsed: Date)] = [:]

    /// A session for reading and writing a camera's settings: the live stream if it's being watched, else a
    /// control-only session (keys, no video) kept for a minute after last use.
    func controlStream(_ channel: UInt8) -> (EufyLiveStream, fresh: Bool) {
        if let feed = hub.feed(channel) { return (feed.stream, false) }
        return lock.withLock {
            if let s = controlSessions[channel] {
                controlSessions[channel]?.lastUsed = Date()
                return (s.stream, false)
            }
            #if canImport(CoreMedia)
            let stream = EufyLiveStream(config: streamConfig(channel: channel, video: false), onSample: { _ in })
            #else
            let stream = EufyLiveStream(config: streamConfig(channel: channel, video: false))
            #endif
            stream.onAvailability = { [weak self] in self?.noteAvailability(channel, $0) }
            stream.start()
            controlSessions[channel] = (stream, Date())
            return (stream, true)
        }
    }

    func closeIdleControlSessions() {
        let idle = lock.withLock { () -> [EufyLiveStream] in
            let old = controlSessions.filter { Date().timeIntervalSince($0.value.lastUsed) > 60 }
            old.keys.forEach { controlSessions[$0] = nil }
            return old.values.map(\.stream)
        }
        idle.forEach { $0.stop() }
    }

    /// Told about every settings read (health monitoring piggybacks on them).
    var onSettingsRead: ((UInt8, [Int: String]?) -> Void)?

    func readSettings(_ channel: UInt8) -> [Int: String]? {
        let (stream, _) = controlStream(channel)
        for _ in 0..<5 {
            if let params = blocking({ await stream.readSettings() }) {
                onSettingsRead?(channel, params)
                return CameraSettingsCatalog.merging(params, remembered: prefs.remembered(channel))
            }
            Thread.sleep(forTimeInterval: 1)
        }
        onSettingsRead?(channel, nil)
        return nil
    }

    // MARK: go2rtc

    static let go2rtcPort: UInt16 = 11984
    /// go2rtc's RTSP server, local only: Home Assistant's camera entities stream from it (only while viewed).
    static let rtspPort: UInt16 = 28554

    func go2rtcConfig() -> String {
        var yaml = """
        api:
          listen: "127.0.0.1:\(Self.go2rtcPort)"
          origin: "*"
        rtsp:
          listen: "127.0.0.1:28554"
        webrtc:
          listen: ""
        srtp:
          listen: ""
        log:
          level: warn
        streams:

        """
        for camera in config.cameras {
            yaml += "  ch\(camera.channel): \"http://127.0.0.1:\(port)/api/stream/\(camera.channel).ts\"\n"
        }
        return yaml
    }

    /// Runs go2rtc (restarting it if it exits) when its binary is present.
    func superviseGo2RTC(binary: String) {
        guard FileManager.default.isExecutableFile(atPath: binary) else { log("go2rtc not found at \(binary); live video in browsers is off"); return }
        let configFile = cacheDir.appendingPathComponent("go2rtc.yaml")
        try? go2rtcConfig().write(to: configFile, atomically: true, encoding: .utf8)
        Thread.detachNewThread {
            while true {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: binary)
                process.arguments = ["-config", configFile.path]
                do { try process.run(); log("go2rtc started"); process.waitUntilExit() } catch { log("go2rtc failed: \(error)") }
                log("go2rtc exited (\(process.terminationStatus)); restarting")
                Thread.sleep(forTimeInterval: 2)
            }
        }
    }
}

/// ffmpeg, for the few things a browser needs decoded or remuxed: snapshot JPEGs and clip MP4s.
enum FFmpeg {
    static var binary: String { ProcessInfo.processInfo.environment["FFMPEG_BIN"] ?? "/usr/bin/ffmpeg" }

    /// Feeds `input` on stdin and returns stdout; nil when ffmpeg fails.
    static func run(_ arguments: [String], input: Data) -> Data? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = ["-hide_banner", "-loglevel", "error"] + arguments
        let stdin = Pipe(), stdout = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { log("ffmpeg: \(error)"); return nil }
        Thread.detachNewThread {
            try? stdin.fileHandleForWriting.write(contentsOf: input)   // throws (not traps) if ffmpeg quit early
            try? stdin.fileHandleForWriting.close()
        }
        let output = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return process.terminationStatus == 0 ? output : nil
    }
}
