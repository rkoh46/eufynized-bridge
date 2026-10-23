import Foundation
import CoreMedia
import ImageIO
import EufyKit

/// The Eufynized bridge on the Pi (the one Home Assistant uses). At home, the Mac app takes its video and pictures
/// from it instead of opening its own HomeBase sessions, so every screen in the house shares one HomeBase session
/// per camera. The HomeBase allows only a few at once; this is what stops one viewer knocking out another.
public struct BridgeClient: Sendable {
    public let base: URL

    public init(base: URL) { self.base = base }

    /// Answers within 3 seconds with its status: the bridge is up and reachable from here.
    public static func reachable(_ base: URL) async -> Bool {
        var request = URLRequest(url: base.appendingPathComponent("api/status"))
        request.timeoutInterval = 3
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
        return json["cameras"] != nil
    }

    private func request(_ path: String, query: [String: String] = [:], json: Any? = nil, timeout: TimeInterval = 20) async -> (Data, Int)? {
        var components = URLComponents(url: base.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { components.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) } }
        guard let url = components.url else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        if let json {
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try? JSONSerialization.data(withJSONObject: json)
        }
        guard let (data, response) = try? await URLSession.shared.data(for: request) else { return nil }
        return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
    }

    /// A picture of the camera. `fresh` asks for a new frame; `full` for the camera's full resolution.
    public func snapshot(channel: UInt8, maxAge: Double = 120, fresh: Bool = false, full: Bool = false) async -> CGImage? {
        var query = ["maxAge": String(Int(maxAge))]
        if fresh { query["fresh"] = "1" }
        if full { query["full"] = "1"; query["settle"] = "0" }
        guard let (data, status) = await request("api/cameras/\(channel)/snapshot.jpg", query: query, timeout: 40), status == 200,
              let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    public func rotate(channel: UInt8, _ direction: PTZDirection) async {
        let name = ["left", "right", "up", "down"][direction.rawValue - 1]
        _ = await request("api/cameras/\(channel)/ptz", json: ["direction": name])
    }

    public func preset(channel: UInt8, _ action: PTZPresetAction, index: Int) async -> [Int] {
        guard let (data, status) = await request("api/cameras/\(channel)/ptz/preset", json: ["action": action.rawValue, "index": index]), status == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
        return json["presets"] as? [Int] ?? []
    }

    public func presets(channel: UInt8) async -> (saved: [Int], home: (index: Int, minutes: Int)?) {
        guard let (data, status) = await request("api/cameras/\(channel)/ptz/preset"), status == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return ([], nil) }
        let home = (json["home"] as? [String: Int]).flatMap { h in h["index"].map { ($0, h["minutes"] ?? 5) } }
        return (json["presets"] as? [Int] ?? [], home)
    }

    public func setHome(channel: UInt8, index: Int?, minutes: Int) async {
        var components = URLComponents(url: base.appendingPathComponent("api/cameras/\(channel)/ptz/home"), resolvingAgainstBaseURL: false)!
        var r = URLRequest(url: components.url!)
        r.httpMethod = "PUT"
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.httpBody = try? JSONSerialization.data(withJSONObject: ["index": index as Any, "minutes": minutes])
        _ = try? await URLSession.shared.data(for: r)
        components.queryItems = nil
    }

    public func zones(channel: UInt8) async -> ActivityZones? {
        guard let (data, status) = await request("api/cameras/\(channel)/zones", timeout: 90), status == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let polys = json["polygons"] as? [[[String: Any]]] else { return nil }
        return ActivityZones(polygons: polys.map { $0.compactMap { pt in
            guard let x = (pt["x"] as? NSNumber)?.intValue, let y = (pt["y"] as? NSNumber)?.intValue else { return nil }
            return (x, y)
        } })
    }

    public func writeZones(channel: UInt8, _ zones: ActivityZones) async -> Bool {
        let body: [String: Any] = ["polygons": zones.polygons.map { $0.map { ["x": $0.x, "y": $0.y] } }]
        guard let (data, status) = await request("api/cameras/\(channel)/zones", json: body, timeout: 120), status == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
        return json["ok"] as? Bool == true
    }

    public func replies(channel: UInt8) async -> [String] {
        guard let (data, status) = await request("api/cameras/\(channel)/replies"), status == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
        return json["replies"] as? [String] ?? []
    }

    /// Plays a stored reply through the camera's speaker; the bridge needs the camera's live feed open (it is,
    /// while the Mac plays it from the bridge).
    public func playReply(channel: UInt8, name: String) async -> Bool {
        guard let (_, status) = await request("api/cameras/\(channel)/replies/play", json: ["name": name]) else { return false }
        return status == 200
    }

    public func setQuality(channel: UInt8, _ quality: StreamQuality) async {
        _ = await request("api/cameras/\(channel)/quality", json: ["quality": quality.rawValue])
    }

    /// Every parameter the camera reports, by number: the same read the HomeBase gives a direct session.
    public func rawSettings(channel: UInt8) async -> [Int: String]? {
        guard let (data, status) = await request("api/cameras/\(channel)/settings", query: ["raw": "1"], timeout: 60), status == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: String] else { return nil }
        var out: [Int: String] = [:]
        for (k, v) in json { if let n = Int(k) { out[n] = v } }
        return out
    }

    /// Writes a setting through the bridge, which reads it back; true when the camera took it.
    public func writeSetting(channel: UInt8, id: String, value: Int) async -> Bool {
        guard let (data, status) = await request("api/cameras/\(channel)/settings", json: ["id": id, "value": value], timeout: 90),
              status == 200, let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
        return json["message"] == nil
    }

    /// The live feed's address: the page's WebSocket, asked for raw frames.
    public func liveURL(channel: UInt8, audio: Bool) -> URL? {
        var components = URLComponents(url: base.appendingPathComponent("api/live/\(channel).mp4"), resolvingAgainstBaseURL: false)!
        components.scheme = components.scheme == "https" ? "wss" : "ws"
        components.queryItems = [URLQueryItem(name: "audio", value: audio ? "1" : "0"), URLQueryItem(name: "format", value: "raw")]
        return components.url
    }
}

/// What a live screen or a grid tile needs from its video source, whether that's a direct HomeBase session
/// (`EufyLiveStream`) or the bridge (`BridgeLiveStream`).
@MainActor public protocol LiveSource: AnyObject {
    func stop()
    func setMuted(_ muted: Bool)
    func setAudioDelay(_ seconds: Double)
    var videoSize: (width: Int, height: Int)? { get }
    /// Bytes received so far, for a network-rate display.
    var bytesReceived: Int { get }
    var sourceChannel: UInt8 { get }
    func rotate(_ direction: PTZDirection)
    func preset(_ action: PTZPresetAction, index: Int)
    func setQuality(_ quality: StreamQuality)
    func readSettings() async -> [Int: String]?
    func writeSetting(_ setting: CameraSetting, deviceType: Int?, value: Int) async -> Bool
    func startTalkback()
    func stopTalkback()
    func readZones() async -> ActivityZones?
    func writeZones(_ zones: ActivityZones) async -> Bool
    /// A full-resolution picture right now (panoramas).
    func snapshot() async -> CGImage?
}

extension EufyLiveStream: LiveSource {
    public var sourceChannel: UInt8 { liveConfig.channel }
    public func readZones() async -> ActivityZones? {
        guard let params = await readSettings(timeout: .seconds(8)) else { return nil }
        return ActivityZones(params: params) ?? ActivityZones(polygons: [])
    }
    public func writeZones(_ zones: ActivityZones) async -> Bool {
        guard let json = zones.controlJSON else { return false }
        sendControlJSON(json)
        try? await Task.sleep(for: .seconds(1.5))
        return await readZones() == zones
    }
    public func readSettings() async -> [Int: String]? { await readSettings(timeout: .seconds(5)) }
    public func snapshot() async -> CGImage? {
        await EufySnapshot.capture(homeBaseIP: liveConfig.homeBaseIP, channel: liveConfig.channel, level2: liveConfig.level2)
    }
}

/// A camera's live video from the bridge: raw H.265 and AAC frames over a WebSocket, decoded here exactly as a
/// direct session's would be. Reconnects quietly if the bridge restarts. Talkback still needs the camera itself,
/// so it opens a direct control session for the mic only while you hold the button.
public final class BridgeLiveStream: LiveSource, @unchecked Sendable {
    public let client: BridgeClient
    public let channel: UInt8
    private let builder = HEVCSampleBuilder()
    private let audio: EufyAudioPlayer?
    private let onSample: @Sendable (CMSampleBuffer) -> Void
    private let onState: @Sendable (EufyLiveStream.State) -> Void
    private let lock = NSLock()
    private var task: URLSessionWebSocketTask?
    private var stopped = false
    private var playing = false
    private var frames = 0
    private var bytes = 0
    /// Makes the direct control-only session talkback uses.
    public var talkSession: (@MainActor () -> EufyLiveStream?)?
    private var talk: EufyLiveStream?

    public init(client: BridgeClient, channel: UInt8, audio: Bool,
         onSample: @escaping @Sendable (CMSampleBuffer) -> Void,
         onState: @escaping @Sendable (EufyLiveStream.State) -> Void = { _ in }) {
        self.client = client
        self.channel = channel
        self.audio = audio ? EufyAudioPlayer() : nil
        self.onSample = onSample
        self.onState = onState
    }

    public func start() {
        onState(.connecting)
        connect()
        // No frames in 20 s: say so, instead of a black view forever.
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(20))
            guard let self, !self.lock.withLock({ self.stopped || self.frames > 0 }) else { return }
            self.onState(.failed("The bridge didn't send any video for this camera."))
        }
    }

    private func connect() {
        guard let url = client.liveURL(channel: channel, audio: audio != nil) else { return }
        let task = URLSession.shared.webSocketTask(with: url)
        task.maximumMessageSize = 16 * 1024 * 1024
        lock.withLock { self.task = task }
        task.resume()
        receive(task)
    }

    private func receive(_ task: URLSessionWebSocketTask) {
        task.receive { [weak self] result in
            guard let self, !self.lock.withLock({ self.stopped }) else { return }
            switch result {
            case .success(.data(let data)):
                self.handle(data)
                self.receive(task)
            case .success(.string):
                self.receive(task)
            case .success:
                self.receive(task)
            case .failure:
                // The bridge restarted or the network blinked: pick the stream up again at its next keyframe.
                self.builder.resyncOnNextKeyframe()
                Task { [weak self] in
                    try? await Task.sleep(for: .seconds(2))
                    guard let self, !self.lock.withLock({ self.stopped }) else { return }
                    self.connect()
                }
            }
        }
    }

    private func handle(_ data: Data) {
        lock.withLock { bytes += data.count }
        guard data.count >= 13 else { return }
        let bytes = [UInt8](data.prefix(13))
        let type = bytes[0]
        let ms = Int64(littleEndian: bytes[5...12].withUnsafeBytes { $0.loadUnaligned(as: Int64.self) })
        let payload = data.dropFirst(13)
        switch type {
        case 4:
            guard payload.count > 1 else { return }
            let annexB = Data(payload.dropFirst())
            if let sample = builder.sampleBuffer(fromAnnexB: annexB, cameraTimestampMs: UInt32(truncatingIfNeeded: ms)) {
                let first = lock.withLock { () -> Bool in frames += 1; return !playing && { playing = true; return true }() }
                if first { onState(.playing) }
                onSample(sample)
            }
        case 5:
            // EufyAudioPlayer expects the camera's 16-byte audio header in front; the bridge strips it.
            audio?.feed(audioFrameBody: Data(count: 16) + payload)
        default:
            break
        }
    }

    // MARK: LiveSource

    public func stop() {
        lock.withLock { stopped = true }
        task?.cancel(with: .normalClosure, reason: nil)
        audio?.stop()
        stopTalkback()
        onState(.stopped)
    }

    public func setMuted(_ muted: Bool) { audio?.setMuted(muted) }
    public func setAudioDelay(_ seconds: Double) { audio?.setDelay(seconds) }
    public var videoSize: (width: Int, height: Int)? { builder.dimensions.map { (Int($0.width), Int($0.height)) } }
    public var bytesReceived: Int { lock.withLock { bytes } }
    public var sourceChannel: UInt8 { channel }
    public func rotate(_ direction: PTZDirection) { Task { await client.rotate(channel: channel, direction) } }
    public func preset(_ action: PTZPresetAction, index: Int) { Task { _ = await client.preset(channel: channel, action, index: index) } }
    public func setQuality(_ quality: StreamQuality) { Task { await client.setQuality(channel: channel, quality) } }
    public func readSettings() async -> [Int: String]? { await client.rawSettings(channel: channel) }
    public func writeSetting(_ setting: CameraSetting, deviceType: Int?, value: Int) async -> Bool {
        await client.writeSetting(channel: channel, id: setting.id, value: value)
    }
    public func snapshot() async -> CGImage? { await client.snapshot(channel: channel, fresh: true, full: true) }
    public func readZones() async -> ActivityZones? { await client.zones(channel: channel) }
    public func writeZones(_ zones: ActivityZones) async -> Bool { await client.writeZones(channel: channel, zones) }

    /// Diagnostics: frames received and the decoded size.
    public var diagnostics: String {
        "frames=\(lock.withLock { frames }) size=\(videoSize.map { "\($0.width)x\($0.height)" } ?? "-") formatChanges=\(builder.formatChanges) droppedUntilKeyframe=\(builder.droppedWaitingForKeyframe)"
    }

    public func startTalkback() {
        guard talk == nil, let make = talkSession else { return }
        Task { @MainActor in
            guard let session = make() else { return }
            talk = session
            session.start()
            try? await Task.sleep(for: .seconds(4))   // keys, then the camera's stream, first
            guard talk === session else { return }
            session.startTalkback()
        }
    }

    public func stopTalkback() {
        let session = talk
        talk = nil
        Task { @MainActor in session?.stopTalkback(); session?.stop() }
    }
}
