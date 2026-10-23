import Foundation
import EufyKit

// Reads a camera's settings straight from its HomeBase (no cloud) and decodes them with the catalog; with
// --verify, proves which writes work: for each low-risk setting it writes a different value, reads it back,
// restores the original and reads again. Paste the "verified" line into CameraSettingsVerified.swift.
//   eufynized-settings <station-serial> <channel> <homebase-ip> <email> <device-type> [--verify]

setvbuf(stdout, nil, _IONBF, 0)   // unbuffered: if a run is cut short, every step it took is still on screen
let args = Array(CommandLine.arguments.dropFirst())
guard args.count >= 5, let deviceType = Int(args[4]) else {
    print("usage: eufynized-settings <station-serial> <channel> <homebase-ip> <email> <device-type> [--verify]"); exit(2)
}
let serial = args[0], ip = args[2], email = args[3]
let channel = UInt8(Int(args[1]) ?? 0)
let verify = args.contains("--verify")
guard let ecc = CipherKeyCache().eccPrivateKey(stationSerial: serial),
      let accountID = EufySessionStore().load(email: email)?.accountUserId else { print("No stored key/session."); exit(1) }

var streamConfig = EufyLiveStream.Config(homeBaseIP: ip, channel: channel,
    level2: .init(stationSerial: serial, accountID: accountID, eccPrivateKeyHex: ecc), audio: false)
streamConfig.video = !args.contains("--control-only")   // what the app's settings sheet uses
let stream = EufyLiveStream(config: streamConfig, onSample: { _ in })
// --snapshot=<path>: fetch one snapshot from the HomeBase's disk (as a banner does) and report its size.
if let path = args.first(where: { $0.hasPrefix("--snapshot=") })?.dropFirst(11) {
    let recordings = HomeBaseRecordings(homeBaseIP: ip, context: .init(stationSerial: serial, accountID: accountID, eccPrivateKeyHex: ecc))
    do {
        let jpeg = try await recordings.image(path: String(path))
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("eufynized-snapshot.jpg")
        try jpeg.write(to: out)
        print("snapshot: \(jpeg.count) bytes, JPEG \(jpeg.prefix(2) == Data([0xFF, 0xD8])) → \(out.path)")
    } catch { print("snapshot failed: \(error.localizedDescription)") }
    await recordings.close(); exit(0)
}

// --watch=<seconds>: run the app's event watcher (one quiet session, reconnects) and print each event.
if let watch = args.first(where: { $0.hasPrefix("--watch=") }).flatMap({ Int($0.dropFirst(8)) }) {
    let watcher = HomeBaseEventWatcher(homeBaseIP: ip, context: .init(stationSerial: serial, accountID: accountID, eccPrivateKeyHex: ecc))
    let started = Date()
    watcher.start(onEvent: { e in
        print(String(format: "%6.1fs", Date().timeIntervalSince(started)),
              "EVENT \(e.title) [\(e.eventType)] \(e.cameraName) ch\(e.channel) at \(e.triggerTime) snapshot=\(e.snapshotPath ?? "-")")
    }, onStatus: { print(String(format: "%6.1fs", Date().timeIntervalSince(started)), "status \($0)") })
    try await Task.sleep(for: .seconds(watch))
    watcher.stop(); exit(0)
}

// --listen=<seconds>: log every frame the HomeBase volunteers on this session, decrypted (does it announce
// motion over the LAN?). Lives here rather than in its own tool: each new binary needs its own macOS
// Local Network permission before it can reach the HomeBase.
if let listen = args.first(where: { $0.hasPrefix("--listen=") }).flatMap({ Int($0.dropFirst(9)) }) {
    let started = Date()
    stream.onControlFrameDetail = { [weak stream] frame in
        guard let stream, let cmd = frame.command, cmd != 1139 else { return }
        let t = String(format: "%6.1fs %@", Date().timeIntervalSince(started), ISO8601DateFormatter().string(from: Date()))
        guard let plain = stream.decryptControlFrame(frame.body, signCode: frame.signCode) else {
            print("\(t) ch\(frame.channel) cmd=\(cmd) sign=\(frame.signCode) len=\(frame.body.count) (sealed)"); return
        }
        let text = String(decoding: plain.prefix { $0 != 0 }, as: UTF8.self)
        let shown = text.hasPrefix("{") || text.hasPrefix("[") ? "json \(text.prefix(400))"
            : "bin \(plain.prefix(24).map { String(format: "%02x", $0) }.joined())"
        print("\(t) ch\(frame.channel) cmd=\(cmd) \(shown)")
    }
    stream.start()
    try await Task.sleep(for: .seconds(listen))
    stream.stop(); exit(0)
}

stream.start()
try await Task.sleep(for: .seconds(6))

func read() async -> [Int: String]? {
    for _ in 0..<3 { if let p = await stream.readSettings() { return p } }
    return nil
}
guard let params = await read() else { print("No settings reply from the HomeBase."); stream.stop(); exit(1) }
let settings = CameraSettingsCatalog.settings(forDeviceType: deviceType)
print("\(settings.count) catalogued settings, \(params.count) params reported")
if args.contains("--raw") {   // JSON of every param, to compare against a saved snapshot
    let raw = Dictionary(uniqueKeysWithValues: params.map { ("\($0)", $1) })
    print("RAW " + String(decoding: try JSONSerialization.data(withJSONObject: raw, options: [.sortedKeys]), as: UTF8.self))
    stream.stop(); exit(0)
}
for group in CameraSettingsCatalog.groupOrder {
    let inGroup = settings.filter { $0.group == group }
    guard !inGroup.isEmpty else { continue }
    print("[\(group)]")
    for s in inGroup {
        let v = CameraSettingsCatalog.value(of: s, in: params, deviceType: deviceType)
        print("  \(s.label): \(v.map { "\($0)" } ?? "—")\(s.writable ? "" : " (read-only)")")
    }
}

// --restore=<file>: put every recipe-writable setting back to the values in a saved params snapshot
// (JSON {"param_type": "value"}), confirming each by reading it back.
if let restorePath = args.first(where: { $0.hasPrefix("--restore=") })?.dropFirst(10),
   let data = FileManager.default.contents(atPath: String(restorePath)),
   let saved = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
    let snapshot = Dictionary(uniqueKeysWithValues: saved.compactMap { k, v in Int(k).map { ($0, "\(v)") } })
    var current = params
    for s in settings where CameraSettingsCatalog.recipe(for: s, deviceType: deviceType) != nil && !CameraSettingsCatalog.isPacked(s) {
        guard let want = CameraSettingsCatalog.value(of: s, in: snapshot, deviceType: deviceType)?.intValue else { continue }
        var have = CameraSettingsCatalog.value(of: s, in: current, deviceType: deviceType)?.intValue
        var tries = 0
        while have != want && tries < 4 {
            tries += 1
            print("restore \(s.id): \(have.map(String.init) ?? "unknown") → \(want) (try \(tries))")
            await stream.writeSetting(s, deviceType: deviceType, value: want)
            try await Task.sleep(for: .seconds(2 + tries))
            if let fresh = await read() { current = fresh }
            have = CameraSettingsCatalog.value(of: s, in: current, deviceType: deviceType)?.intValue
        }
        print("\(have == want ? "ok  " : "⚠️  ") \(s.id) = \(have.map(String.init) ?? "unknown") (want \(want))")
    }
    stream.stop(); exit(0)
}

// --set-raw=<1298|6027>:<value>: put a packed param back to an exact raw value, and read it back.
if let set = args.first(where: { $0.hasPrefix("--set-raw=") })?.dropFirst(10).split(separator: ":"), set.count == 2,
   let key = Int(set[0]), let v = Int(set[1]) {
    for attempt in 1...4 {
        let sent = await stream.restorePackedRaw(key: key, value: v)
        try await Task.sleep(for: .seconds(2 + attempt))
        let now = await read()?[key]
        print("set-raw \(key) = \(v): sent \(sent), reads \(now ?? "unknown")")
        if now == String(v) { break }
    }
    stream.stop(); exit(0)
}

// --set=<settingId>:<value>: write one setting with its recipe and read it back (used to repair a camera).
if let set = args.first(where: { $0.hasPrefix("--set=") })?.dropFirst(6).split(separator: ":"), set.count == 2,
   let s = settings.first(where: { $0.id == set[0] }), let v = Int(set[1]) {
    for attempt in 1...4 {
        let sent = await stream.writeSetting(s, deviceType: deviceType, value: v)
        try await Task.sleep(for: .seconds(2 + attempt))
        let now = await read().flatMap { CameraSettingsCatalog.value(of: s, in: $0, deviceType: deviceType)?.intValue }
        print("set \(s.id) = \(v): sent \(sent), reads \(now.map(String.init) ?? "unknown")")
        if now == v { break }
    }
    stream.stop(); exit(0)
}

// --locked: every setting the app shows for this camera that isn't editable, and why.
if args.contains("--locked") {
    let verified = CameraSettingsCatalog.verifiedWrites[deviceType] ?? []
    for s in settings {
        guard let v = CameraSettingsCatalog.value(of: s, in: params, deviceType: deviceType) else { continue }
        if CameraSettingsCatalog.isStatus(s, deviceType: deviceType) { print("STATUS \(s.label) = \(v)"); continue }
        if !CameraSettingsCatalog.isEditable(s, deviceType: deviceType) { print("LOCKED \(s.id) [\(s.label)] = \(v)"); continue }
        if !verified.contains(s.id) { print("EDITABLE-UNTESTED \(s.id) [\(s.label)]") }
    }
    stream.stop(); exit(0)
}

guard verify else { stream.stop(); exit(0) }

// Low-risk only: nothing that turns the camera off, changes power/storage/RTSP, sounds an alarm, lights the
// spotlight, or moves the camera. Packed settings (shared bits) are left for a dedicated test.
let excluded: Set<String> = ["enabled", "rtspStream", "powerSource", "powerWorkingMode", "continuousRecording",
                             "continuousRecordingType", "videoTypeStoreToNAS", "autoCalibration", "motionAutoCruise",
                             "motionTracking", "soundDetectionRoundLook", "light", "lightSettingsEnable",
                             "antitheftDetection", "dualCamWatchViewMode", "videoStreamingQuality"]
let only = args.first { $0.hasPrefix("--only=") }.map { Set($0.dropFirst(7).split(separator: ",").map(String.init)) }
func alternative(for s: CameraSetting, current: Int) -> Int? {
    if CameraSettingsCatalog.isPacked(s) { return current == 0 ? 1 : 0 }
    if let supported = CameraSettingsCatalog.recipe(for: s, deviceType: deviceType)?.supportedValues {
        return supported.first { $0 != current }
    }
    switch s.kind {
    case .toggle: return current == 0 ? 1 : 0
    case .choice(let options): return options.map(\.value).first { $0 != current }
    case .number(let min, let max, _, _):
        guard let min, let max else { return nil }
        return current == Int(min) ? Int(min) + 1 : Int(min) <= Int(max) ? Int(min) : nil
    case .text: return nil
    }
}

let candidates = settings.filter { s in
    s.writable && (only?.contains(s.id) ?? !excluded.contains(s.id))
        && (CameraSettingsCatalog.isPacked(s) || CameraSettingsCatalog.recipe(for: s, deviceType: deviceType) != nil)
}
// Packed params' exact raw values, so the sweep can put them back byte-for-byte (a packed write can change the
// encoding of an unchanged meaning, e.g. "all notifications off" stored as 40 vs 800).
let originalPackedRaw = Dictionary(uniqueKeysWithValues: Set(candidates.filter(CameraSettingsCatalog.isPacked).map(\.key))
    .compactMap { key in params[key].flatMap(Int.init).map { (key, $0) } })
// Snapshot first: whatever happens below, the final sweep puts every one of these back.
let original = Dictionary(uniqueKeysWithValues: candidates.compactMap { s in
    CameraSettingsCatalog.value(of: s, in: params, deviceType: deviceType)?.intValue.map { (s.id, $0) }
})

func value(_ s: CameraSetting) async -> Int? {
    await read().flatMap { CameraSettingsCatalog.value(of: s, in: $0, deviceType: deviceType)?.intValue }
}

var verified: [String] = []
var failedReads = 0
for s in candidates {
    // Two read-backs in a row failed: the HomeBase isn't answering reliably, so stop changing things and
    // go straight to the restore sweep rather than testing blind.
    if failedReads >= 2 { print("stopping: the HomeBase stopped answering reads"); break }
    guard let before = original[s.id], let target = alternative(for: s, current: before) else {
        print("skip \(s.id): no current value or no alternative"); continue
    }
    guard await stream.writeSetting(s, deviceType: deviceType, value: target) else {
        print("skip \(s.id): no frames for \(target)"); continue
    }
    try await Task.sleep(for: .seconds(2))
    let after = await value(s)
    failedReads = after == nil ? failedReads + 1 : 0
    var restored: Int?
    for attempt in 0..<4 where restored != before {
        await stream.writeSetting(s, deviceType: deviceType, value: before)
        try await Task.sleep(for: .seconds(2 + attempt * 2))
        restored = await value(s)
    }
    let ok = after == target && restored == before
    if ok { verified.append(s.id) }
    print("\(ok ? "OK  " : "FAIL") \(s.id): \(before) → wrote \(target), read \(after.map(String.init) ?? "nil"); restored \(restored.map(String.init) ?? "nil")")
}

// Final sweep: compare every tested setting with its original and re-apply any that differ.
if let now = await read() {
    for s in candidates {
        guard let want = original[s.id] else { continue }
        let have = CameraSettingsCatalog.value(of: s, in: now, deviceType: deviceType)?.intValue
        if have != want {
            print("sweep: \(s.id) is \(have.map(String.init) ?? "unknown"), restoring \(want)")
            await stream.writeSetting(s, deviceType: deviceType, value: want)
        }
    }
    for (key, raw) in originalPackedRaw where now[key] != String(raw) {
        print("sweep: packed \(key) is \(now[key] ?? "unknown"), restoring \(raw)")
        await stream.restorePackedRaw(key: key, value: raw)
    }
    print("sweep done")
} else {
    print("⚠️ sweep: couldn't read settings; originals were \(original)")
}
print("verified[\(deviceType)] = [\(verified.map { "\"\($0)\"" }.joined(separator: ", "))]")
stream.stop()
