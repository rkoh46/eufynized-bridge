import Foundation
import EufyKit

/// One frame from the camera, before packaging.
enum LiveFrame {
    case video(Data, captureMs: Int64, keyframe: Bool, size: String?)
    case audio(Data, captureMs: Int64)

    var isKeyframe: Bool { if case .video(_, _, true, _) = self { return true }; return false }
}

/// How a viewer wants the stream: MPEG-TS (go2rtc, snapshots) or fragmented MP4 for the page's own player.
enum LiveFormat {
    case ts
    case fmp4(audio: Bool)
    /// The camera's own frames, undecoded, for the Mac app at home: `[type u8][length u32 BE][captureMs i64 LE]…`
    /// with type 4 = `[keyframe u8][H.265 Annex B]` and type 5 = `[ADTS AAC]`.
    case raw(audio: Bool)
}

/// A viewer: packages frames in its format and queues the bytes for its connection. It joins at a keyframe;
/// a viewer that falls too far behind starts again at the next keyframe rather than buffering without end.
final class StreamSubscriber {
    let id = UUID()
    let format: LiveFormat
    private let condition = NSCondition()
    private var queue: [Data] = []
    private var queued = 0
    private var waitingForKeyframe = true
    private var tsMuxer = MPEGTSMuxer()
    private var mp4Muxer: FMP4Muxer?
    private(set) var closed = false
    static let maxBacklog = 8 * 1024 * 1024

    init(format: LiveFormat) {
        self.format = format
        if case .fmp4(let audio) = format { mp4Muxer = FMP4Muxer(audio: audio) }
    }

    /// For text-only streams (server-sent events): queue bytes as they are.
    func pushRaw(_ chunk: Data) {
        condition.lock(); defer { condition.unlock() }
        guard !closed else { return }
        queue.append(chunk); queued += chunk.count
        condition.signal()
    }

    func push(_ frame: LiveFrame) {
        condition.lock(); defer { condition.unlock() }
        guard !closed else { return }
        if waitingForKeyframe && !frame.isKeyframe { return }
        if waitingForKeyframe { waitingForKeyframe = false }
        if queued > Self.maxBacklog {
            // Too far behind: drop what's queued and restart cleanly (a new init segment) at the next keyframe.
            queue.removeAll(); queued = 0
            tsMuxer = MPEGTSMuxer()
            if case .fmp4(let audio) = format { mp4Muxer = FMP4Muxer(audio: audio) }
            if !frame.isKeyframe { waitingForKeyframe = true; return }
        }
        for chunk in encode(frame) where !chunk.isEmpty {
            queue.append(chunk); queued += chunk.count
        }
        condition.signal()
    }

    private func encode(_ frame: LiveFrame) -> [Data] {
        switch (format, frame, mp4Muxer) {
        case let (.raw(audio), .video(data, ms, key, _), _): return [Self.rawFrame(4, captureMs: ms, Data([key ? 1 : 0]) + data)]
        case let (.raw(audio), .audio(data, ms), _): return audio ? [Self.rawFrame(5, captureMs: ms, data)] : []
        case let (_, .video(data, ms, key, _), nil): return [tsMuxer.video(data, captureMs: ms, keyframe: key)]
        case let (_, .audio(data, ms), nil): return [tsMuxer.audio(data, captureMs: ms)]
        case let (_, .video(data, ms, key, size), muxer?): return muxer.video(data, captureMs: ms, keyframe: key, size: size).map(Self.frame)
        case let (_, .audio(data, ms), muxer?): return muxer.audio(data, captureMs: ms).map(Self.frame)
        }
    }

    static func rawFrame(_ type: UInt8, captureMs: Int64, _ payload: Data) -> Data {
        var out = Data([type, 0, 0, 0, 0])
        let n = UInt32(payload.count + 8)
        out[1] = UInt8(n >> 24); out[2] = UInt8(n >> 16 & 0xFF); out[3] = UInt8(n >> 8 & 0xFF); out[4] = UInt8(n & 0xFF)
        withUnsafeBytes(of: captureMs.littleEndian) { out.append(contentsOf: $0) }
        out.append(payload)
        return out
    }

    /// The page player's framing: `[type u8][length u32 BE][payload]` — 1 MIME type, 2 init segment, 3 fragment.
    static func frame(_ output: FMP4Muxer.Output) -> Data {
        let (type, payload): (UInt8, Data) = switch output {
        case .mimeType(let text): (1, Data(text.utf8))
        case .initSegment(let data): (2, data)
        case .fragment(let data): (3, data)
        }
        let n = UInt32(payload.count)
        return Data([type, UInt8(n >> 24), UInt8(n >> 16 & 0xFF), UInt8(n >> 8 & 0xFF), UInt8(n & 0xFF)]) + payload
    }

    /// The next chunk; nil if none came within `timeout` or the subscriber was closed.
    func next(timeout: TimeInterval) -> Data? {
        condition.lock(); defer { condition.unlock() }
        let deadline = Date().addingTimeInterval(timeout)
        while queue.isEmpty && !closed {
            if !condition.wait(until: deadline) { return nil }
        }
        guard !queue.isEmpty else { return nil }
        let chunk = queue.removeFirst()
        queued -= chunk.count
        return chunk
    }

    func close() {
        condition.lock(); closed = true; condition.broadcast(); condition.unlock()
    }
}

/// One camera's live stream from the HomeBase, shared by everyone watching it.
final class LiveFeed {
    let channel: UInt8
    let stream: EufyLiveStream
    private let lock = NSLock()
    private var subscribers: [UUID: StreamSubscriber] = [:]
    /// Every frame since the last keyframe, so a new viewer starts right away instead of waiting for one.
    private var gop: [LiveFrame] = []
    private var gopBytes = 0
    var stopWork: DispatchWorkItem?
    private(set) var startedAt = Date()
    private(set) var lastVideoAt: Date?
    private(set) var codec: MPEGTSMuxer.VideoCodec?
    var onAvailability: ((CameraAvailability) -> Void)?
    private var size: String?

    init(channel: UInt8, config: EufyLiveStream.Config) {
        self.channel = channel
        #if canImport(CoreMedia)
        stream = EufyLiveStream(config: config, onSample: { _ in })
        #else
        stream = EufyLiveStream(config: config)
        #endif
        stream.onVideoFrame = { [weak self] annexB, ms, keyframe, size in
            self?.deliver(.video(annexB, captureMs: ms, keyframe: keyframe, size: size))
        }
        stream.onAudioFrame = { [weak self] adts, ms in self?.deliver(.audio(adts, captureMs: ms)) }
        stream.onAvailability = { [weak self] state in self?.onAvailability?(state) }
    }

    func start() { startedAt = Date(); stream.start() }
    func stop() {
        lock.withLock { subscribers.values.forEach { $0.close() }; subscribers.removeAll() }
        stream.stop()
    }

    var viewerCount: Int { lock.withLock { subscribers.count } }

    /// Adds a viewer. It starts with the frames since the last keyframe (so it shows a picture at once) unless
    /// `freshOnly` (snapshots for alerts), or the buffered frames are stale: a stream that stopped sending must
    /// never hand out a picture from minutes or hours ago.
    func add(_ subscriber: StreamSubscriber, freshOnly: Bool = false) {
        lock.withLock {
            subscribers[subscriber.id] = subscriber
            let fresh = lastVideoAt.map { Date().timeIntervalSince($0) < 5 } ?? false
            if !freshOnly && fresh { for frame in gop { subscriber.push(frame) } }
        }
    }

    /// Video stopped while the camera session is still up (seen overnight on a battery camera): seconds since the
    /// last frame, counted from the start if none ever came.
    var secondsWithoutVideo: TimeInterval { Date().timeIntervalSince(lock.withLock { lastVideoAt } ?? startedAt) }

    /// The viewers, for moving them to a fresh feed.
    func takeSubscribers() -> [StreamSubscriber] {
        lock.withLock { defer { subscribers.removeAll() }; return Array(subscribers.values) }
    }

    /// Removes a viewer; returns how many remain.
    func remove(_ subscriber: StreamSubscriber) -> Int {
        lock.withLock {
            subscribers[subscriber.id] = nil
            return subscribers.count
        }
    }

    private func deliver(_ frame: LiveFrame) {
        lock.withLock {
            if case let .video(data, _, keyframe, newSize) = frame {
                if codec == nil { codec = MPEGTSMuxer.detectCodec(data) }
                lastVideoAt = Date()
                if keyframe {
                    // Cameras change resolution as they go (Auto quality ramps up, and steps down when the network is
                    // busy). The page's player follows each change through a new init segment.
                    if let newSize, let size, size != newSize { log("live ch\(channel): \(size) → \(newSize)") }
                    if let newSize { size = newSize }
                    gop = []; gopBytes = 0
                }
                guard keyframe || !gop.isEmpty else { return }   // nothing before the first keyframe
                if gopBytes < 12 * 1024 * 1024 { gop.append(frame); gopBytes += data.count }
            } else if case let .audio(data, _) = frame, !gop.isEmpty, gopBytes < 12 * 1024 * 1024 {
                gop.append(frame); gopBytes += data.count
            }
            for s in subscribers.values { s.push(frame) }
        }
    }
}

/// Live streams by camera: the first viewer starts a camera's stream, and it stops (telling the camera to
/// stop sending, so battery cameras sleep again) a few seconds after the last viewer leaves. Nobody
/// watching means nothing streams.
final class LiveHub {
    private let bridge: Bridge
    private let lock = NSLock()
    private var feeds: [UInt8: LiveFeed] = [:]
    /// How long a stream outlives its last viewer: covers a page reload or switching views.
    let linger: TimeInterval = 8

    init(bridge: Bridge) { self.bridge = bridge }

    /// A stream with no video for this long is stuck: its camera session gets replaced.
    static let stuckAfter: TimeInterval = 45

    func subscribe(_ channel: UInt8, format: LiveFormat = .ts, freshOnly: Bool = false) -> (LiveFeed, StreamSubscriber) {
        let subscriber = StreamSubscriber(format: format)
        var stuck: LiveFeed?
        let feed: LiveFeed = lock.withLock {
            if let existing = feeds[channel] {
                existing.stopWork?.cancel(); existing.stopWork = nil
                guard existing.secondsWithoutVideo > Self.stuckAfter else { return existing }
                // No video for a while although the session is up: start over with a new camera session.
                stuck = existing
                feeds[channel] = nil
            }
            var config = bridge.streamConfig(channel: channel, video: true)
            config.quality = bridge.prefs.quality(channel)
            let feed = LiveFeed(channel: channel, config: config)
            feed.onAvailability = { [weak bridge] state in bridge?.noteAvailability(channel, state) }
            feeds[channel] = feed
            log("live ch\(channel): starting" + (stuck == nil ? "" : " again (no video for \(Int(stuck!.secondsWithoutVideo)) s)"))
            feed.start()
            return feed
        }
        if let stuck {
            // Move the stuck feed's viewers over, then let the old camera session go.
            for viewer in stuck.takeSubscribers() { feed.add(viewer) }
            DispatchQueue.global().async { stuck.stop() }
        }
        feed.add(subscriber, freshOnly: freshOnly)
        return (feed, subscriber)
    }

    /// Restarts streams that have viewers but no video (checked periodically, so a viewer that just keeps
    /// waiting, like Home Assistant's stream, doesn't hold a stuck session forever).
    func restartStuckFeeds() {
        let stuck = lock.withLock { feeds.filter { $0.value.viewerCount > 0 && $0.value.secondsWithoutVideo > Self.stuckAfter }.map(\.key) }
        for channel in stuck {
            let (feed, probe) = subscribe(channel)   // replaces the stuck feed
            unsubscribe(feed, probe)
        }
    }

    func unsubscribe(_ feed: LiveFeed, _ subscriber: StreamSubscriber) {
        subscriber.close()
        guard feed.remove(subscriber) == 0 else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let stop: Bool = self.lock.withLock {
                guard feed.viewerCount == 0, self.feeds[feed.channel] === feed else { return false }
                self.feeds[feed.channel] = nil
                return true
            }
            if stop { log("live ch\(feed.channel): no viewers, stopping — \(feed.stream.videoDiagnostics)"); feed.stop() }
        }
        lock.withLock { feed.stopWork?.cancel(); feed.stopWork = work }
        DispatchQueue.global().asyncAfter(deadline: .now() + linger, execute: work)
    }

    /// The running stream for a camera, if someone is watching it (PTZ and quality changes go through it).
    func feed(_ channel: UInt8) -> LiveFeed? { lock.withLock { feeds[channel] } }

    func viewers(_ channel: UInt8) -> Int { feed(channel)?.viewerCount ?? 0 }

    /// The first keyframe (as a self-contained TS chunk) from a camera, opening its stream briefly if needed.
    func keyframe(_ channel: UInt8, timeout: TimeInterval = 20) -> (Data, MPEGTSMuxer.VideoCodec?)? {
        let (feed, subscriber) = subscribe(channel, freshOnly: true)
        defer { unsubscribe(feed, subscriber) }
        let chunk = subscriber.next(timeout: timeout)
        return chunk.map { ($0, feed.codec) }
    }

    /// The last keyframe seen within `within` seconds of the first (cameras start small and step up to their full
    /// resolution), as a self-contained TS chunk.
    func sharpestKeyframe(_ channel: UInt8, within: TimeInterval, timeout: TimeInterval = 20) -> Data? {
        let (feed, subscriber) = subscribe(channel, freshOnly: true)
        defer { unsubscribe(feed, subscriber) }
        guard var best = subscriber.next(timeout: timeout) else { return nil }
        let deadline = Date().addingTimeInterval(within)
        while Date() < deadline, let chunk = subscriber.next(timeout: deadline.timeIntervalSinceNow) {
            // A keyframe chunk starts with the PAT (PID 0, payload start): 47 40 00.
            if chunk.count > 3, chunk[chunk.startIndex + 1] == 0x40, chunk[chunk.startIndex + 2] == 0x00 { best = chunk }
        }
        return best
    }

    func stopAll() {
        let all = lock.withLock { () -> [LiveFeed] in defer { feeds.removeAll() }; return Array(feeds.values) }
        all.forEach { $0.stop() }
    }
}
