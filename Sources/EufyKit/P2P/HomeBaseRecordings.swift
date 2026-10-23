import Foundation

/// Reads the HomeBase's own recordings over the direct P2P session — no cloud, read-only:
/// the event list (its `history_record_info` database), event snapshots, and clip downloads.
///
/// Wire (verified on a HomeBase 3, T8030), all level-2 SET_PAYLOAD (1350) with the owner's account id:
/// - events: `{cmd:1306, mChannel:255, payload:{cmd:10006, table:"history_record_info", payload:{…dates…}}}` →
///   one `CMD_DATABASE` reply (level-1 ECB) holding the START day's rows, newest first, up to `count`;
/// - snapshot: `{cmd:1308, payload:[{file}]}` → `CMD_DATABASE_IMAGE` `{file, content:<base64url JPEG>}`;
/// - clip: `{cmd:1024, mChannel:<camera>, mValue3:1024, payload:{filepath, key:<RSA modulus>}}` → the clip's
///   video/audio frames on the binary channel, faster than real time, then `CMD_DOWNLOAD_FINISH` (1304).
///
/// One request at a time: replies don't say which request they answer.
public actor HomeBaseRecordings {
    public enum RecordingsError: LocalizedError {
        case noReply(String), refused(String, Int), noVideo
        public var errorDescription: String? {
            switch self {
            case .noReply(let what): "The HomeBase didn't answer the \(what) request."
            case .refused(let what, let code): "The HomeBase refused the \(what) request (error \(code))."
            case .noVideo: "The clip had no playable video."
            }
        }
    }

    enum Command {
        static let setPayload: UInt16 = 1350
        static let database: UInt16 = 1306
        static let databaseImage: UInt16 = 1308
        static let downloadVideo: UInt16 = 1024
        static let downloadFinish: UInt16 = 1304
        static let queryByDate = 10006
    }

    private let homeBaseIP: String?
    private let context: EufyLiveStream.Level2Context
    private var session: HomeBaseSession?

    public init(homeBaseIP: String?, context: EufyLiveStream.Level2Context) {
        self.homeBaseIP = homeBaseIP
        self.context = context
    }

    public func close() {
        session?.close()
        session = nil
    }

    private func openSession() async throws -> HomeBaseSession {
        if let session { return session }
        let s = try HomeBaseSession(homeBaseIP: homeBaseIP, context: context)
        do { try await s.open() } catch { s.close(); throw error }
        session = s
        return s
    }

    /// The request in flight; each new one waits for it, since an actor alone would interleave them at awaits.
    private var tail: Task<Void, Never>?

    /// Runs one request at a time; if the station doesn't answer, reconnects once and tries again.
    private func withSession<T: Sendable>(_ body: @escaping @Sendable (HomeBaseSession) async throws -> T) async throws -> T {
        let previous = tail
        let task = Task { () async throws -> T in
            _ = await previous?.value
            do {
                return try await body(try await self.openSession())
            } catch RecordingsError.noReply {
                self.close()
                return try await body(try await self.openSession())
            }
        }
        tail = Task { _ = try? await task.value }
        return try await task.value
    }

    // MARK: Events

    /// Every event the HomeBase recorded on the given calendar day (in `calendar`'s zone), newest first.
    public func events(on day: Date, cameraSerials: [String], calendar: Calendar = .current) async throws -> [EufyEvent] {
        let start = calendar.startOfDay(for: day)
        guard let next = calendar.date(byAdding: .day, value: 1, to: start) else { return [] }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = calendar.timeZone
        f.dateFormat = "yyyyMMdd"
        let devices = cameraSerials.map { "{\"device_sn\":\"\($0)\"}" }.joined(separator: ",")
        let transaction = "\(Int(Date().timeIntervalSince1970 * 1000))"
        let query = "{\"cmd\":\(Command.queryByDate),\"payload\":{\"count\":1000,\"detection_type\":0,\"device_info\":[\(devices)]," +
            "\"end_date\":\"\(f.string(from: next))\",\"event_type\":0,\"flag\":0,\"res_unzip\":1," +
            "\"start_date\":\"\(f.string(from: start))\",\"start_time\":\"\(f.string(from: start))000000\"," +
            "\"storage_cloud\":-1,\"ai_type\":0},\"table\":\"history_record_info\",\"transaction\":\"\(transaction)\"}"

        return try await withSession { session in
            let reply = Reply<[EufyEvent]>()
            let buffer = TextBuffer()
            let token = session.addFrameHandler { _, cmd, sign, body in
                guard cmd == Command.database else { return }
                buffer.append(session.decryptControl(body, signCode: sign))
                guard let parsed = EufyEvent.parseQueryReply(buffer.text) else { return }
                if parsed.result != 0 { reply.fail(RecordingsError.refused("event list", parsed.result)) }
                else { reply.succeed(parsed.events) }
            }
            defer { session.removeFrameHandler(token) }
            session.sendSetPayload(cmd: Int(Command.database), channel: PPPPMessage.stationChannel, payloadJSON: query)
            return try await reply.wait(seconds: 15, what: "event list")
        }
    }

    /// Events from `start` to `end`, newest first, one HomeBase query per day.
    public func events(cameraSerials: [String], from start: Date, to end: Date, calendar: Calendar = .current) async throws -> [EufyEvent] {
        var out: [EufyEvent] = []
        var day = calendar.startOfDay(for: end)
        while day >= calendar.startOfDay(for: start) {
            out += try await events(on: day, cameraSerials: cameraSerials, calendar: calendar)
            guard let previous = calendar.date(byAdding: .day, value: -1, to: day) else { break }
            day = previous
        }
        return out.filter { $0.startTime >= start && $0.startTime <= end }.sorted { $0.startTime > $1.startTime }
    }

    // MARK: Snapshot

    /// The event's snapshot JPEG (`thumb_path`), straight from the HomeBase's disk.
    /// Cancelling the caller (e.g. a list row scrolled away) skips the request if it hasn't been sent yet.
    public func image(path: String) async throws -> Data {
        let escaped = path.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let cancelled = CancelFlag()
        return try await withTaskCancellationHandler {
            try await fetchImage(path: path, escaped: escaped, cancelled: cancelled)
        } onCancel: { cancelled.set() }
    }

    private func fetchImage(path: String, escaped: String, cancelled: CancelFlag) async throws -> Data {
        try await withSession { session in
            if cancelled.isSet { throw CancellationError() }
            let reply = Reply<Data>()
            let buffer = TextBuffer()
            let token = session.addFrameHandler { _, cmd, sign, body in
                guard cmd == Command.databaseImage else { return }
                buffer.append(session.decryptControl(body, signCode: sign))
                let json = buffer.text.prefix { $0 != 0 }
                guard let object = try? JSONSerialization.jsonObject(with: json) as? [String: Any] else { return }
                guard (object["file"] as? String) == path, let content = object["content"] as? String,
                      let jpeg = Data(base64URLEncoded: content) else { return }
                reply.succeed(jpeg)
            }
            defer { session.removeFrameHandler(token) }
            session.sendSetPayload(cmd: Int(Command.databaseImage), channel: PPPPMessage.stationChannel,
                                   payloadJSON: "[{\"file\":\"\(escaped)\"}]")
            return try await reply.wait(seconds: 10, what: "snapshot")
        }
    }

    // MARK: Clip

    /// Downloads one clip. `progress` gets (video frames, bytes) as they arrive.
    public func downloadClip(channel: UInt8, storagePath: String,
                             progress: @escaping @Sendable (Int, Int) -> Void = { _, _ in }) async throws -> EufyClip {
        guard let rsa = EufyRSA() else { throw RecordingsError.noVideo }
        let escaped = storagePath.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        return try await withSession { session in
            let collector = ClipCollector(decoder: Level2VideoDecoder(rsa: rsa), progress: progress)
            let token = session.addFrameHandler { kind, cmd, sign, body in
                switch cmd {
                case Command.setPayload where body.count >= 4:
                    let code = Int32(bitPattern: UInt32(body[body.startIndex]) | UInt32(body[body.startIndex + 1]) << 8 |
                                     UInt32(body[body.startIndex + 2]) << 16 | UInt32(body[body.startIndex + 3]) << 24)
                    if code < 0 { collector.fail(RecordingsError.refused("clip", Int(code))) }
                case 1300 where kind == .binary: collector.video(body, signCode: sign)
                case 1301 where kind == .binary: collector.audio(body)
                case Command.downloadFinish: collector.finish()
                default: break
                }
            }
            defer { session.removeFrameHandler(token) }
            session.sendSetPayload(cmd: Int(Command.downloadVideo), channel: channel, mValue3: Int(Command.downloadVideo),
                                   payloadJSON: "{\"filepath\":\"\(escaped)\",\"key\":\"\(rsa.modulusHex.uppercased())\"}")
            return try await collector.wait()
        }
    }
}

// MARK: - Helpers

/// A one-shot reply slot a frame handler fills and a request awaits, with a timeout.
final class Reply<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<T, Error>?
    private var continuation: CheckedContinuation<T, Error>?

    func succeed(_ value: T) { settle(.success(value)) }
    func fail(_ error: Error) { settle(.failure(error)) }

    private func settle(_ r: Result<T, Error>) {
        let c: CheckedContinuation<T, Error>? = lock.withLock {
            guard result == nil else { return nil }
            result = r
            defer { continuation = nil }
            return continuation
        }
        c?.resume(with: r)
    }

    func wait(seconds: Double, what: String) async throws -> T {
        let timer = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            self?.fail(HomeBaseRecordings.RecordingsError.noReply(what))
        }
        defer { timer.cancel() }
        return try await withCheckedThrowingContinuation { c in
            lock.withLock {
                if let result { c.resume(with: result) } else { continuation = c }
            }
        }
    }
}

final class CancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func set() { lock.withLock { value = true } }
    var isSet: Bool { lock.withLock { value } }
}

/// Accumulates a reply's decrypted text across frames.
final class TextBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    func append(_ d: Data) { lock.withLock { data.append(d) } }
    var text: Data { lock.withLock { data } }
}

/// Collects a clip transfer: decrypts video as it arrives, keeps audio, and ends on the finish frame or
/// when the station goes quiet.
final class ClipCollector: @unchecked Sendable {
    private let decoder: Level2VideoDecoder
    private let progress: @Sendable (Int, Int) -> Void
    private let lock = NSLock()
    private var videoFrames: [EufyClip.Frame] = []
    private var audioFrames: [EufyClip.Frame] = []
    private var bytes = 0
    private var lastFrameAt = Date()
    private var received = false
    private let reply = Reply<EufyClip>()
    /// A guard against a runaway transfer; a two-minute 1080p event is about 50 MB.
    static let maxBytes = 200 * 1024 * 1024

    init(decoder: Level2VideoDecoder, progress: @escaping @Sendable (Int, Int) -> Void) {
        self.decoder = decoder
        self.progress = progress
    }

    func video(_ body: Data, signCode: UInt8) {
        guard let header = VideoFrameHeader(body), let es = decoder.decode(body, signCode: signCode) else { return }
        let (count, total) = lock.withLock {
            received = true
            lastFrameAt = Date()
            bytes += body.count
            videoFrames.append(.init(timestampMs: Self.stamp(body, at: 0x0e), data: es, keyframe: header.keyframe))
            return (videoFrames.count, bytes)
        }
        progress(count, total)
        if total > Self.maxBytes { finish() }
    }

    func audio(_ body: Data) {
        guard body.count > 16 else { return }
        lock.withLock {
            received = true
            lastFrameAt = Date()
            bytes += body.count
            audioFrames.append(.init(timestampMs: Self.stamp(body, at: 8), data: Data(body.dropFirst(16)), keyframe: true))
        }
    }

    func finish() {
        let clip = lock.withLock { EufyClip(video: videoFrames, audio: audioFrames) }
        if clip.video.isEmpty { reply.fail(HomeBaseRecordings.RecordingsError.noVideo) } else { reply.succeed(clip) }
    }

    func fail(_ error: Error) { reply.fail(error) }

    /// Waits for the transfer: nothing for 20 s → no reply; 10 s of silence mid-transfer → keep what came.
    func wait() async throws -> EufyClip {
        let watchdog = Task { [weak self] in
            let started = Date()
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
                guard let self else { return }
                let (got, last) = self.lock.withLock { (self.received, self.lastFrameAt) }
                if !got, Date().timeIntervalSince(started) > 20 { self.fail(HomeBaseRecordings.RecordingsError.noReply("clip")); return }
                if got, Date().timeIntervalSince(last) > 10 { self.finish(); return }
            }
        }
        defer { watchdog.cancel() }
        return try await reply.wait(seconds: 600, what: "clip")
    }

    /// The frame header's capture time: a 48-bit little-endian millisecond clock.
    static func stamp(_ body: Data, at offset: Int) -> Int64 {
        guard body.count >= offset + 6 else { return 0 }
        let b = Array(body[body.startIndex + offset ..< body.startIndex + offset + 6])
        return b.enumerated().reduce(Int64(0)) { $0 | Int64($1.element) << (8 * Int64($1.offset)) }
    }
}

extension Data {
    /// Decodes base64url (`-`/`_`, padding optional), which the HomeBase uses for snapshot images.
    init?(base64URLEncoded text: String) {
        var s = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        s += String(repeating: "=", count: (4 - s.count % 4) % 4)
        self.init(base64Encoded: s)
    }
}
