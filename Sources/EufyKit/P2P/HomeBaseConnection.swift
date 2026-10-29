import Foundation

/// Opens and holds a P2P session with a HomeBase on the local network.
///
/// The connect sequence (ported from eufy-sdk, Apache-2.0):
///   1. Send LOCAL_LOOKUP (broadcast, and directly to the known LAN address), repeated each second.
///   2. The HomeBase answers; we reply with CHECK_CAM carrying its P2P id, to the answering address and a
///      few neighbouring ports (so NAT port remapping doesn't lose us).
///   3. The HomeBase answers CAM_ID — the session is open. We note the address, send a PING, and from then
///      on send a PING every 5 seconds and answer the HomeBase's PINGs, which keeps the path alive.
///
/// This step proves a working, cloud-free session. Requesting a camera's video builds on it next.
public final class HomeBaseConnection: @unchecked Sendable {
    public struct Config: Sendable {
        public var stationSerial: String
        /// The station's P2P id. Pass nil to learn it from the HomeBase's own lookup reply (fully
        /// cloud-free); pass a known value to use it directly.
        public var p2pDID: String?
        public var knownAddress: String?
        public var connectTimeout: TimeInterval
        /// The HomeBase lookup port. Overridable so tests can point at a loopback stand-in.
        public var lookupPort: UInt16

        public init(stationSerial: String, p2pDID: String?, knownAddress: String?, connectTimeout: TimeInterval = 15,
                    lookupPort: UInt16 = PPPPMessage.lookupPort) {
            self.stationSerial = stationSerial
            self.p2pDID = p2pDID
            self.knownAddress = knownAddress
            self.connectTimeout = connectTimeout
            self.lookupPort = lookupPort
        }
    }

    public struct Peer: Sendable, Equatable {
        public var host: String
        public var port: UInt16
        public var elapsed: TimeInterval
    }

    public enum ConnectionError: LocalizedError {
        case timedOut(sawHomeBase: Bool)
        case invalidP2PDID

        public var errorDescription: String? {
            switch self {
            case .timedOut(true): "Found the HomeBase but it didn't complete the connection in time."
            case .timedOut(false): "No HomeBase answered. Check it's on the same network as this device."
            case .invalidP2PDID: "The HomeBase's P2P id isn't in the expected form."
            }
        }
    }

    private let config: Config
    private let socket: UDPSocket
    private let lock = NSLock()
    private let debug = ProcessInfo.processInfo.environment["EUFY_P2P_DEBUG"] != nil

    /// CHECK_CAM payload for the station's DID. Set from config, or learned from the HomeBase's reply.
    private var checkCamPayload: Data?
    /// The DID actually used (from config or learned locally).
    private var resolvedDID: String?

    /// Outgoing command sequence number.
    private var seqNumber: UInt16 = 0
    /// Separate counter for level-2 GCM sub-sequences (starts at 0, base 0x01020300).
    private var level2Seq: UInt32 = 0
    /// Counts of inbound complete DATA frames seen, by channel kind — a quick signal that video is flowing.
    private var framesByKind: [UInt8: Int] = [:]
    /// Per-channel reorder buffer + ordered byte stream for frame reassembly.
    private var streams: [UInt8: KindStream] = [:]
    /// Complete frames are handed off here, so decrypting/decoding never delays the next packet's ACK —
    /// a late ACK makes the HomeBase pause and resend, which stalls the stream.
    private let mediaQueue = DispatchQueue(label: "Eufynized.HomeBaseConnection.media", qos: .userInteractive)
    /// Called for each complete inbound DATA frame: (kind, commandType?, signCode, full payload).
    private var frameHandler: (@Sendable (PPPPMessage.DataKind, UInt16?, UInt8, Data) -> Void)?
    /// Like `frameHandler`, plus the channel the frame is about (which camera a station reply concerns).
    private var detailHandler: (@Sendable (InboundFrame) -> Void)?

    /// One complete inbound DATA frame with its header fields.
    public struct InboundFrame: @unchecked Sendable {
        public let kind: PPPPMessage.DataKind
        public let command: UInt16?
        public let channel: UInt8
        public let signCode: UInt8
        public let body: Data
    }

    /// A class, so appending to one channel's stream mutates it in place instead of copying it per packet.
    private final class KindStream {
        var nextSeq: UInt16?
        var reorder: [UInt16: Data] = [:]
        var stream: Data = Data()
        /// When the oldest missing packet was first noticed (nil while there's no hole).
        var holeSince: Date?
    }

    /// Transport counters, for diagnosing stutter.
    public struct Stats: Sendable, CustomStringConvertible {
        public var datagrams = 0, packets = 0, duplicates = 0, outOfOrder = 0, skippedPackets = 0, gaps = 0
        /// Bytes received on the socket (every datagram, retransmissions included): the network rate.
        public var bytes = 0
        public var connected = false
        public var description: String {
            "connected=\(connected) datagrams=\(datagrams) packets=\(packets) dup=\(duplicates) " +
                "outOfOrder=\(outOfOrder) gaps=\(gaps) skippedPackets=\(skippedPackets)"
        }
    }
    private var stats = Stats()
    public func transportStats() -> Stats {
        lock.withLock { var s = stats; s.connected = peer != nil; return s }
    }
    /// Called (on the socket queue) when a lost packet was given up on, so the video can resync on a keyframe.
    private var gapHandler: (@Sendable () -> Void)?
    public func onGap(_ handler: @escaping @Sendable () -> Void) { lock.withLock { gapHandler = handler } }
    /// How long to wait for a missing packet (the HomeBase resends unacked ones) before skipping past it.
    /// How long a hole waits for the HomeBase's resend. Under load (several cameras at 4K through one HomeBase)
    /// resends often take longer than 0.3 s; players keep about a second of buffer, so waiting is cheaper than
    /// throwing away the rest of the frame and everything up to the next keyframe.
    private static let holeTimeout: TimeInterval = 0.8
    /// Packets buffered behind a hole before giving up on it: a 4K keyframe alone can be ~1,000 packets.
    private static let holeBacklog = 4096
    /// Outbound sequence for the video channel (talkback audio), separate from the command channel's.
    private var videoSeqNumber: UInt16 = 0

    // State guarded by `lock`.
    private var peer: UDPSocket.Endpoint?
    private var sawHomeBase = false
    private var lastPeerAt: Date?
    private var connectContinuation: CheckedContinuation<Peer, Error>?
    private var heartbeat: Task<Void, Never>?
    private var closed = false
    private let startedAt = Date()

    public init(config: Config) throws {
        self.config = config
        socket = try UDPSocket()
        if let did = config.p2pDID {
            checkCamPayload = try PPPPMessage.encode(p2pDID: did) + Data([0, 0, 0])
            resolvedDID = did
        }
    }

    /// The DID the session connected with — the configured one, or the one learned from the HomeBase.
    public var connectedDID: String? { lock.withLock { resolvedDID } }

    /// True once CAM_ID has been received.
    public var isConnected: Bool { lock.withLock { peer != nil } }

    /// When the HomeBase last answered (PONG/ACK/PING), for liveness checks.
    public var lastContact: Date? { lock.withLock { lastPeerAt } }

    /// Runs the handshake and resolves once the session is open, or throws on timeout.
    public func connect() async throws -> Peer {
        socket.startReceiving { [weak self] datagram, from in
            self?.handle(datagram, from: from)
        }
        let lookupTask = Task { [weak self] in
            while let self, !Task.isCancelled, !self.isConnected {
                self.sendLookup()
                try? await Task.sleep(for: .seconds(1))
            }
        }
        defer { lookupTask.cancel() }

        let timeout = Task { [config] in
            try? await Task.sleep(for: .seconds(config.connectTimeout))
            self.failIfStillConnecting()
        }
        defer { timeout.cancel() }

        return try await withCheckedThrowingContinuation { continuation in
            lock.withLock {
                if let peer { continuation.resume(returning: peerValue(peer)) }
                else { connectContinuation = continuation }
            }
        }
    }

    public func close() {
        let (heartbeat, peer): (Task<Void, Never>?, UDPSocket.Endpoint?) = lock.withLock {
            closed = true
            defer { self.heartbeat = nil }
            return (self.heartbeat, self.peer)
        }
        heartbeat?.cancel()
        // Tell the HomeBase the session is over, so it frees the slot now rather than after its own timeout:
        // it serves only a few sessions, and one left to expire can keep the next one from being answered.
        if let peer { socket.send(PPPPMessage.frame(PPPPMessage.Request.end), to: peer) }
        socket.close()
    }

    // MARK: Incoming datagrams (called on the socket's queue)

    private func handle(_ datagram: Data, from: UDPSocket.Endpoint) {
        guard let type = PPPPMessage.type(of: datagram) else { return }
        lock.withLock { stats.datagrams += 1; stats.bytes += datagram.count }
        if debug {
            let hex = datagram.map { String(format: "%02x", $0) }.joined()
            FileHandle.standardError.write(Data("[p2p] <- \(from) type=0x\(String(format: "%02x", type)) len=\(datagram.count) \(hex)\n".utf8))
        }
        switch type {
        case PPPPMessage.Response.localLookupResponse where !isConnected:
            // Shares its byte with CAM_ID; before we're connected it means "HomeBase is here" → hole-punch.
            // If we weren't given a DID, learn it from the HomeBase's own announcement — fully cloud-free.
            learnDIDIfNeeded(from: datagram)
            lock.withLock { sawHomeBase = true }
            beginCheckCam(at: from)
        case PPPPMessage.Response.camID, PPPPMessage.Response.turnServerCamID:
            onConnected(peer: from)
        case PPPPMessage.Response.ping:
            socket.send(PPPPMessage.frame(PPPPMessage.Request.pong), to: from) // echo
            noteContact()
        case PPPPMessage.Response.pong, PPPPMessage.Response.ack:
            noteContact()
        case PPPPMessage.Response.data:
            onDataFrame(datagram, from: from)
        default:
            break
        }
    }

    /// Handle an inbound DATA packet: ACK it, reassemble a complete frame across continuation packets,
    /// then surface it. Packet layout: `f1 d0 <len> | d1 <kind> | <seq BE> | <body>`.
    /// A new frame's body starts with a 16-byte header `XZYH <cmd LE> <bytesToRead LE> .. <channel/type>`;
    /// continuation packets carry only more payload bytes for the current frame.
    private func onDataFrame(_ datagram: Data, from: UDPSocket.Endpoint) {
        guard datagram.count >= 8 else { return }
        let bytes = Array(datagram)
        guard let kind = PPPPMessage.DataKind(rawValue: bytes[5]) else { return }
        let seq = UInt16(bytes[6]) << 8 | UInt16(bytes[7])
        socket.send(PPPPMessage.frame(PPPPMessage.Request.ack, payload: PPPPMessage.ackPayload(kind: kind, seq: seq)), to: from)
        noteContact()

        // Order packets by sequence (they can arrive out of order), then parse frames from the ordered
        // byte stream. Large keyframes span hundreds of packets, so reordering matters.
        let payload = Data(datagram.dropFirst(8))
        var completed: [(cmd: UInt16?, channel: UInt8, signCode: UInt8, payload: Data)] = []
        var gapped = false
        lock.withLock {
            let st: KindStream
            if let existing = streams[kind.rawValue] { st = existing } else { st = KindStream(); streams[kind.rawValue] = st }
            stats.packets += 1
            if st.nextSeq == nil { st.nextSeq = seq }
            guard let next = st.nextSeq else { return }
            // Already consumed (behind nextSeq, modulo wrap) or already buffered: a resend — drop it.
            if ((next &- seq) & 0xFFFF < 0x8000 && seq != next) || st.reorder[seq] != nil {
                stats.duplicates += 1
                return
            }
            if seq != next { stats.outOfOrder += 1 }
            st.reorder[seq] = payload
            drain(st)
            // A hole: wait briefly for the resend, then skip to the earliest buffered packet. The frame the
            // hole was in is unusable, so drop the partial bytes and resync on the next frame header.
            if st.reorder.isEmpty {
                st.holeSince = nil
            } else if let since = st.holeSince {
                if Date().timeIntervalSince(since) > Self.holeTimeout || st.reorder.count > Self.holeBacklog,
                   let resume = st.reorder.keys.min(by: { ($0 &- next) < ($1 &- next) }) {
                    stats.gaps += 1
                    stats.skippedPackets += Int(resume &- (st.nextSeq ?? resume))
                    st.nextSeq = resume
                    st.stream.removeAll(keepingCapacity: true)
                    st.holeSince = nil
                    gapped = true
                    drain(st)
                    if !st.reorder.isEmpty { st.holeSince = Date() }
                }
            } else {
                st.holeSince = Date()
            }
            completed = Self.parseFrames(&st.stream, resyncing: gapped)
            if !completed.isEmpty { framesByKind[kind.rawValue, default: 0] += completed.count }
        }
        if gapped, kind == .video, let gap = lock.withLock({ gapHandler }) { mediaQueue.async { gap() } }
        let (handler, detail) = lock.withLock { (frameHandler, detailHandler) }
        guard !completed.isEmpty, handler != nil || detail != nil else { return }
        mediaQueue.async {
            for frame in completed {
                handler?(kind, frame.cmd, frame.signCode, frame.payload)
                detail?(InboundFrame(kind: kind, command: frame.cmd, channel: frame.channel,
                                     signCode: frame.signCode, body: frame.payload))
            }
        }
    }

    /// Moves buffered packets that are now in order onto the byte stream.
    private func drain(_ st: KindStream) {
        while let next = st.nextSeq, let p = st.reorder.removeValue(forKey: next) {
            st.stream.append(p)
            st.nextSeq = next &+ 1
        }
    }

    /// Parses complete `XZYH`-delimited frames out of the ordered byte stream, consuming them.
    /// After a gap the stream starts mid-frame, so `resyncing` skips to the next frame header first.
    private static func parseFrames(_ stream: inout Data, resyncing: Bool = false)
        -> [(cmd: UInt16?, channel: UInt8, signCode: UInt8, payload: Data)] {
        var out: [(cmd: UInt16?, channel: UInt8, signCode: UInt8, payload: Data)] = []
        if resyncing, !stream.prefix(4).elementsEqual(PPPPMessage.commandMagic) {
            if let r = stream.range(of: PPPPMessage.commandMagic) { stream.removeSubrange(stream.startIndex..<r.lowerBound) }
            else { stream = Data(stream.suffix(3)); return out }
        }
        while stream.count >= 16 {
            if !stream.prefix(4).elementsEqual(PPPPMessage.commandMagic) {
                // Resync to the next frame header.
                guard let r = stream.range(of: PPPPMessage.commandMagic) else {
                    stream = stream.suffix(3); break
                }
                stream.removeSubrange(stream.startIndex..<r.lowerBound)
                continue
            }
            let b = [UInt8](stream.prefix(16))
            let cmd = UInt16(b[4]) | UInt16(b[5]) << 8
            let bytesToRead = Int(UInt32(b[6]) | UInt32(b[7]) << 8 | UInt32(b[8]) << 16 | UInt32(b[9]) << 24)
            guard stream.count >= 16 + bytesToRead else { break }
            let start = stream.index(stream.startIndex, offsetBy: 16)
            let end = stream.index(start, offsetBy: bytesToRead)
            out.append((cmd, b[12], b[13], Data(stream[start..<end])))
            stream.removeSubrange(stream.startIndex..<end)
        }
        return out
    }

    /// Install a handler that also receives each frame's channel (see `InboundFrame`).
    public func onFrameDetail(_ handler: @escaping @Sendable (InboundFrame) -> Void) {
        lock.withLock { detailHandler = handler }
    }

    /// Install a handler for inbound DATA frames (commands and video).
    public func onFrame(_ handler: @escaping @Sendable (PPPPMessage.DataKind, UInt16?, UInt8, Data) -> Void) {
        lock.withLock { frameHandler = handler }
    }

    /// Counts of inbound frames by channel kind, e.g. how many video frames have arrived.
    public func frameCounts() -> [PPPPMessage.DataKind: Int] {
        lock.withLock { Dictionary(uniqueKeysWithValues: framesByKind.compactMap { k, v in
            PPPPMessage.DataKind(rawValue: k).map { ($0, v) } }) }
    }

    // MARK: Sending commands

    private func nextSeq() -> UInt16 {
        lock.withLock { defer { seqNumber = seqNumber &+ 1 }; return seqNumber }
    }

    /// Send a control command that carries only a channel (e.g. gateway info).
    public func sendCommand(_ commandType: UInt16, channel: UInt8 = PPPPMessage.stationChannel) {
        guard let address = lock.withLock({ peer }) else { return }
        let body = PPPPMessage.commandHeader(seq: nextSeq(), commandType: commandType)
            + PPPPMessage.voidCommandPayload(channel: channel)
        socket.send(PPPPMessage.frame(PPPPMessage.Request.data, payload: body), to: address)
    }

    /// Start realtime video by selecting a specific camera channel via the START_LIVE control command
    /// (1700 wrapper, inner cmd 1000, `mChannel`). Sent unencrypted, which the local path accepts.
    public func startLive(channel: UInt8, accountId: String = "") {
        let now = Int(Date().timeIntervalSince1970 * 1000)
        let json = """
        {"commandType":1000,"data":{"cmd":1000,"account_id":"\(accountId)","accountId":"\(accountId)",\
        "mChannel":\(channel),"mValue3":0,"mValue5":0,"msg_id":1,"camera_type":0,"entrytype":0,\
        "extValue":1000,"ivalue":1,"restore":0,"streamtype":2,"video_type":12,\
        "timestamp":\(now),"transaction":"\(now)"}}
        """
        sendStringCommand(1700, value: json, channel: channel)
    }

    /// Start realtime video for a specific camera using the level-2 media start (CMD_SET_PAYLOAD 1350,
    /// GCM-encrypted with the level-2 key, carrying the RSA modulus and `mChannel`). This is what selects
    /// a particular HomeBase-attached camera.
    public func startLiveLevel2(channel: UInt8, level2Key: Data, rsaModulusHex: String, accountID: String, streamType: Int = 1) {
        sendSetPayload(PPPPMessage.level2MediaStartJSON(channel: channel, accountID: accountID, rsaModulusHex: rsaModulusHex,
                                                        streamType: streamType),
                       channel: channel, level2Key: level2Key, mediaStart: true)
    }

    /// Stops a HomeBase-attached camera's stream: the SET_PAYLOAD envelope `{cmd:1004, mValue3:1004, payload:{}}`,
    /// the mirror of the start. (A plain level-1 1004 is ignored once the session is level-2.)
    public func stopLiveLevel2(channel: UInt8, level2Key: Data, accountID: String) {
        sendSetPayload("{\"account_id\":\"\(accountID)\",\"cmd\":1004,\"mChannel\":\(channel),\"mValue3\":1004,\"payload\":{}}",
                       channel: channel, level2Key: level2Key, mediaStart: true)
    }

    /// A HomeBase SET_PAYLOAD (1350) command: level-2 GCM over the `{account_id, cmd, mChannel, …}` envelope
    /// JSON. The station relays it to the camera on `channel` (media start, and some device controls).
    /// `mediaStart` gives the frame the per-stream id the live-stream start uses; other commands (settings)
    /// use stream id 0, as eufy-sdk's generic SET_PAYLOAD sender does.
    public func sendSetPayload(_ json: String, channel: UInt8, level2Key: Data, mediaStart: Bool = false) {
        guard let address = lock.withLock({ peer }) else { return }
        // GCM sub uses its own counter from 0; the command header uses the main sequence.
        let l2seq = lock.withLock { let s = level2Seq; level2Seq &+= 1; return s }
        guard let encrypted = PPPPMessage.encryptLevel2(Data(json.utf8), key: level2Key, seq: l2seq) else { return }
        let streamID: UInt8 = !mediaStart || channel == PPPPMessage.stationChannel || channel == 0
            ? 0 : 0x0A + UInt8((l2seq &+ 1) & 0x7F)
        let body = PPPPMessage.commandHeader(seq: nextSeq(), commandType: 1350)
            + PPPPMessage.rawCommandPayload(encrypted, channel: channel, signCode: 8, magic: (0x08, 0x00), streamID: streamID)
        socket.send(PPPPMessage.frame(PPPPMessage.Request.data, payload: body), to: address)
    }

    /// Start two-way audio (talkback) for a camera: CMD_START_TALKBACK (1005), level-2 encrypted, whose
    /// whole plaintext body is the camera channel as a little-endian UInt32.
    public func startTalkback(channel: UInt8, level2Key: Data) {
        sendLevel2Command(1005, channel: channel, plaintext: Data([channel, 0, 0, 0]), level2Key: level2Key)
    }

    public func stopTalkback(channel: UInt8, level2Key: Data) {
        sendLevel2Command(1006, channel: channel, plaintext: Data([channel, 0, 0, 0]), level2Key: level2Key)
    }

    /// A level-2 (GCM, signCode 8) frame whose plaintext is exactly `plaintext` — no envelope. This is how
    /// the app sends control commands once level-2 is up (outer 1700 + JSON, e.g. PTZ), and talkback
    /// start/stop (1005/1006 + the channel). The HomeBase ignores plaintext control frames at level-2.
    public func sendLevel2Command(_ commandType: UInt16, channel: UInt8, plaintext: Data, level2Key: Data) {
        guard let address = lock.withLock({ peer }) else { return }
        let l2seq = lock.withLock { let s = level2Seq; level2Seq &+= 1; return s }
        guard let encrypted = PPPPMessage.encryptLevel2(plaintext, key: level2Key, seq: l2seq) else { return }
        let body = PPPPMessage.commandHeader(seq: nextSeq(), commandType: commandType)
            + PPPPMessage.rawCommandPayload(encrypted, channel: channel, signCode: 8, magic: (0x08, 0x00), streamID: 0)
        socket.send(PPPPMessage.frame(PPPPMessage.Request.data, payload: body), to: address)
    }

    /// Send one outbound ADTS AAC frame to the camera (for talkback). CMD_AUDIO_FRAME on the video channel,
    /// prefixed with a 16-byte header (frame length + channel).
    public func sendAudioFrame(_ adtsFrame: Data, channel: UInt8) {
        guard let address = lock.withLock({ peer }) else { return }
        var header = Data(count: 16)
        let len = UInt32(adtsFrame.count).littleEndian
        let ch = UInt32(channel).littleEndian
        withUnsafeBytes(of: len) { header.replaceSubrange(0..<4, with: $0) }
        withUnsafeBytes(of: ch) { header.replaceSubrange(4..<8, with: $0) }
        let seq = lock.withLock { defer { videoSeqNumber &+= 1 }; return videoSeqNumber }
        let body = PPPPMessage.commandHeader(seq: seq, commandType: 1301, kind: .video)
            + PPPPMessage.rawCommandPayload(header + adtsFrame, channel: channel, signCode: 0, magic: (0x01, 0x00), streamID: 0)
        socket.send(PPPPMessage.frame(PPPPMessage.Request.data, payload: body), to: address)
    }

    /// Send a string-valued command (optionally level-1 encrypted) on a channel.
    public func sendStringCommand(_ commandType: UInt16, value: String, channel: UInt8, key: Data? = nil, encType: UInt8 = 1) {
        guard let address = lock.withLock({ peer }) else { return }
        let body = PPPPMessage.commandHeader(seq: nextSeq(), commandType: commandType)
            + PPPPMessage.stringCommandPayload(value, channel: channel, key: key, encType: encType)
        socket.send(PPPPMessage.frame(PPPPMessage.Request.data, payload: body), to: address)
    }

    private func learnDIDIfNeeded(from datagram: Data) {
        let needsDID = lock.withLock { checkCamPayload == nil }
        guard needsDID, let did = PPPPMessage.announcedDID(in: datagram),
              let payload = try? PPPPMessage.encode(p2pDID: did) + Data([0, 0, 0]) else { return }
        lock.withLock {
            if checkCamPayload == nil { checkCamPayload = payload; resolvedDID = did }
        }
        if debug { FileHandle.standardError.write(Data("[p2p] learned DID \(did) from HomeBase\n".utf8)) }
    }

    private func beginCheckCam(at address: UDPSocket.Endpoint) {
        guard let payload = lock.withLock({ checkCamPayload }) else { return }
        let message = PPPPMessage.frame(PPPPMessage.Request.checkCam, payload: payload)
        if debug {
            FileHandle.standardError.write(Data("[p2p] -> CHECK_CAM to \(address) (+/-3, +:\(config.lookupPort))\n".utf8))
        }
        socket.send(message, to: address)
        // Hole-punch a small neighbourhood of ports around the reported one (NAT remapping)…
        for delta in Int(-3)...3 where delta != 0 {
            let p = Int(address.port) + delta
            if p > 0, p <= 65_535 { socket.send(message, to: .init(host: address.host, port: UInt16(p))) }
        }
        // …and the well-known lookup port, which some HomeBases use for the punch regardless of the
        // ephemeral port their lookup reply came from.
        socket.send(message, to: .init(host: address.host, port: config.lookupPort))
    }

    private func onConnected(peer address: UDPSocket.Endpoint) {
        let continuation: CheckedContinuation<Peer, Error>? = lock.withLock {
            if peer != nil || closed { return nil }
            peer = address
            lastPeerAt = Date()
            defer { connectContinuation = nil }
            return connectContinuation
        }
        guard let continuation else { return }
        socket.send(PPPPMessage.frame(PPPPMessage.Request.ping), to: address)
        startHeartbeat(to: address)
        continuation.resume(returning: peerValue(address))
    }

    private func startHeartbeat(to address: UDPSocket.Endpoint) {
        let task = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                guard let self, !Task.isCancelled else { return }
                self.socket.send(PPPPMessage.frame(PPPPMessage.Request.ping), to: address)
            }
        }
        lock.withLock { heartbeat = task }
    }

    private func sendLookup() {
        let lookup = PPPPMessage.localLookup()
        socket.send(lookup, to: .init(host: "255.255.255.255", port: config.lookupPort))
        if let known = config.knownAddress {
            socket.send(lookup, to: .init(host: known, port: config.lookupPort))
        }
    }

    private func noteContact() { lock.withLock { lastPeerAt = Date() } }

    private func failIfStillConnecting() {
        let result: (continuation: CheckedContinuation<Peer, Error>?, saw: Bool) = lock.withLock {
            defer { connectContinuation = nil }
            return (connectContinuation, sawHomeBase)
        }
        result.continuation?.resume(throwing: ConnectionError.timedOut(sawHomeBase: result.saw))
    }

    private func peerValue(_ endpoint: UDPSocket.Endpoint) -> Peer {
        Peer(host: endpoint.host, port: endpoint.port, elapsed: Date().timeIntervalSince(startedAt))
    }
}
