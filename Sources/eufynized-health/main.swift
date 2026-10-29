import Foundation
import EufyKit
import CoreMedia
import VideoToolbox

// End-to-end health check of the direct path, stage by stage, on real hardware: HomeBase discovery,
// P2P session, level-2 key, and per camera a level-2 live start that must decode video, plus audio and
// the camera's settings report. Writes a JSON report (the "wire fingerprint") that
// scripts/eufy_health_compare.py diffs against the last good run, so a HomeBase or camera firmware update
// that changes or breaks the protocol is caught the day it lands.
//
// Reads the app's own settings (HomeBase IP, station serial, account) and caches. Secrets are only read
// when they are already in the secrets file: it never touches the Keychain, so it can't prompt.
//   eufynized-health [--quick] [--cloud] [--seconds N] [--channels 0,2] [--out report.json]
//     --quick     one mains-powered camera instead of all (spares battery cameras)
//     --cloud     also fetch the device list for firmware versions, channels and Wi-Fi signal (with it,
//                 a camera that is off the network is reported OFFLINE instead of failing the check)
// Exit status: 0 all stages passed, 1 a stage failed, 2 not set up / usage.

let args = Array(CommandLine.arguments.dropFirst())
func option(_ name: String) -> String? { args.firstIndex(of: name).flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil } }
let quick = args.contains("--quick")
let useCloud = args.contains("--cloud")
let seconds = Double(option("--seconds") ?? "") ?? 10
let onlyChannels = option("--channels").map { Set($0.split(separator: ",").compactMap { Int($0) }) }
let outPath = option("--out")

let defaults = UserDefaults(suiteName: "io.github.rkoh46.Eufynized")
let env = ProcessInfo.processInfo.environment
let homeBaseIP = env["EUFY_HOMEBASE_IP"] ?? defaults?.string(forKey: "homeBaseIP") ?? ""
let stationSerial = env["EUFY_STATION_SERIAL"] ?? defaults?.string(forKey: "stationSerial") ?? ""
let email = env["EUFY_EMAIL"] ?? defaults?.string(forKey: "accountEmail") ?? ""

// MARK: Report

final class Report: @unchecked Sendable {
    private let lock = NSLock()
    private var stages: [[String: Any]] = []
    private var cameras: [[String: Any]] = []
    var station: [String: Any] = [:]
    var cloud: [String: Any]?
    let started = Date()

    func stage(_ name: String, ok: Bool, ms: Int? = nil, _ detail: String = "") {
        lock.withLock {
            var s: [String: Any] = ["name": name, "ok": ok, "detail": detail]
            if let ms { s["ms"] = ms }
            stages.append(s)
        }
        print("\(ok ? "PASS" : "FAIL")  \(name)\(ms.map { " (\($0) ms)" } ?? "")\(detail.isEmpty ? "" : " — \(detail)")")
    }

    func camera(_ c: [String: Any]) { lock.withLock { cameras.append(c) } }

    var failed: Bool { lock.withLock { stages.contains { $0["ok"] as? Bool == false } } }

    func json() -> Data {
        let all: [String: Any] = lock.withLock {
            var r: [String: Any] = [
                "schema": 1,
                "startedAt": ISO8601DateFormatter().string(from: started),
                "durationSeconds": Int(Date().timeIntervalSince(started)),
                "ok": !stages.contains { $0["ok"] as? Bool == false },
                "stages": stages, "station": station, "cameras": cameras,
            ]
            if let cloud { r["cloud"] = cloud }
            return r
        }
        return (try? JSONSerialization.data(withJSONObject: all, options: [.prettyPrinted, .sortedKeys])) ?? Data()
    }
}

let report = Report()
func finish() -> Never {
    let data = report.json()
    if let outPath { try? data.write(to: URL(fileURLWithPath: outPath)) } else { print(String(decoding: data, as: UTF8.self)) }
    exit(report.failed ? 1 : 0)
}
func ms(since start: Date) -> Int { Int(Date().timeIntervalSince(start) * 1000) }

// MARK: Setup (no Keychain)

guard !homeBaseIP.isEmpty, !stationSerial.isEmpty, !email.isEmpty else {
    print("Eufynized isn't set up (no HomeBase IP / station / account in its settings)."); exit(2)
}
report.station["serial"] = stationSerial
report.station["model"] = String(stationSerial.prefix(5))
let hasKey = CipherKeyCache().hasStoredKey(stationSerial: stationSerial)
let hasSession = EufySessionStore().hasStoredSession(email: email)
// The HomeBase needs the station key and the account id. The id comes from the cloud session when there is one,
// else from what the app remembered (it keeps the id apart from the session since 0.7.5, because eufy signs a
// session out whenever it's used from a second device). No session only means the cloud check is skipped.
let rememberedID = defaults?.string(forKey: "accountUserId:\(email.lowercased())")
let accountIDFound = EufySessionStore().load(email: email)?.accountUserId ?? rememberedID
report.stage("secrets", ok: hasKey && accountIDFound != nil,
             hasKey && accountIDFound != nil
                ? (hasSession ? "station key and session present" : "station key and account id present (no cloud session; cloud check skipped)")
                : "missing \(hasKey ? "" : "station key ")\(accountIDFound == nil ? "account id" : "") in secrets file — open Eufynized and sign in")
guard hasKey, let ecc = CipherKeyCache().eccPrivateKey(stationSerial: stationSerial), let accountID = accountIDFound else { finish() }

var catalog = CameraCatalogCache().load(email: email) ?? []
/// Wi-Fi signal per device from the cloud list (param 1142, dBm; -100 when the camera is off the network).
var wifiSignal: [String: Int] = [:]

// MARK: Cloud (optional): firmware versions and the catalog as the account sees it

if useCloud && hasSession {
    let start = Date()
    do {
        let client = EufyCloudClient(configuration: .init(email: email, countryCode: "US"))
        let devices = try await client.devices()
        report.cloud = ["devices": devices.sorted { $0.serial < $1.serial }.map { d -> [String: Any] in
            var e: [String: Any] = ["serial": d.serial, "model": d.model, "station": d.stationSerial]
            if let v = d.deviceType { e["deviceType"] = v }
            if let v = d.channel { e["channel"] = v }
            if let v = d.firmwareVersion { e["firmware"] = v }
            if let v = d.secondaryFirmwareVersion { e["firmware2"] = v }
            e["paramTypes"] = d.params.keys.sorted()
            if let rssi = d.params[1142].flatMap({ Int($0) }) { e["wifiSignal"] = rssi }
            return e
        }]
        for d in devices { if let rssi = d.params[1142].flatMap({ Int($0) }) { wifiSignal[d.serial] = rssi } }
        let station = devices.first { $0.serial == stationSerial }
        report.station["firmware"] = station?.firmwareVersion ?? NSNull()
        // Channels are what the live start addresses: a renumbering after an update would show the wrong camera.
        let cloudChannels = Dictionary(devices.compactMap { d in d.channel.map { (d.serial, $0) } }, uniquingKeysWith: { a, _ in a })
        let moved = catalog.filter { cam in cloudChannels[cam.serial].map { $0 != cam.channel } ?? false }
        report.stage("cloud device list", ok: moved.isEmpty, ms: ms(since: start),
                     moved.isEmpty ? "\(devices.count) devices, station firmware \(station?.firmwareVersion ?? "?")"
                                   : "channel changed for \(moved.map(\.name).joined(separator: ", ")) — refresh cameras in the app")
    } catch {
        report.stage("cloud device list", ok: false, ms: ms(since: start), "\(error.localizedDescription)")
    }
}

// MARK: Discovery

do {
    let start = Date()
    let found = try await HomeBaseDiscovery.find(knownAddress: homeBaseIP, timeout: 5)
    report.station["discovery"] = ["port": Int(found.port), "announcesDID": found.announcedDID != nil]
    report.stage("discovery", ok: true, ms: ms(since: start), "answered from \(found.host):\(found.port)")
} catch {
    report.stage("discovery", ok: false, "\(error.localizedDescription) — HomeBase unreachable at \(homeBaseIP)")
    finish()
}

// MARK: Cameras

guard !catalog.isEmpty else {
    report.stage("camera catalog", ok: false, "no cached cameras — open Eufynized and refresh"); finish()
}
catalog.sort { $0.channel < $1.channel }
var targets = catalog.filter { onlyChannels?.contains($0.channel) ?? true }
if quick {
    // Indoor (mains-powered) cameras first: streaming briefly costs them nothing.
    let mains: Set<String> = ["T8417", "T8419", "T8400", "T8410", "T8416"]
    targets = [targets.first { mains.contains(String($0.model.prefix(5))) || mains.contains(String($0.serial.prefix(5))) } ?? targets[0]]
}

final class Probe: @unchecked Sendable {
    let lock = NSLock()
    var session: VTDecompressionSession?
    var samples = 0, decoded = 0, decodeErrors = 0
    var firstSample: Date?
    var codec: String?
    var control: Set<String> = []
    var paramTypes: Set<Int> = []
    var state: CameraAvailability?

    func decode(_ sample: CMSampleBuffer) {
        lock.withLock {
            samples += 1
            if firstSample == nil { firstSample = Date() }
            guard let fmt = CMSampleBufferGetFormatDescription(sample) else { decodeErrors += 1; return }
            let sub = CMFormatDescriptionGetMediaSubType(fmt)
            codec = String(bytes: [24, 16, 8, 0].map { UInt8((sub >> $0) & 0xFF) }, encoding: .ascii)
            if let s = session, !VTDecompressionSessionCanAcceptFormatDescription(s, formatDescription: fmt) {
                VTDecompressionSessionInvalidate(s); session = nil
            }
            if session == nil {
                VTDecompressionSessionCreate(allocator: nil, formatDescription: fmt, decoderSpecification: nil,
                                             imageBufferAttributes: nil, outputCallback: nil, decompressionSessionOut: &session)
            }
            guard let session else { decodeErrors += 1; return }
            var ok = false
            let status = VTDecompressionSessionDecodeFrame(session, sampleBuffer: sample, flags: [], infoFlagsOut: nil) { st, _, image, _, _ in
                ok = st == noErr && image != nil
            }
            if status == noErr && ok { decoded += 1 } else { decodeErrors += 1 }
        }
    }

    func invalidate() { lock.withLock { if let s = session { VTDecompressionSessionInvalidate(s) }; session = nil } }
}

/// `key=value` pairs out of a diagnostics string like "gateway=true level2=true videoFrames=12 size=1920x1080".
func fields(_ text: String) -> [String: String] {
    Dictionary(text.split(separator: " ").compactMap { part -> (String, String)? in
        let kv = part.split(separator: "=", maxSplits: 1)
        return kv.count == 2 ? (String(kv[0]), String(kv[1])) : nil
    }, uniquingKeysWith: { a, _ in a })
}

for (index, camera) in targets.enumerated() {
    if index > 0 { try? await Task.sleep(for: .seconds(2)) }   // let the HomeBase close the previous session
    let probe = Probe()
    let failure = NSLock()
    nonisolated(unsafe) var failedState: String?
    let channel = UInt8(camera.channel)
    let stream = EufyLiveStream(
        config: .init(homeBaseIP: homeBaseIP, channel: channel,
                      level2: .init(stationSerial: stationSerial, accountID: accountID, eccPrivateKeyHex: ecc), audio: true),
        onSample: { probe.decode($0) },
        onState: { state in if case .failed(let m) = state { failure.withLock { failedState = m } } })
    stream.onControlFrameDetail = { [weak stream] frame in
        guard let stream else { return }
        probe.lock.withLock { _ = probe.control.insert("\(frame.command ?? 0):\(frame.signCode)") }
        guard frame.channel == channel, let plain = stream.decryptControlFrame(frame.body, signCode: frame.signCode) else { return }
        let text = String(decoding: plain.prefix { $0 != 0 }, as: UTF8.self)
        guard text.hasPrefix("{"), let dict = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any] else { return }
        let list = (dict["params"] ?? (dict["payload"] as? [String: Any])?["params"]) as? [[String: Any]] ?? []
        probe.lock.withLock { for e in list { if let k = (e["param_type"] as? NSNumber)?.intValue { probe.paramTypes.insert(k) } } }
    }

    stream.onAvailability = { state in probe.lock.withLock { probe.state = state } }
    let start = Date()
    stream.start()
    var askedInfo = false
    while Date().timeIntervalSince(start) < seconds {
        try? await Task.sleep(for: .milliseconds(250))
        if failure.withLock({ failedState }) != nil { break }
        if !askedInfo, probe.lock.withLock({ probe.decoded }) > 0 { stream.requestCameraInfo(level2: true); askedInfo = true }
    }
    if !askedInfo { stream.requestCameraInfo(level2: true) }
    try? await Task.sleep(for: .seconds(2))   // the settings reply
    let video = fields(stream.videoDiagnostics)
    let audio = fields(stream.audioDiagnostics)
    stream.stop()
    probe.invalidate()

    let (samples, decoded, errors, first, codec, control, params, state) = probe.lock.withLock {
        (probe.samples, probe.decoded, probe.decodeErrors, probe.firstSample, probe.codec, probe.control, probe.paramTypes, probe.state)
    }
    let level2 = video["level2"] == "true"
    let audioFrames = Int(audio["parsed"] ?? audio["fed"] ?? "0") ?? 0
    var problems: [String] = []
    // Nothing at all from a camera its HomeBase reports offline / switched off (param 1131), or that the
    // cloud says has no Wi-Fi: that's the camera, not a protocol break.
    let offline = samples == 0 && audioFrames == 0 &&
        ((state.map { !$0.canStream } ?? false) || (wifiSignal[camera.serial] ?? 0) <= -95)

    if let m = failure.withLock({ failedState }) { problems.append("stream failed: \(m)") }
    if video["gateway"] != "true" { problems.append("no gateway-info reply (1100)") }
    if !level2 { problems.append("no level-2 key — would fall back to level-1 and show the wrong camera") }
    if decoded == 0 && !offline { problems.append("no decodable video in \(Int(seconds))s") }
    if samples > 0 && errors * 4 > samples { problems.append("\(errors)/\(samples) frames failed to decode") }
    if (Int(video["decryptFail"] ?? "0") ?? 0) > 0 && decoded == 0 { problems.append("video decryption fails") }

    var entry: [String: Any] = [
        "serial": camera.serial, "name": camera.name, "model": camera.model, "channel": camera.channel,
        "ok": problems.isEmpty, "problems": problems, "offline": offline, "state": state?.title ?? "unknown",
        "gateway": video["gateway"] == "true", "level2": level2,
        "samples": samples, "decoded": decoded, "decodeErrors": errors,
        "keyframes": Int(video["keyframes"] ?? "0") ?? 0, "size": video["size"] ?? "-",
        "formatChanges": Int(video["formatChanges"] ?? "0") ?? 0, "decryptFail": Int(video["decryptFail"] ?? "0") ?? 0,
        "audioFrames": audioFrames, "codec": codec ?? "-",
        "controlFrames": control.sorted(), "paramTypes": params.sorted(),
    ]
    if let first { entry["firstFrameMs"] = Int(first.timeIntervalSince(start) * 1000) }
    report.camera(entry)
    let summary = offline && problems.isEmpty
        ? "\((state.map { $0.canStream ? nil : $0.title } ?? nil) ?? "Offline") (reported by the HomeBase) — sent nothing. \(state?.advice ?? "")"
        : problems.isEmpty
        ? "\(codec ?? "?") \(video["size"] ?? "-"), \(decoded) frames decoded, first after \(entry["firstFrameMs"] ?? "-") ms, audio \(audioFrames), \(params.count) settings"
        : problems.joined(separator: "; ")
    report.stage("camera ch\(camera.channel) \(camera.name)", ok: problems.isEmpty, ms: ms(since: start), summary)
}

finish()
