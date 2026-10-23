import Foundation

/// Packs a camera's Annex-B video (H.264 or H.265) and ADTS AAC audio into an MPEG transport stream — the
/// format the Home Assistant add-on hands to go2rtc, which repackages it for browsers (MSE / WebRTC / HLS).
/// No re-encoding: frames go out exactly as the camera sent them, timed by the camera's capture clock.
///
/// Every keyframe is preceded by the PAT and PMT, so a reader can join at any keyframe.
public final class MPEGTSMuxer {
    public enum VideoCodec: Sendable, Equatable {
        case h264, h265
        var streamType: UInt8 { self == .h265 ? 0x24 : 0x1B }
    }

    static let pmtPID: UInt16 = 0x1000
    static let videoPID: UInt16 = 0x100
    static let audioPID: UInt16 = 0x101

    /// The video codec, learned from the first parameter set (VPS/SPS) seen. nil until then.
    public private(set) var codec: VideoCodec?
    private var counters: [UInt16: UInt8] = [:]
    /// The capture time (ms) that maps to PTS 0, so timestamps start small and stay positive.
    private var origin: Int64?
    private var lastVideoMs: Int64 = -1
    private var lastAudioMs: Int64 = -1

    public init(codec: VideoCodec? = nil) { self.codec = codec }

    /// One video access unit as TS packets (with PAT/PMT first when it's a keyframe). Empty until the codec
    /// is known, since the PMT has to name it — the camera's first keyframe carries its parameter sets.
    public func video(_ annexB: Data, captureMs: Int64, keyframe: Bool) -> Data {
        if codec == nil { codec = Self.detectCodec(annexB) }
        guard codec != nil, !annexB.isEmpty else { return Data() }
        if origin == nil {
            guard keyframe else { return Data() }   // start on a keyframe
            origin = captureMs
        }
        // Keep time moving forward: a camera clock that steps back would stall the reader.
        var ms = captureMs - (origin ?? captureMs)
        if ms <= lastVideoMs { ms = lastVideoMs + 1 }
        lastVideoMs = ms
        var out = Data()
        if keyframe { out += programTables() }
        let pts = UInt64(ms + 1000) * 90   // +1 s so audio slightly ahead of video never goes negative
        let pes = Self.pesPacket(streamID: 0xE0, pts: pts, payload: Self.withAccessUnitDelimiter(annexB, codec: codec!), unbounded: true)
        out += packetize(pes, pid: Self.videoPID, pcr: pts, randomAccess: keyframe)
        return out
    }

    /// One ADTS AAC frame as TS packets. Dropped until the first video keyframe has set the clock.
    public func audio(_ adts: Data, captureMs: Int64) -> Data {
        guard let origin, !adts.isEmpty else { return Data() }
        var ms = captureMs - origin
        if ms <= lastAudioMs { ms = lastAudioMs + 1 }
        lastAudioMs = ms
        guard ms > -1000 else { return Data() }
        let pts = UInt64(ms + 1000) * 90
        let pes = Self.pesPacket(streamID: 0xC0, pts: pts, payload: adts, unbounded: false)
        return packetize(pes, pid: Self.audioPID, pcr: nil, randomAccess: false)
    }

    // MARK: Codec

    /// H.265 when the stream carries a VPS/SPS with H.265 NAL headers, H.264 for an H.264 SPS; nil if neither.
    public static func detectCodec(_ annexB: Data) -> VideoCodec? {
        for header in nalHeaders(annexB) {
            if header == 0x40 || header == 0x42 { return .h265 }            // VPS / SPS (type 32 / 33)
            if header & 0x1F == 7, header & 0x80 == 0 { return .h264 }      // SPS (type 7)
        }
        return nil
    }

    /// The stream's parameter sets in this frame (VPS/SPS/PPS for H.265, SPS/PPS for H.264), concatenated —
    /// they change when the camera switches resolution. Empty when the frame carries none.
    public static func parameterSets(_ annexB: Data, codec: VideoCodec) -> Data {
        let b = [UInt8](annexB)
        var starts: [Int] = []
        var i = 0
        while i + 3 < b.count {
            if b[i] == 0, b[i + 1] == 0, b[i + 2] == 1 { starts.append(i + 3); i += 3 } else { i += 1 }
        }
        var out = Data()
        for (n, start) in starts.enumerated() {
            let header = b[start]
            let isParameterSet = codec == .h265 ? (32...34).contains(Int((header >> 1) & 0x3F)) : [7, 8].contains(header & 0x1F)
            guard isParameterSet else { continue }
            var end = n + 1 < starts.count ? starts[n + 1] - 3 : b.count
            while end > start, b[end - 1] == 0 { end -= 1 }   // trailing zeros of the next start code
            out.append(contentsOf: b[start..<end])
        }
        return out
    }

    /// The first byte of each NAL unit in an Annex-B stream.
    static func nalHeaders(_ data: Data) -> [UInt8] {
        let b = [UInt8](data)
        var out: [UInt8] = []
        var i = 0
        while i + 3 < b.count {
            if b[i] == 0, b[i + 1] == 0, b[i + 2] == 1 { out.append(b[i + 3]); i += 3 }
            else { i += 1 }
        }
        return out
    }

    /// Prefixes an access unit delimiter unless the frame already starts with one (some readers split
    /// access units on it).
    static func withAccessUnitDelimiter(_ annexB: Data, codec: VideoCodec) -> Data {
        let first = nalHeaders(annexB.prefix(8)).first
        switch codec {
        case .h265:
            if let first, (first >> 1) & 0x3F == 35 { return annexB }
            return Data([0, 0, 0, 1, 0x46, 0x01, 0x50]) + annexB
        case .h264:
            if let first, first & 0x1F == 9 { return annexB }
            return Data([0, 0, 0, 1, 0x09, 0xF0]) + annexB
        }
    }

    // MARK: Packets

    private func programTables() -> Data {
        // PAT: program 1 → PMT PID.
        var pat = Data([0x00, 0x00, 0xB0, 0x0D, 0x00, 0x01, 0xC1, 0x00, 0x00, 0x00, 0x01,
                        0xE0 | UInt8(Self.pmtPID >> 8), UInt8(Self.pmtPID & 0xFF)])
        pat += Self.crc32(pat.dropFirst())
        // PMT: PCR on the video PID; video + AAC (ADTS) audio.
        let streams: [(UInt8, UInt16)] = [(codec?.streamType ?? 0x24, Self.videoPID), (0x0F, Self.audioPID)]
        var body = Data([0x02, 0x00, 0x00, 0x00, 0x01, 0xC1, 0x00, 0x00,
                         0xE0 | UInt8(Self.videoPID >> 8), UInt8(Self.videoPID & 0xFF), 0xF0, 0x00])
        for (type, pid) in streams { body += Data([type, 0xE0 | UInt8(pid >> 8), UInt8(pid & 0xFF), 0xF0, 0x00]) }
        let sectionLength = body.count - 3 + 4   // after the length field, including the CRC
        body[1] = 0xB0 | UInt8(sectionLength >> 8)
        body[2] = UInt8(sectionLength & 0xFF)
        var pmt = Data([0x00]) + body
        pmt += Self.crc32(body)
        return packetize(pat, pid: 0, pcr: nil, randomAccess: false, padWithFF: true)
            + packetize(pmt, pid: Self.pmtPID, pcr: nil, randomAccess: false, padWithFF: true)
    }

    static func pesPacket(streamID: UInt8, pts: UInt64, payload: Data, unbounded: Bool) -> Data {
        var out = Data([0x00, 0x00, 0x01, streamID])
        let headerLength = 5
        let length = unbounded ? 0 : min(0xFFFF, 3 + headerLength + payload.count)
        out += Data([UInt8(length >> 8), UInt8(length & 0xFF), 0x80, 0x80, UInt8(headerLength)])
        out += Data([0x21 | UInt8((pts >> 29) & 0x0E),
                     UInt8((pts >> 22) & 0xFF), UInt8(((pts >> 14) & 0xFE) | 1),
                     UInt8((pts >> 7) & 0xFF), UInt8(((pts << 1) & 0xFE) | 1)])
        out += payload
        return out
    }

    /// Splits a PES packet (or a table section) into 188-byte TS packets. Tables are padded with 0xFF bytes
    /// after the section; PES packets are padded with adaptation-field stuffing.
    private func packetize(_ payload: Data, pid: UInt16, pcr: UInt64?, randomAccess: Bool, padWithFF: Bool = false) -> Data {
        var out = Data(capacity: (payload.count / 184 + 2) * 188)
        var offset = payload.startIndex
        var first = true
        while offset < payload.endIndex || first {
            let counter = counters[pid, default: 0]
            counters[pid] = (counter + 1) & 0x0F
            // The adaptation field's contents (after its length byte), or nil for none.
            var adaptation: Data?
            if first && (pcr != nil || randomAccess) {
                var flags: UInt8 = randomAccess ? 0x40 : 0
                var fields = Data()
                if let pcr {
                    flags |= 0x10
                    let base = pcr & 0x1_FFFF_FFFF
                    fields += Data([UInt8(base >> 25), UInt8((base >> 17) & 0xFF), UInt8((base >> 9) & 0xFF),
                                    UInt8((base >> 1) & 0xFF), UInt8((base & 1) << 7) | 0x7E, 0x00])
                }
                adaptation = Data([flags]) + fields
            }
            let remaining = payload.endIndex - offset
            var room = 184 - (adaptation.map { $0.count + 1 } ?? 0)
            if !padWithFF && remaining < room {
                // Stuff the adaptation field so the payload exactly fills the packet.
                let stuffing = room - remaining
                if var a = adaptation {
                    a += Data(repeating: 0xFF, count: stuffing)
                    adaptation = a
                } else {
                    adaptation = stuffing == 1 ? Data() : Data([0x00]) + Data(repeating: 0xFF, count: stuffing - 2)
                }
                room = remaining
            }
            out += header(pid: pid, start: first, counter: counter, adaptation: adaptation != nil)
            if let adaptation { out.append(UInt8(adaptation.count)); out += adaptation }
            let take = min(room, remaining)
            out += payload[offset..<offset + take]
            offset += take
            if take < room { out += Data(repeating: 0xFF, count: room - take) }
            first = false
        }
        return out
    }

    private func header(pid: UInt16, start: Bool, counter: UInt8, adaptation: Bool) -> Data {
        Data([0x47, (start ? 0x40 : 0x00) | UInt8(pid >> 8), UInt8(pid & 0xFF), (adaptation ? 0x30 : 0x10) | counter])
    }

    /// CRC-32/MPEG-2, big-endian, as table sections end with.
    static func crc32<C: Collection>(_ bytes: C) -> Data where C.Element == UInt8 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in bytes {
            crc ^= UInt32(byte) << 24
            for _ in 0..<8 { crc = crc & 0x8000_0000 != 0 ? (crc << 1) ^ 0x04C1_1DB7 : crc << 1 }
        }
        return Data([UInt8(crc >> 24), UInt8((crc >> 16) & 0xFF), UInt8((crc >> 8) & 0xFF), UInt8(crc & 0xFF)])
    }
}
