import Foundation
#if canImport(CoreMedia)
import CoreMedia
#endif

/// Drives a live camera feed from a HomeBase: opens the direct session, starts realtime video on a
/// channel, keeps it alive, and emits decoded-ready `CMSampleBuffer`s for display. Cloud-free.
///
/// Without a `Level2Context` it does a simple level-1 start, which plays the HomeBase's active camera.
/// With one (station serial, account id, ECC key — all cached after a one-time fetch) it does the
/// level-2 media start, which selects the specific camera on `channel` and decodes its encrypted video.
public final class EufyLiveStream: @unchecked Sendable {
    enum Command {
        static let startRealtime: UInt16 = 1003
        static let stopRealtime: UInt16 = 1004
        static let gatewayInfo: UInt16 = 1100
        static let streamKeepalive: UInt16 = 1139
    }

    /// Everything the level-2 (per-camera) path needs. Build it from cached values; no cloud at play time.
    public struct Level2Context: Sendable {
        public var stationSerial: String
        public var accountID: String
        public var eccPrivateKeyHex: String
        public init(stationSerial: String, accountID: String, eccPrivateKeyHex: String) {
            self.stationSerial = stationSerial
            self.accountID = accountID
            self.eccPrivateKeyHex = eccPrivateKeyHex
        }
    }

    public struct Config: Sendable {
        public var homeBaseIP: String?
        public var p2pDID: String?
        public var channel: UInt8
        public var level2: Level2Context?
        /// Whether to play the camera's audio at all. Off for grid tiles: no decoding, nothing to unmute.
        public var audio: Bool
        /// false: a control-only session (settings) — connect and derive the keys, but never start video.
        public var video: Bool = true
        /// Live-view quality to set once the stream is up (level-2 only), or nil to leave the camera's
        /// setting alone. Needs `model` (model or serial) to pick the wire command.
        public var quality: StreamQuality?
        /// Send `quality` before the media start instead of after it (the camera may then wake at that size).
        public var qualityBeforeStart = false
        /// The media start's `streamtype` (the official app sends it too; 1 is what Eufynized has always used).
        public var streamType = 1
        public var model: String?
        public init(homeBaseIP: String?, p2pDID: String? = nil, channel: UInt8 = 0, level2: Level2Context? = nil,
                    audio: Bool = true, quality: StreamQuality? = nil, model: String? = nil) {
            self.homeBaseIP = homeBaseIP
            self.p2pDID = p2pDID
            self.channel = channel
            self.level2 = level2
            self.audio = audio
            self.quality = quality
            self.model = model
        }
    }

    public enum State: Sendable, Equatable { case connecting, playing, failed(String), stopped }

    /// The configuration this stream was made with.
    public var liveConfig: Config { config }

    private let config: Config
    #if canImport(CoreMedia)
    private let builder = HEVCSampleBuilder()
    private let audio: EufyAudioPlayer?
    private var microphone: MicrophoneCapture?
    private let onSample: @Sendable (CMSampleBuffer) -> Void
    #endif
    private let rsa = EufyRSA()
    private var level2Decoder: Level2VideoDecoder?
    private var connection: HomeBaseConnection?
    private var keepAlive: Task<Void, Never>?
    private let lock = NSLock()
    private var rawGateway: Data?
    private var level2Key: Data?
    private var level1Key: Data?
    /// The pending `readSettings()` call, tagged so its timeout can't finish a later read.
    private var settingsWaiter: (id: UUID, continuation: CheckedContinuation<[Int: String]?, Never>)?
    private var videoFrames = 0, decryptFailures = 0, keyframes = 0
    /// Each decrypted video frame as an Annex-B elementary stream (H.264 or H.265), with the camera's capture
    /// time in ms, whether it's a keyframe, and its size from the frame header ("1920x1080") — what the Home
    /// Assistant add-on hands to go2rtc. Every platform.
    public var onVideoFrame: (@Sendable (_ annexB: Data, _ captureMs: Int64, _ keyframe: Bool, _ size: String?) -> Void)?
    /// Each audio frame as ADTS AAC (16 kHz mono), the 16-byte frame header stripped, with its capture time
    /// in ms on the same clock as the video.
    public var onAudioFrame: (@Sendable (_ adts: Data, _ captureMs: Int64) -> Void)?
    /// After a hole in the stream (lost packets), the frames up to the next keyframe are corrupt: `onVideoFrame`
    /// skips them, as the Mac's decoder does. A browser's player treats one bad frame as fatal.
    private var frameOutputWaitsForKeyframe = false
    /// Holes in the stream so far (lost packets the reassembly gave up on).
    public private(set) var gaps = 0
    /// Diagnostics: every inbound frame that isn't video/audio (command id, signCode, body).
    public var onControlFrame: (@Sendable (UInt16, UInt8, Data) -> Void)?
    /// Every inbound control (non-media) frame with its channel — for reading station replies about cameras.
    public var onControlFrameDetail: (@Sendable (HomeBaseConnection.InboundFrame) -> Void)?
    /// The camera's state as its HomeBase reports it (param 1131). Asked for automatically when no video has
    /// arrived a few seconds after the start, so an unplugged or switched-off camera says so instead of
    /// staying black; also follows any later settings report (1103 reply or 1351 notify) for this camera.
    public var onAvailability: (@Sendable (CameraAvailability) -> Void)?
    private var availability: CameraAvailability?
    private var availabilityCheck: Task<Void, Never>?
    /// Restarts the camera's stream when its video stops mid-session (see `watchForStalls`).
    private var stallWatchdog: Task<Void, Never>?
    /// How many times the watchdog has had to restart the stream (diagnostics).
    public private(set) var stallRestarts = 0
    private let onState: @Sendable (State) -> Void

    #if canImport(CoreMedia)
    public init(config: Config,
                onSample: @escaping @Sendable (CMSampleBuffer) -> Void,
                onState: @escaping @Sendable (State) -> Void = { _ in }) {
        self.config = config
        self.onSample = onSample
        self.onState = onState
        audio = config.audio ? EufyAudioPlayer() : nil
        if let rsa { level2Decoder = Level2VideoDecoder(rsa: rsa) }
    }
    #else
    /// Linux: frames come out through `onVideoFrame` / `onAudioFrame` (no decoding or presentation here).
    public init(config: Config, onState: @escaping @Sendable (State) -> Void = { _ in }) {
        self.config = config
        self.onState = onState
        if let rsa { level2Decoder = Level2VideoDecoder(rsa: rsa) }
    }
    #endif

    public func start() {
        onState(.connecting)
        Task { [weak self] in
            guard let self else { return }
            do {
                let connection = try HomeBaseConnection(config: .init(
                    stationSerial: config.level2?.stationSerial ?? "live", p2pDID: config.p2pDID,
                    knownAddress: config.homeBaseIP))
                self.connection = connection
                connection.onGap { [weak self] in
                    guard let self else { return }
                    #if canImport(CoreMedia)
                    self.builder.resyncOnNextKeyframe()
                    #endif
                    self.lock.withLock { self.frameOutputWaitsForKeyframe = true; self.gaps += 1 }
                }
                connection.onFrameDetail { [weak self] frame in
                    guard let self, frame.command != 1300, frame.command != 1301 else { return }
                    if frame.channel == self.config.channel,
                       let plain = self.decryptControlFrame(frame.body, signCode: frame.signCode),
                       let params = CameraSettingsCatalog.paramReport(plain) {
                        // This camera's settings reply (CMD_CAMERA_INFO), for `readSettings()`.
                        if frame.command == 1103 { self.finishSettingsRead(params) }
                        if let state = CameraAvailability(params: params) { self.noteAvailability(state) }
                    }
                    self.onControlFrameDetail?(frame)
                }
                let debug = ProcessInfo.processInfo.environment["EUFY_DEBUG"] != nil
                connection.onFrame { [weak self] _, cmd, signCode, body in
                    guard let self else { return }
                    if cmd == Command.gatewayInfo { self.lock.withLock { if self.rawGateway == nil { self.rawGateway = body } }; return }
                    if cmd == 1301 {   // AAC audio
                        #if canImport(CoreMedia)
                        self.audio?.feed(audioFrameBody: body)
                        #endif
                        if body.count > 16, let onAudio = self.onAudioFrame { onAudio(Data(body.dropFirst(16)), ClipCollector.stamp(body, at: 8)) }
                        return
                    }
                    guard cmd == 1300 else {
                        if let cmd { self.onControlFrame?(cmd, signCode, body) }
                        return
                    }
                    self.lock.withLock { self.videoFrames += 1 }
                    // Level-1: plaintext H.265 after the 22-byte header. Level-2: decrypt first.
                    let annexB: Data
                    if let decoder = self.level2Decoder, config.level2 != nil {
                        guard let es = decoder.decode(body, signCode: signCode) else {
                            self.lock.withLock { self.decryptFailures += 1 }
                            if debug { FileHandle.standardError.write(Data("[live] decode nil signCode=\(signCode) len=\(body.count)\n".utf8)) }
                            return
                        }
                        annexB = es
                    } else {
                        guard VideoFrameHeader(body) != nil else { return }
                        annexB = Data(body.dropFirst(0x16))
                    }
                    let header = VideoFrameHeader(body)
                    if header?.keyframe == true { self.lock.withLock { self.keyframes += 1 } }
                    let isKeyframe = header?.keyframe == true
                    let skip = self.lock.withLock { () -> Bool in
                        if isKeyframe { self.frameOutputWaitsForKeyframe = false }
                        return self.frameOutputWaitsForKeyframe
                    }
                    if !skip { self.onVideoFrame?(annexB, ClipCollector.stamp(body, at: 0x0e), isKeyframe, header?.resolution) }
                    #if canImport(CoreMedia)
                    if let sample = self.builder.sampleBuffer(fromAnnexB: annexB, cameraTimestampMs: header?.timestamp) { self.onSample(sample) }
                    else if debug { FileHandle.standardError.write(Data("[live] builder nil, es=\(annexB.count)\n".utf8)) }
                    #endif
                }
                _ = try await connection.connect()
                try await startVideo(on: connection)
                self.onState(.playing)
                if self.config.video { self.watchForStalls() }
                // No video yet? Ask the HomeBase why (camera info, 1103) — twice, in case a reply is lost.
                self.availabilityCheck = Task { [weak self] in
                    for delay in [5, 7] {
                        try? await Task.sleep(for: .seconds(delay))
                        guard let self, !Task.isCancelled, self.onAvailability != nil,
                              self.lock.withLock({ self.videoFrames == 0 }) else { return }
                        self.requestCameraInfo(level2: self.config.level2 != nil)
                    }
                }
                // Keepalive holds the stream WITHOUT re-negotiating — re-starting would re-key and stutter.
                self.keepAlive = Task { [weak self] in
                    while !Task.isCancelled {
                        try? await Task.sleep(for: .seconds(3))
                        guard let self, !Task.isCancelled, let connection = self.connection else { return }
                        if !self.config.video {
                            continue   // control-only: the session's own heartbeat keeps it open
                        } else if self.config.level2 != nil {
                            connection.sendCommand(Command.streamKeepalive, channel: self.config.channel)
                        } else {
                            connection.sendCommand(Command.startRealtime, channel: self.config.channel)
                        }
                    }
                }
            } catch {
                self.onState(.failed(error.localizedDescription))
            }
        }
    }

    /// Issues the realtime start — level-2 (camera-selecting) when a context is set, else level-1.
    private func startVideo(on connection: HomeBaseConnection?) async throws {
        guard let connection else { return }
        guard let ctx = config.level2, let did = connection.connectedDID,
              let level1Key = PPPPMessage.commandKey(stationSerial: ctx.stationSerial, p2pDID: did),
              let rsa else {
            connection.sendCommand(Command.startRealtime, channel: config.channel)   // level-1
            return
        }
        // Gateway-info → level-2 key (once).
        connection.sendCommand(Command.gatewayInfo)
        for _ in 0..<12 where lock.withLock({ rawGateway }) == nil { try await Task.sleep(for: .milliseconds(300)) }
        guard let raw = lock.withLock({ rawGateway }) else {
            connection.sendCommand(Command.startRealtime, channel: config.channel)
            return
        }
        lock.withLock { self.level1Key = level1Key }
        let decrypted = PPPPMessage.decryptGatewayInfo(raw, level1Key: level1Key)
        guard let envelope = PPPPMessage.gatewayInfoEnvelope(decrypted: decrypted),
              let level2Key = EufyMediaDecryptor.deriveLevel2Key(gatewayEnvelope: envelope, eccPrivateKeyHex: ctx.eccPrivateKeyHex) else {
            connection.sendCommand(Command.startRealtime, channel: config.channel)
            return
        }
        lock.withLock { self.level2Key = level2Key }
        guard config.video else { return }
        if config.qualityBeforeStart, let quality = config.quality {
            setQuality(quality)
            try await Task.sleep(for: .milliseconds(300))
        }
        connection.startLiveLevel2(channel: config.channel, level2Key: level2Key,
                                   rsaModulusHex: rsa.modulusHex, accountID: ctx.accountID, streamType: config.streamType)
        if !config.qualityBeforeStart, let quality = config.quality { setQuality(quality) }
    }

    /// The live-view quality levels this camera offers, or nil if its model has no known setting.
    public var qualityProfile: StreamQualityProfile? { config.model.flatMap(StreamQualityProfile.forModel) }

    /// Sets the camera's live-view (streaming) quality. This is the camera's persistent Streaming Quality
    /// setting, shared with the Eufy app; the camera re-encodes at the new size within a few seconds.
    public func setQuality(_ quality: StreamQuality) {
        guard let profile = qualityProfile, let value = profile.value(for: quality) else { return }
        sendQuality(wire: profile.wire, value: value)
    }

    /// Sends a raw streaming-quality value on the given wire (for probing).
    public func sendQuality(wire: StreamQualityProfile.Wire, value: Int) {
        guard let connection, let ctx = config.level2, let key = lock.withLock({ level2Key }) else { return }
        connection.setStreamQuality(wire: wire, value: value, channel: config.channel, accountID: ctx.accountID, level2Key: key)
    }

    /// The decoded video size right now, e.g. 1920x1080, once a keyframe has arrived.
    #if canImport(CoreMedia)
    public var videoSize: (width: Int, height: Int)? { builder.dimensions.map { (Int($0.width), Int($0.height)) } }
    #else
    public var videoSize: (width: Int, height: Int)? { nil }
    #endif

    /// A camera can stop sending video on a live session — an S3 Pro sometimes does right after its streaming
    /// quality changes — and only a new stream start brings it back (reopening the camera did that by hand).
    /// Once video has flowed, 4 s of silence re-sends the level-2 media start on the same session, backing off
    /// if the camera stays quiet (an offline camera never sends video, so it's never restarted).
    private func watchForStalls() {
        stallWatchdog?.cancel()
        stallWatchdog = Task { [weak self] in
            var lastCount = 0, quietSince = Date(), backoff: TimeInterval = 4
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self else { return }
                let count = self.lock.withLock { self.videoFrames }
                if count != lastCount { lastCount = count; quietSince = Date(); backoff = 4; continue }
                guard count > 0, Date().timeIntervalSince(quietSince) >= backoff else { continue }
                self.restartMedia()
                self.stallRestarts += 1
                quietSince = Date()
                backoff = min(backoff * 2, 30)
            }
        }
    }

    /// Restores a packed param (1298 detection types, 6027 notification types) to an exact raw value, e.g.
    /// one recorded before a test. Only those two params; returns false otherwise.
    @discardableResult
    public func restorePackedRaw(key: Int, value: Int) async -> Bool {
        guard [1298, 6027].contains(key), let ctx = config.level2, let connection, let k = lock.withLock({ level2Key }) else { return false }
        let body = key == 1298
            ? "{\"account_id\":\"\(ctx.accountID)\",\"cmd\":1298,\"mChannel\":0,\"mValue3\":0,\"payload\":{\"ai_detect_type\":\(value),\"channel\":\(config.channel)}}"
            : "{\"account_id\":\"\(ctx.accountID)\",\"cmd\":6027,\"mChannel\":\(config.channel),\"mValue3\":0,\"payload\":{\"onoff\":\(value)}}"
        for _ in 0..<5 {
            connection.sendSetPayload(body, channel: config.channel, level2Key: k)
            try? await Task.sleep(for: .milliseconds(200))
        }
        return true
    }

    /// Diagnostics: tells the camera to stop streaming while the session stays up — the same symptom as a
    /// camera going quiet on its own — so the stall watchdog's recovery can be tested on hardware.
    public func stopCameraStreamForTesting() {
        stopCameraStream()
    }

    /// Tells the camera to stop streaming, in the form its session understands.
    private func stopCameraStream() {
        if let connection, let ctx = config.level2, let key = lock.withLock({ level2Key }) {
            connection.stopLiveLevel2(channel: config.channel, level2Key: key, accountID: ctx.accountID)
        } else {
            connection?.sendCommand(Command.stopRealtime, channel: config.channel)
        }
    }

    /// Re-requests the camera's stream on the existing session.
    private func restartMedia() {
        guard let connection, let ctx = config.level2, let rsa, let key = lock.withLock({ level2Key }) else {
            connection?.sendCommand(Command.startRealtime, channel: config.channel)
            return
        }
        connection.startLiveLevel2(channel: config.channel, level2Key: key, rsaModulusHex: rsa.modulusHex, accountID: ctx.accountID,
                                   streamType: config.streamType)
    }

    public func stop() {
        stallWatchdog?.cancel()
        stallWatchdog = nil
        keepAlive?.cancel()
        keepAlive = nil
        availabilityCheck?.cancel()
        availabilityCheck = nil
        stopTalkback()
        #if canImport(CoreMedia)
        audio?.stop()
        #endif
        if config.video { stopCameraStream() }   // so the camera really stops, not just this end
        connection?.close()
        connection = nil
        onState(.stopped)
    }

    /// Turn the camera's audio on or off (starts muted).
    public func setMuted(_ muted: Bool) {
        #if canImport(CoreMedia)
        audio?.setMuted(muted)
        #endif
    }

    /// Playback gain for the camera's sound (1 = as recorded; more for a quiet camera).
    public func setVolume(_ gain: Float) {
        #if canImport(CoreMedia)
        audio?.gain = gain
        #endif
    }

    /// Microphone gain for talkback (1 = as captured). Applies to the current and later talkback sessions.
    public func setMicrophoneGain(_ gain: Float) {
        lock.withLock { microphoneGain = gain }
        #if canImport(CoreMedia)
        microphone?.gain = gain
        #endif
    }
    private var microphoneGain: Float = 1

    /// Decrypts a control frame's body with this session's keys: signCode 1 is level-1 AES-ECB, 2 and 8 are
    /// level-2 AES-GCM, 0 is plaintext. nil when the needed key isn't known yet or the frame doesn't open.
    public func decryptControlFrame(_ body: Data, signCode: UInt8) -> Data? {
        let (l1, l2) = lock.withLock { (level1Key, level2Key) }
        switch signCode {
        case 0: return body
        case 1:
            guard let l1, !body.isEmpty, body.count % 16 == 0 else { return nil }
            return PPPPMessage.decryptGatewayInfo(body, level1Key: l1)
        case 2, 8:
            guard let l2 else { return nil }
            return PPPPMessage.decryptLevel2(body, key: l2, signCode: signCode)
        default: return nil
        }
    }

    /// Asks the HomeBase for this camera's settings (CMD_CAMERA_INFO 1103). The reply arrives as a control
    /// frame `{"params":[{"param_type":…,"param_value":…},…]}`.
    public func requestCameraInfo(level2: Bool = false) {
        if level2, let connection, let key = lock.withLock({ level2Key }) {
            // Same frame shape eufy-sdk uses for 1103: level-2, body [u32 channel][u32 0], on the camera's channel.
            let ch = config.channel
            connection.sendLevel2Command(1103, channel: ch, plaintext: Data([ch, 0, 0, 0, 0, 0, 0, 0]), level2Key: key)
        } else {
            connection?.sendCommand(1103, channel: config.channel)
        }
    }

    /// Reads this camera's current settings from the HomeBase (no cloud): `param_type → param_value`.
    /// nil if the HomeBase doesn't answer in time or the session isn't up yet.
    public func readSettings(timeout: Duration = .seconds(5)) async -> [Int: String]? {
        let id = UUID()
        return await withCheckedContinuation { (continuation: CheckedContinuation<[Int: String]?, Never>) in
            let previous = lock.withLock { () -> CheckedContinuation<[Int: String]?, Never>? in
                defer { settingsWaiter = (id, continuation) }
                return settingsWaiter?.continuation
            }
            previous?.resume(returning: nil)
            requestCameraInfo(level2: true)
            Task { [weak self] in
                try? await Task.sleep(for: timeout)
                self?.finishSettingsRead(nil, onlyFor: id)
            }
        }
    }

    /// Completes the pending settings read. `onlyFor` limits it to one read (its timeout).
    /// Passes the camera's state on when it changes.
    private func noteAvailability(_ state: CameraAvailability) {
        let changed = lock.withLock { () -> Bool in
            defer { availability = state }
            return availability != state
        }
        if changed { onAvailability?(state) }
    }

    private func finishSettingsRead(_ params: [Int: String]?, onlyFor id: UUID? = nil) {
        let waiter = lock.withLock { () -> CheckedContinuation<[Int: String]?, Never>? in
            guard let w = settingsWaiter, id == nil || w.id == id else { return nil }
            settingsWaiter = nil
            return w.continuation
        }
        waiter?.resume(returning: params)
    }

    /// Writes a setting with its recipe (the frames eufy-security-client sends for this camera type), each
    /// repeated as the apps do since the HomeBase→camera link drops some. Returns false if there's no recipe
    /// for the value, a frame would invoke a forbidden command, or the session isn't ready.
    @discardableResult
    public func writeSetting(_ setting: CameraSetting, deviceType: Int?, value: Int) async -> Bool {
        guard let ctx = config.level2, let connection, let key = lock.withLock({ level2Key }) else { return false }
        let frames: [CameraSettingWriteFrame]
        if CameraSettingsCatalog.isPacked(setting) {
            // Flip just this setting's bit in the camera's current value (read fresh, so others aren't undone).
            guard let params = await readSettings(), let raw = params[setting.key].flatMap({ Int($0) }),
                  let frame = CameraSettingsCatalog.packedWriteFrame(for: setting, on: value != 0, currentRaw: raw,
                                                                     channel: config.channel, accountID: ctx.accountID)
            else { return false }
            frames = [frame]
        } else {
            guard let built = CameraSettingsCatalog.writeFrames(for: setting, deviceType: deviceType, value: value,
                                                                channel: config.channel, accountID: ctx.accountID)
            else { return false }
            frames = built
        }
        for frame in frames {
            for _ in 0..<5 {
                switch frame.form {
                case .direct:
                    guard let v = Int(frame.body),
                          let body = CameraSettingsCatalog.directBinaryBody(channel: config.channel, value: v, accountID: ctx.accountID)
                    else { return false }
                    connection.sendLevel2Command(UInt16(frame.command), channel: config.channel, plaintext: body, level2Key: key)
                case .stationScalar:
                    guard let v = Int(frame.body),
                          let body = CameraSettingsCatalog.directBinaryBody(channel: nil, value: v, accountID: ctx.accountID)
                    else { return false }
                    connection.sendLevel2Command(UInt16(frame.command), channel: config.channel, plaintext: body, level2Key: key)
                case .setPayload:
                    connection.sendSetPayload(frame.body, channel: config.channel, level2Key: key)
                case .control:
                    connection.sendLevel2Command(UInt16(frame.command), channel: config.channel,
                                                 plaintext: Data(frame.body.utf8), level2Key: key)
                }
                try? await Task.sleep(for: .milliseconds(200))
            }
        }
        return true
    }

    /// Delays audio to match the player's video buffer, keeping the two in sync.
    public func setAudioDelay(_ seconds: Double) {
        #if canImport(CoreMedia)
        audio?.setDelay(seconds)
        #endif
    }

    #if canImport(CoreMedia)
    public var audioDiagnostics: String { audio?.diagnostics ?? "off" }
    #else
    public var audioDiagnostics: String { "passthrough" }
    #endif

    /// Bytes received from the HomeBase so far (for a network-rate display).
    public var bytesReceived: Int { connection?.transportStats().bytes ?? 0 }

    /// Transport + video counters, for diagnosing stutter.
    public var videoDiagnostics: String {
        let (frames, failures) = lock.withLock { (videoFrames, decryptFailures) }
        let transport = connection.map { "\($0.transportStats())" } ?? "no-connection"
        #if canImport(CoreMedia)
        let size = builder.dimensions.map { "\($0.width)x\($0.height)" } ?? "-"
        let builderStats = "keyframes=\(builder.keyframes) size=\(size) formatChanges=\(builder.formatChanges) droppedUntilKeyframe=\(builder.droppedWaitingForKeyframe)"
        #else
        let builderStats = "keyframes=\(lock.withLock { keyframes })"
        #endif
        let gateway = lock.withLock { rawGateway != nil }
        let rsa = level2Decoder.map { "rsa=\($0.rsaUnwraps)/hits=\($0.rsaCacheHits) " } ?? ""
        return "\(rsa)restarts=\(stallRestarts) gateway=\(gateway) level2=\(lock.withLock { level2Key != nil }) videoFrames=\(frames) decryptFail=\(failures) " +
            "\(builderStats) \(transport)"
    }

    /// Start two-way audio: tells the camera to listen, then streams the mic to it as AAC. On Linux there's no
    /// local mic: the caller feeds ADTS AAC (e.g. from a browser) through `sendTalkbackAudio`.
    public func startTalkback() {
        guard let connection, let key = lock.withLock({ level2Key }) else { return }
        connection.startTalkback(channel: config.channel, level2Key: key)
        #if canImport(CoreMedia)
        let mic = MicrophoneCapture()
        mic.gain = lock.withLock { microphoneGain }
        microphone = mic
        mic.start { [weak self] adtsFrame in
            guard let self else { return }
            self.connection?.sendAudioFrame(adtsFrame, channel: self.config.channel)
        }
        #endif
    }

    /// One ADTS AAC frame (16 kHz mono) of talkback audio, sent to the camera while talkback is on.
    public func sendTalkbackAudio(_ adtsFrame: Data) {
        connection?.sendAudioFrame(adtsFrame, channel: config.channel)
    }

    public func stopTalkback() {
        #if canImport(CoreMedia)
        microphone?.stop()
        microphone = nil
        #endif
        if let connection, let key = lock.withLock({ level2Key }) {
            connection.stopTalkback(channel: config.channel, level2Key: key)
        }
    }

    /// Pan or tilt a PTZ camera one step in the given direction.
    /// Verified moving on hardware: SoloCam S340 (T8170) and Indoor Cam E30 (T8417), both behind a HomeBase.
    /// Go to, save or delete one of the camera's preset positions (0–3).
    public func preset(_ action: PTZPresetAction, index: Int) {
        sendControlJSON(PPPPMessage.ptzPresetJSON(action, index: index))
    }

    /// Sends a raw 1700 control payload (`{"commandType":…,"data":…}`), as the eufy app does for zones and more.
    public func sendControlJSON(_ json: String) {
        guard let connection else { return }
        if let key = lock.withLock({ level2Key }) {
            connection.sendLevel2Command(PPPPMessage.controlPayloadCommand, channel: config.channel,
                                         plaintext: Data(json.utf8), level2Key: key)
        } else {
            connection.sendStringCommand(PPPPMessage.controlPayloadCommand, value: json, channel: config.channel)
        }
    }

    public func rotate(_ direction: PTZDirection) {
        guard let connection else { return }
        let json = PPPPMessage.ptzRotateJSON(direction)
        if let key = lock.withLock({ level2Key }) {
            connection.sendLevel2Command(PPPPMessage.controlPayloadCommand, channel: config.channel,
                                         plaintext: Data(json.utf8), level2Key: key)
        } else {
            connection.sendStringCommand(PPPPMessage.controlPayloadCommand, value: json, channel: config.channel)
        }
    }
}
