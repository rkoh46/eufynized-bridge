import Foundation
import EufyKit
import EufynizedKit
import CoreMedia
import VideoToolbox

// Measures the live path on real hardware: frames per second actually decoded (through VideoToolbox,
// as the display layer would), the longest gap between frames, and transport/decode counters.
//   swift run eufynized-fps <station-serial> <channel> <homebase-ip> <email>
//   swift run eufynized-fps --level1 <homebase-ip>     (HomeBase's active camera; no Keychain access)
//   swift run eufynized-fps --bridge <url> <channel>    (the Pi bridge's raw feed, as the Mac app plays it at home)
// Live-view quality (level-2; changes the camera's persistent Streaming Quality setting):
//   QUALITY=auto|hd720|fullHD|twoK|max   the camera's level, model looked up in the cached catalog
//   QUALITY_RAW=2730:<n> | 1705:<n>      a raw value on one wire
//   QUALITY_AT=<s>                       send it this many seconds after video starts (default 3)
//   PROBE_CONTROL=1                      print non-media frames (the station's replies)

let args = Array(CommandLine.arguments.dropFirst())
if args.first == "--bridge", args.count >= 3, let base = URL(string: args[1]), let ch = UInt8(args[2]) {
    let counter = Counter()
    let total = Int(ProcessInfo.processInfo.environment["PROBE_SECONDS"] ?? "") ?? 25
    let stream = BridgeLiveStream(client: BridgeClient(base: base), channel: ch, audio: false,
                                  onSample: { counter.decode($0) },
                                  onState: { state in print("  state: \(state)") })
    print("Measuring bridge \(base) ch\(ch) for \(total)s…")
    stream.start()
    for s in 1...total {
        try await Task.sleep(for: .seconds(1))
        let (n, gap) = counter.takeSecond()
        print("  \(s)s: \(n) fps, longest gap \(Int(gap * 1000))ms, decode ok=\(counter.decoded) err=\(counter.errors) | \(stream.diagnostics)")
    }
    stream.stop()
    exit(0)
}
let config: EufyLiveStream.Config
let label: String
if args.first == "--level1", args.count >= 2 {
    config = .init(homeBaseIP: args[1])
    label = "level-1 (active camera)"
} else if args.count >= 4 {
    let serial = args[0], ip = args[2], email = args[3]
    let channel = UInt8(Int(args[1]) ?? 0)
    guard let ecc = CipherKeyCache().eccPrivateKey(stationSerial: serial),
          let accountID = EufySessionStore().load(email: email)?.accountUserId else {
        print("No cached key/session. Run setup first."); exit(1)
    }
    let camera = CameraCatalogCache().load(email: email)?.first { $0.channel == Int(channel) }
    config = .init(homeBaseIP: ip, channel: channel,
                   level2: .init(stationSerial: serial, accountID: accountID, eccPrivateKeyHex: ecc),
                   model: camera?.serial)
    label = "\(serial) ch\(channel) \(camera.map { "\($0.name) \($0.serial.prefix(5))" } ?? "")"
} else {
    print("usage: eufynized-fps <station-serial> <channel> <homebase-ip> <email> | --level1 <homebase-ip>"); exit(2)
}

let counter = Counter()
let stream = EufyLiveStream(
    config: config,
    onSample: { counter.decode($0) },
    onState: { state in if case .failed(let m) = state { print("failed: \(m)") } })

let total = Int(ProcessInfo.processInfo.environment["PROBE_SECONDS"] ?? "") ?? 25
let env = ProcessInfo.processInfo.environment
if env["PROBE_CONTROL"] != nil {
    stream.onControlFrame = { cmd, sign, body in
        let text = String(decoding: body.prefix(200), as: UTF8.self).filter { $0.isASCII && !$0.isNewline }
        print("    control cmd=\(cmd) sign=\(sign) len=\(body.count) hex=\(body.prefix(24).map { String(format: "%02x", $0) }.joined()) \(text)")
    }
}
let qualityAt = Int(env["QUALITY_AT"] ?? "") ?? 3
print("Measuring \(label) for \(total)s…")
if let p = stream.qualityProfile { print("quality levels: \(p.options.map(\.rawValue).joined(separator: " ")) via \(p.wire)") }
stream.start()
var steady = 0
var videoStartedAt: Int?
for s in 1...total {
    try await Task.sleep(for: .seconds(1))
    if videoStartedAt == nil, stream.videoSize != nil { videoStartedAt = s }
    if let started = videoStartedAt, let at = Int(env["STALL_AT"] ?? ""), s == started + at {
        print("  -> telling the camera to stop streaming (the watchdog should bring it back)")
        stream.stopCameraStreamForTesting()
    }
    if let started = videoStartedAt, s == started + qualityAt {
        if let name = env["QUALITY"], let q = StreamQuality(rawValue: name) {
            print("  -> quality \(q.label) (wire value \(stream.qualityProfile?.value(for: q).map(String.init) ?? "unsupported"))")
            stream.setQuality(q)
        } else if let raw = env["QUALITY_RAW"], let colon = raw.firstIndex(of: ":"), let v = Int(raw[raw.index(after: colon)...]) {
            let wire: StreamQualityProfile.Wire = raw.hasPrefix("1705") ? .videoQuality1705 : .setPayload2730
            print("  -> raw quality \(wire) = \(v)")
            stream.sendQuality(wire: wire, value: v)
        }
    }
    let (n, gap) = counter.takeSecond()
    if s > 5 { steady += n }
    print("  \(s)s: \(n) fps, longest gap \(Int(gap * 1000))ms, decode ok=\(counter.decoded) err=\(counter.errors) | \(stream.videoDiagnostics)")
}
print("video: \(stream.videoDiagnostics)")
print("decode: ok=\(counter.decoded) errors=\(counter.errors)")
print("audio: \(stream.audioDiagnostics)")
print("steady-state average (after 5s): \(String(format: "%.1f", Double(steady) / Double(total - 5))) fps")
stream.stop()

final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var second = 0
    private var longestGap: TimeInterval = 0
    private var last: Date?
    private var session: VTDecompressionSession?
    private(set) var decoded = 0, errors = 0
    private var log = 0

    func decode(_ sample: CMSampleBuffer) {
        lock.withLock {
            let now = Date()
            if let last { longestGap = max(longestGap, now.timeIntervalSince(last)) }
            last = now
            second += 1
            if let current = session, let fmt = CMSampleBufferGetFormatDescription(sample),
               !VTDecompressionSessionCanAcceptFormatDescription(current, formatDescription: fmt) {
                VTDecompressionSessionInvalidate(current); session = nil
            }
            if session == nil, let fmt = CMSampleBufferGetFormatDescription(sample) {
                VTDecompressionSessionCreate(allocator: nil, formatDescription: fmt, decoderSpecification: nil,
                                             imageBufferAttributes: nil, outputCallback: nil, decompressionSessionOut: &session)
            }
            guard let session else { return }
            var ok = false
            let status = VTDecompressionSessionDecodeFrame(session, sampleBuffer: sample, flags: [], infoFlagsOut: nil) { status, _, image, _, _ in
                ok = status == noErr && image != nil
            }
            if status == noErr && ok { decoded += 1 } else { errors += 1 }
            if log < 40, ProcessInfo.processInfo.environment["PROBE_FRAMES"] != nil {
                log += 1
                print("    frame \(log): status=\(status) ok=\(ok) \(Self.describe(sample))")
            }
        }
    }

    /// NAL types and sizes inside an AVCC sample (works for H.264 and H.265 headers).
    static func describe(_ sample: CMSampleBuffer) -> String {
        guard let block = CMSampleBufferGetDataBuffer(sample) else { return "-" }
        var length = 0; var ptr: UnsafeMutablePointer<CChar>?
        CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length, dataPointerOut: &ptr)
        guard let ptr else { return "-" }
        let bytes = UnsafeRawPointer(ptr).assumingMemoryBound(to: UInt8.self)
        var i = 0; var parts: [String] = []
        while i + 4 < length {
            let n = Int(bytes[i]) << 24 | Int(bytes[i+1]) << 16 | Int(bytes[i+2]) << 8 | Int(bytes[i+3])
            let h = bytes[i+4]
            parts.append("h265t\((h >> 1) & 0x3F)/h264t\(h & 0x1F):\(n)B")
            i += 4 + n
        }
        return "total=\(length) [\(parts.joined(separator: " "))]" + (i == length ? "" : " MISALIGNED(\(i) vs \(length))")
    }

    func takeSecond() -> (Int, TimeInterval) {
        lock.withLock { defer { second = 0; longestGap = 0 }; return (second, longestGap) }
    }
}
