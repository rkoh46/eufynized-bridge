import Foundation
import EufyKit
import CoreMedia
import CoreVideo
import VideoToolbox

// Checks whether pan/tilt actually moves a camera: streams it, sends rotate steps, and compares a coarse
// picture fingerprint before and after (against a no-PTZ baseline, so ordinary motion doesn't count).
// Also lists each camera's reported device type, and logs the HomeBase's replies to the rotate commands.
//   eufynized-ptz <station-serial> <channel> <homebase-ip> <email> [left|right|up|down]

let args = Array(CommandLine.arguments.dropFirst())
guard args.count >= 4 else { print("usage: eufynized-ptz <station-serial> <channel> <homebase-ip> <email> [direction]"); exit(2) }
let serial = args[0], ip = args[2], email = args[3]
let channel = UInt8(Int(args[1]) ?? 0)
let direction: PTZDirection = switch args.count > 4 ? args[4] : "right" {
    case "left": .left
    case "up": .up
    case "down": .down
    default: .right
}

guard let ecc = CipherKeyCache().eccPrivateKey(stationSerial: serial),
      let accountID = EufySessionStore().load(email: email)?.accountUserId else {
    print("No cached key/session. Run setup in the app first."); exit(1)
}

if ProcessInfo.processInfo.environment["PTZ_DEVICES"] != nil {
    let client = EufyCloudClient(configuration: .init(email: email, countryCode: "US"))
    for d in (try? await client.devices()) ?? [] {
        print("device \(d.name) model=\(d.model) type=\(d.deviceType.map(String.init) ?? "-") panTilt=\(EufyModels.isPanTilt(d.model, deviceType: d.deviceType))")
    }
}

let fingerprints = Fingerprints()
let stream = EufyLiveStream(
    config: .init(homeBaseIP: ip, channel: channel,
                  level2: .init(stationSerial: serial, accountID: accountID, eccPrivateKeyHex: ecc), audio: false),
    onSample: { fingerprints.add($0) },
    onState: { if case .failed(let m) = $0 { print("failed: \(m)") } })
let started = Date()
stream.onControlFrame = { cmd, sign, body in
    print(String(format: "  %5.1fs reply cmd=%d signCode=%d len=%d", Date().timeIntervalSince(started), cmd, sign, body.count))
    if cmd == 1700 || cmd == 1350 {
        print("        hex: " + body.map { String(format: "%02x", $0) }.joined())
        print("        txt: " + String(decoding: body.map { (32...126).contains($0) ? $0 : 46 }, as: UTF8.self))
    }
}
stream.start()

try await Task.sleep(for: .seconds(8))
let a = fingerprints.latest
try await Task.sleep(for: .seconds(3))
let b = fingerprints.latest
print(String(format: "baseline (no PTZ, 3s apart): difference %.1f", Fingerprints.difference(a, b)))
print("sending 6 × rotate \(direction) at \(String(format: "%.1f", Date().timeIntervalSince(started)))s")
for _ in 0..<6 { stream.rotate(direction); try await Task.sleep(for: .milliseconds(400)) }
try await Task.sleep(for: .seconds(4))
let c = fingerprints.latest
print(String(format: "after rotate: difference %.1f  (video frames %@)", Fingerprints.difference(b, c), fingerprints.countText))
stream.stop()

/// A 16×9 grid of average luma — a cheap picture fingerprint. A pan shifts the whole scene, so the
/// difference jumps far above what people or trees moving in a fixed view produce.
final class Fingerprints: @unchecked Sendable {
    private let lock = NSLock()
    private var session: VTDecompressionSession?
    private var last: [Double] = []
    private var frames = 0
    var latest: [Double] { lock.withLock { last } }
    var countText: String { lock.withLock { "\(frames)" } }

    func add(_ sample: CMSampleBuffer) {
        lock.withLock {
            frames += 1
            if let current = session, let fmt = CMSampleBufferGetFormatDescription(sample),
               !VTDecompressionSessionCanAcceptFormatDescription(current, formatDescription: fmt) {
                VTDecompressionSessionInvalidate(current); session = nil
            }
            if session == nil, let fmt = CMSampleBufferGetFormatDescription(sample) {
                let attrs = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange] as CFDictionary
                VTDecompressionSessionCreate(allocator: nil, formatDescription: fmt, decoderSpecification: nil,
                                             imageBufferAttributes: attrs, outputCallback: nil, decompressionSessionOut: &session)
            }
            guard let session else { return }
            var print: [Double] = []
            VTDecompressionSessionDecodeFrame(session, sampleBuffer: sample, flags: [], infoFlagsOut: nil) { status, _, image, _, _ in
                guard status == noErr, let image else { return }
                print = Self.fingerprint(image)
            }
            if !print.isEmpty { last = print }
        }
    }

    static func fingerprint(_ image: CVImageBuffer) -> [Double] {
        CVPixelBufferLockBaseAddress(image, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(image, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddressOfPlane(image, 0) else { return [] }
        let w = CVPixelBufferGetWidthOfPlane(image, 0), h = CVPixelBufferGetHeightOfPlane(image, 0)
        let stride = CVPixelBufferGetBytesPerRowOfPlane(image, 0)
        let y = base.assumingMemoryBound(to: UInt8.self)
        var out: [Double] = []
        for gy in 0..<9 { for gx in 0..<16 {
            var sum = 0, n = 0
            for py in Swift.stride(from: gy * h / 9, to: (gy + 1) * h / 9, by: 8) {
                for px in Swift.stride(from: gx * w / 16, to: (gx + 1) * w / 16, by: 8) { sum += Int(y[py * stride + px]); n += 1 }
            }
            out.append(n > 0 ? Double(sum) / Double(n) : 0)
        }}
        return out
    }

    static func difference(_ a: [Double], _ b: [Double]) -> Double {
        guard a.count == b.count, !a.isEmpty else { return -1 }
        return zip(a, b).map { abs($0 - $1) }.reduce(0, +) / Double(a.count)
    }
}
