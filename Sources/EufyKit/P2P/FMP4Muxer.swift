import Foundation

/// Packs a camera's live video (H.264 or H.265, Annex-B) and ADTS AAC audio into fragmented MP4 for a browser's
/// Media Source Extensions player — one fragment per frame, so there's no added latency.
///
/// Eufy cameras change resolution mid-stream (Auto quality ramps 720p → 1080p → 2K/4K as a stream starts, and
/// steps down when the network is busy). A browser's decoder can't follow a resolution change inside one
/// initialization segment, so each change gets a fresh one — which MSE players then switch to without a restart,
/// the way adaptive streaming works. (The Mac app does the same with a new format description.)
public final class FMP4Muxer {
    public enum Output: Equatable {
        /// The MSE type for `addSourceBuffer` / `changeType`, e.g. `video/mp4; codecs="hvc1.1.6.L153.B0,mp4a.40.2"`.
        case mimeType(String)
        case initSegment(Data)
        case fragment(Data)
    }

    static let videoTrack: UInt32 = 1
    static let audioTrack: UInt32 = 2
    static let videoTimescale: UInt32 = 90_000

    private let includeAudio: Bool
    private var codec: MPEGTSMuxer.VideoCodec?
    private var parameterSets: [Data] = []
    private var size: (width: Int, height: Int) = (0, 0)
    private var audioConfig = AudioConfig(objectType: 2, frequencyIndex: 8, channels: 1)   // AAC-LC 16 kHz mono
    private var initialized = false
    private var origin: Int64?
    private var sequence: UInt32 = 0
    private var lastVideoTime: Int64 = -1
    private var nextAudioSample: Int64?   // in audio timescale units
    /// The latest video frame, held until the next one arrives so its duration is exact: cameras drop their frame
    /// rate under load (a 4K camera sharing the HomeBase can fall to 6 fps), and a guessed duration would leave
    /// gaps the player stalls on.
    private var pending: (time: Int64, sample: Data, keyframe: Bool)?

    public init(audio: Bool) { includeAudio = audio }

    // MARK: Input

    /// One video access unit. Returns nothing until the first keyframe (the stream starts there).
    public func video(_ annexB: Data, captureMs: Int64, keyframe: Bool, size frameSize: String?) -> [Output] {
        if codec == nil { codec = MPEGTSMuxer.detectCodec(annexB) }
        guard let codec else { return [] }
        let nals = Self.nalUnits(annexB)
        var out: [Output] = []
        var time: Int64 = 0
        if initialized {
            time = (captureMs - origin!) * Int64(Self.videoTimescale / 1000)
            if time <= lastVideoTime { time = lastVideoTime + 1 }
        }
        // The held frame ends where this one starts.
        if initialized, let held = pending {
            let duration = UInt32(clamping: min(max(time - held.time, 1), Int64(Self.videoTimescale) * 2))
            out.append(.fragment(fragment(track: Self.videoTrack, decodeTime: held.time, duration: duration,
                                          sample: held.sample, keyframe: held.keyframe)))
            pending = nil
        }
        if keyframe {
            let sets = nals.filter { Self.isParameterSet($0, codec) }
            let newSize = frameSize.flatMap(Self.parseSize) ?? size
            if !sets.isEmpty, sets != parameterSets || newSize != size || !initialized,
               let initSegment = makeInit(sets, codec: codec, size: newSize) {
                parameterSets = sets
                size = newSize
                if !initialized { initialized = true; origin = captureMs; time = 0 }
                out.append(.mimeType(mimeType(codec: codec, sets: sets)))
                out.append(.initSegment(initSegment))
            }
        }
        guard initialized else { return out }
        lastVideoTime = time
        // Sample data: length-prefixed NAL units, without parameter sets or delimiters (they live in the init).
        var sample = Data()
        for nal in nals where !Self.isParameterSet(nal, codec) && !Self.isDelimiter(nal, codec) {
            var length = UInt32(nal.count).bigEndian
            sample.append(Data(bytes: &length, count: 4))
            sample.append(nal)
        }
        if !sample.isEmpty { pending = (time, sample, keyframe) }
        return out
    }

    /// One ADTS AAC frame (header included). Dropped until video has started.
    public func audio(_ adts: Data, captureMs: Int64) -> [Output] {
        guard includeAudio, initialized, let origin else { return [] }
        let bytes = [UInt8](adts)
        guard bytes.count > 7, bytes[0] == 0xFF, bytes[1] & 0xF0 == 0xF0 else { return [] }
        let config = AudioConfig(objectType: Int((bytes[2] >> 6) & 0x3) + 1, frequencyIndex: Int((bytes[2] >> 2) & 0xF),
                                 channels: Int(((bytes[2] & 0x1) << 2) | (bytes[3] >> 6)))
        var out: [Output] = []
        if config != audioConfig, let codec, let initSegment = makeInit(parameterSets, codec: codec, size: size, audio: config) {
            audioConfig = config
            out.append(.mimeType(mimeType(codec: codec, sets: parameterSets)))
            out.append(.initSegment(initSegment))
        }
        let headerLength = bytes[1] & 0x1 == 0 ? 9 : 7   // protection absent → 7 bytes
        guard bytes.count > headerLength else { return out }
        let rate = Int64(audioConfig.sampleRate)
        // Back to back unless the capture clock shows a real gap (or the audio fell behind).
        let fromClock = (captureMs - origin) * rate / 1000
        var t = nextAudioSample ?? fromClock
        if abs(fromClock - t) > rate / 4 { t = max(0, fromClock) }
        nextAudioSample = t + 1024
        out.append(.fragment(fragment(track: Self.audioTrack, decodeTime: t, duration: 1024,
                                      sample: Data(bytes[headerLength...]), keyframe: true)))
        return out
    }

    // MARK: Codec details

    struct AudioConfig: Equatable {
        var objectType: Int, frequencyIndex: Int, channels: Int
        var sampleRate: Int {
            let rates = [96000, 88200, 64000, 48000, 44100, 32000, 24000, 22050, 16000, 12000, 11025, 8000, 7350]
            return frequencyIndex < rates.count ? rates[frequencyIndex] : 16000
        }
        var specificConfig: Data {
            Data([UInt8(objectType << 3 | frequencyIndex >> 1), UInt8((frequencyIndex & 1) << 7 | channels << 3)])
        }
    }

    static func parseSize(_ text: String) -> (Int, Int)? {
        let parts = text.split(separator: "x").compactMap { Int($0) }
        return parts.count == 2 && parts[0] > 0 && parts[1] > 0 ? (parts[0], parts[1]) : nil
    }

    static func nalUnits(_ annexB: Data) -> [Data] {
        let b = [UInt8](annexB)
        var starts: [Int] = []
        var i = 0
        while i + 3 <= b.count {
            if b[i] == 0, b[i + 1] == 0, b[i + 2] == 1 { starts.append(i + 3); i += 3 } else { i += 1 }
        }
        return starts.enumerated().compactMap { n, start in
            var end = n + 1 < starts.count ? starts[n + 1] - 3 : b.count
            while end > start, b[end - 1] == 0 { end -= 1 }
            return end > start ? Data(b[start..<end]) : nil
        }
    }

    static func nalType(_ nal: Data, _ codec: MPEGTSMuxer.VideoCodec) -> Int {
        let h = nal[nal.startIndex]
        return codec == .h265 ? Int((h >> 1) & 0x3F) : Int(h & 0x1F)
    }

    static func isParameterSet(_ nal: Data, _ codec: MPEGTSMuxer.VideoCodec) -> Bool {
        codec == .h265 ? (32...34).contains(nalType(nal, codec)) : [7, 8].contains(nalType(nal, codec))
    }

    static func isDelimiter(_ nal: Data, _ codec: MPEGTSMuxer.VideoCodec) -> Bool {
        nalType(nal, codec) == (codec == .h265 ? 35 : 9)
    }

    /// The bytes of a NAL unit with emulation-prevention bytes removed (to read fields out of an SPS).
    static func rbsp(_ nal: Data) -> [UInt8] {
        var out: [UInt8] = []
        var zeros = 0
        for byte in nal {
            if zeros >= 2 && byte == 3 { zeros = 0; continue }
            zeros = byte == 0 ? zeros + 1 : 0
            out.append(byte)
        }
        return out
    }

    /// H.265 profile_tier_level from the SPS: 12 bytes after the 2-byte header and 1 byte of ids.
    static func h265ProfileTierLevel(_ sps: Data) -> [UInt8]? {
        let r = rbsp(sps)
        return r.count >= 15 ? Array(r[3..<15]) : nil
    }

    private func mimeType(codec: MPEGTSMuxer.VideoCodec, sets: [Data]) -> String {
        var codecs: String
        switch codec {
        case .h264:
            let sps = sets.first { Self.nalType($0, .h264) == 7 }.map { [UInt8]($0) } ?? [0x67, 0x64, 0, 0x29]
            codecs = String(format: "avc1.%02X%02X%02X", sps[1], sps[2], sps[3])
        case .h265:
            codecs = "hvc1.1.6.L153.B0"
            if let sps = sets.first(where: { Self.nalType($0, .h265) == 33 }), let ptl = Self.h265ProfileTierLevel(sps) {
                let space = ["", "A", "B", "C"][Int(ptl[0] >> 6)]
                let tier = ptl[0] & 0x20 != 0 ? "H" : "L"
                let profile = Int(ptl[0] & 0x1F)
                // Compatibility flags, bit-reversed, in hex.
                let flags = UInt32(ptl[1]) << 24 | UInt32(ptl[2]) << 16 | UInt32(ptl[3]) << 8 | UInt32(ptl[4])
                var reversed: UInt32 = 0
                for bit in 0..<32 where flags & (1 << bit) != 0 { reversed |= 1 << (31 - bit) }
                var constraints = Array(ptl[5..<11])
                while let last = constraints.last, last == 0 { constraints.removeLast() }
                codecs = "hvc1.\(space)\(profile).\(String(reversed, radix: 16, uppercase: true)).\(tier)\(ptl[11])"
                    + constraints.map { "." + String($0, radix: 16, uppercase: true) }.joined()
            }
        }
        if includeAudio { codecs += ",mp4a.40.\(audioConfig.objectType)" }
        return "video/mp4; codecs=\"\(codecs)\""
    }

    // MARK: Boxes

    private static func box(_ type: String, _ payload: Data) -> Data {
        var out = Data()
        out.append(be32(UInt32(8 + payload.count)))
        out.append(Data(type.utf8))
        out.append(payload)
        return out
    }

    private static func fullBox(_ type: String, version: UInt8 = 0, flags: UInt32 = 0, _ payload: Data) -> Data {
        box(type, Data([version, UInt8(flags >> 16 & 0xFF), UInt8(flags >> 8 & 0xFF), UInt8(flags & 0xFF)]) + payload)
    }

    /// Concatenates box fields (long `+` chains are too slow for the type checker).
    static func join(_ parts: Data...) -> Data { parts.reduce(into: Data()) { $0.append($1) } }

    static func be16(_ v: UInt16) -> Data { Data([UInt8(v >> 8), UInt8(v & 0xFF)]) }
    static func be32(_ v: UInt32) -> Data { Data([UInt8(v >> 24), UInt8(v >> 16 & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v & 0xFF)]) }
    static func be64(_ v: UInt64) -> Data { be32(UInt32(v >> 32)) + be32(UInt32(v & 0xFFFF_FFFF)) }

    private static let matrix: Data = [0x10000, 0, 0, 0, 0x10000, 0, 0, 0, 0x4000_0000].reduce(into: Data()) { $0.append(be32(UInt32($1))) }

    private func makeInit(_ sets: [Data], codec: MPEGTSMuxer.VideoCodec, size: (width: Int, height: Int),
                          audio: AudioConfig? = nil) -> Data? {
        guard let entry = visualSampleEntry(sets, codec: codec, size: size) else { return nil }
        let audio = audio ?? audioConfig
        let ftyp = Self.box("ftyp", Data("iso5".utf8) + Self.be32(512) + Data("iso5iso6mp41".utf8))
        let mvhd = Self.fullBox("mvhd", Self.join(Self.be32(0), Self.be32(0), Self.be32(1000), Self.be32(0),
                                                  Self.be32(0x0001_0000), Self.be16(0x0100), Data(count: 10), Self.matrix,
                                                  Data(count: 24), Self.be32(includeAudio ? 3 : 2)))
        var traks = trak(id: Self.videoTrack, handler: "vide", timescale: Self.videoTimescale, entry: entry,
                         width: size.width, height: size.height)
        var trexes = trex(Self.videoTrack)
        if includeAudio {
            traks += trak(id: Self.audioTrack, handler: "soun", timescale: UInt32(audio.sampleRate),
                          entry: audioSampleEntry(audio), width: 0, height: 0)
            trexes += trex(Self.audioTrack)
        }
        return ftyp + Self.box("moov", mvhd + traks + Self.box("mvex", trexes))
    }

    private func trak(id: UInt32, handler: String, timescale: UInt32, entry: Data, width: Int, height: Int) -> Data {
        let tkhd = Self.fullBox("tkhd", flags: 3, Self.join(
            Self.be32(0), Self.be32(0), Self.be32(id), Self.be32(0), Self.be32(0), Data(count: 8),
            Self.be16(0), Self.be16(0), Self.be16(handler == "soun" ? 0x0100 : 0), Self.be16(0),
            Self.matrix, Self.be32(UInt32(width) << 16), Self.be32(UInt32(height) << 16)))
        let mdhd = Self.fullBox("mdhd", Self.join(Self.be32(0), Self.be32(0), Self.be32(timescale), Self.be32(0),
                                                  Self.be16(0x55C4), Self.be16(0)))
        let hdlr = Self.fullBox("hdlr", Self.be32(0) + Data(handler.utf8) + Data(count: 12) + Data("Eufynized\0".utf8))
        let header = handler == "vide" ? Self.fullBox("vmhd", flags: 1, Data(count: 8)) : Self.fullBox("smhd", Data(count: 4))
        let dinf = Self.box("dinf", Self.fullBox("dref", Self.be32(1) + Self.fullBox("url ", flags: 1, Data())))
        let stbl = Self.box("stbl", Self.fullBox("stsd", Self.be32(1) + entry)
            + Self.fullBox("stts", Self.be32(0)) + Self.fullBox("stsc", Self.be32(0))
            + Self.fullBox("stsz", Self.be32(0) + Self.be32(0)) + Self.fullBox("stco", Self.be32(0)))
        return Self.box("trak", tkhd + Self.box("mdia", mdhd + hdlr + Self.box("minf", header + dinf + stbl)))
    }

    private func trex(_ id: UInt32) -> Data {
        Self.fullBox("trex", Self.be32(id) + Self.be32(1) + Self.be32(0) + Self.be32(0) + Self.be32(0))
    }

    private func visualSampleEntry(_ sets: [Data], codec: MPEGTSMuxer.VideoCodec, size: (width: Int, height: Int)) -> Data? {
        let config: Data
        switch codec {
        case .h264:
            guard let sps = sets.first(where: { Self.nalType($0, .h264) == 7 }), sps.count >= 4 else { return nil }
            let s = [UInt8](sps)
            var avcC = Data([1, s[1], s[2], s[3], 0xFF, 0xE1]) + Self.be16(UInt16(sps.count)) + sps
            let ppss = sets.filter { Self.nalType($0, .h264) == 8 }
            avcC.append(UInt8(ppss.count))
            for pps in ppss { avcC += Self.be16(UInt16(pps.count)) + pps }
            config = Self.box("avcC", avcC)
        case .h265:
            guard let sps = sets.first(where: { Self.nalType($0, .h265) == 33 }), let ptl = Self.h265ProfileTierLevel(sps) else { return nil }
            var hvcC = Data([1]) + Data(ptl)                       // version, profile/tier/level (12 bytes)
            hvcC += Data([0xF0, 0x00, 0xFC, 0xFD, 0xF8, 0xF8, 0x00, 0x00, 0x0F])
            let arrays = [32, 33, 34].map { type in sets.filter { Self.nalType($0, .h265) == type } }.filter { !$0.isEmpty }
            hvcC.append(UInt8(arrays.count))
            for nals in arrays {
                hvcC.append(0x80 | UInt8(Self.nalType(nals[0], .h265)))
                hvcC += Self.be16(UInt16(nals.count))
                for nal in nals { hvcC += Self.be16(UInt16(nal.count)) + nal }
            }
            config = Self.box("hvcC", hvcC)
        }
        let width = size.width > 0 ? size.width : 1920, height = size.height > 0 ? size.height : 1080
        let entry = Self.join(Data(count: 6), Self.be16(1), Data(count: 16), Self.be16(UInt16(width)), Self.be16(UInt16(height)),
                              Self.be32(0x0048_0000), Self.be32(0x0048_0000), Self.be32(0), Self.be16(1), Data(count: 32),
                              Self.be16(0x0018), Self.be16(0xFFFF), config)
        return Self.box(codec == .h265 ? "hvc1" : "avc1", entry)
    }

    private func audioSampleEntry(_ audio: AudioConfig) -> Data {
        let asc = audio.specificConfig
        let decoderSpecific = Data([0x05, UInt8(asc.count)]) + asc
        let decoderConfig = Data([0x04, UInt8(13 + decoderSpecific.count), 0x40, 0x15, 0, 0, 0])
            + Self.be32(0) + Self.be32(0) + decoderSpecific
        let sl = Data([0x06, 0x01, 0x02])
        let es = Data([0x03, UInt8(3 + decoderConfig.count + sl.count)]) + Self.be16(0) + Data([0]) + decoderConfig + sl
        return Self.box("mp4a", Self.join(Data(count: 6), Self.be16(1), Data(count: 8), Self.be16(UInt16(audio.channels)),
                                          Self.be16(16), Self.be16(0), Self.be16(0), Self.be32(UInt32(audio.sampleRate) << 16),
                                          Self.fullBox("esds", es)))
    }

    private func fragment(track: UInt32, decodeTime: Int64, duration: UInt32, sample: Data, keyframe: Bool) -> Data {
        sequence &+= 1
        let flags: UInt32 = keyframe ? 0x0200_0000 : 0x0101_0000
        let tfhd = Self.fullBox("tfhd", flags: 0x020000, Self.be32(track))
        let tfdt = Self.fullBox("tfdt", version: 1, Self.be64(UInt64(max(0, decodeTime))))
        // trun: data offset, then one sample's duration, size and flags.
        func moof(dataOffset: UInt32) -> Data {
            let trun = Self.fullBox("trun", flags: 0x000701, Self.be32(1) + Self.be32(dataOffset)
                + Self.be32(duration) + Self.be32(UInt32(sample.count)) + Self.be32(flags))
            return Self.box("moof", Self.fullBox("mfhd", Self.be32(sequence)) + Self.box("traf", tfhd + tfdt + trun))
        }
        let size = moof(dataOffset: 0).count
        return moof(dataOffset: UInt32(size + 8)) + Self.box("mdat", sample)
    }
}
