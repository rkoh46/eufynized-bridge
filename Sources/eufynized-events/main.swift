import Foundation
import EufyKit

// Reads the HomeBase's own event history and downloads clips over the direct P2P session. Read-only.
//   eufynized-events <station-serial> <homebase-ip> <email> raw <cmd[:mValue3]@channel@payload-json>…
//     (sends each as a level-2 SET_PAYLOAD and logs every reply; `$RSA` becomes our RSA modulus.
//      GAP=seconds between commands; DUMP=prefix saves decrypted replies and the clip's video as files)
//   eufynized-events <station-serial> <homebase-ip> <email> list [days]
//   eufynized-events <station-serial> <homebase-ip> <email> download <channel> <storage_path> [out.mp4]

let args = Array(CommandLine.arguments.dropFirst())
guard args.count >= 4 else { print("usage: eufynized-events <station-serial> <homebase-ip> <email> raw|list|download …"); exit(2) }
let serial = args[0], ip = args[1], email = args[2], mode = args[3]

guard let ecc = CipherKeyCache().eccPrivateKey(stationSerial: serial),
      let accountID = EufySessionStore().load(email: email)?.accountUserId else {
    print("No cached key/session. Run setup in the app first."); exit(1)
}
let context = EufyLiveStream.Level2Context(stationSerial: serial, accountID: accountID, eccPrivateKeyHex: ecc)
let cameras = CameraCatalogCache().load(email: email) ?? []

@Sendable func printable(_ d: Data) -> String { String(decoding: d.map { (32...126).contains($0) ? $0 : 46 }, as: UTF8.self) }

switch mode {
case "raw":
    let session = try HomeBaseSession(homeBaseIP: ip, context: context)
    let rsa = EufyRSA()!
    let decoder = Level2VideoDecoder(rsa: rsa)
    let dump = ProcessInfo.processInfo.environment["DUMP"]
    let es = dump.flatMap { path in
        FileManager.default.createFile(atPath: path + ".es", contents: nil) ? FileHandle(forWritingAtPath: path + ".es") : nil
    }
    nonisolated(unsafe) var media = 0
    session.addFrameHandler { kind, cmd, sign, body in
        if cmd == 1300 || cmd == 1301 {
            media += 1
            if media <= 5 || media % 100 == 0 {
                print("<- media #\(media) kind=\(kind) cmd=\(cmd!) sign=\(sign) len=\(body.count) head=" + body.prefix(40).map { String(format: "%02x", $0) }.joined())
            }
            if cmd == 1300, let annexB = decoder.decode(body, signCode: sign) { es?.write(annexB) }
            return
        }
        let plain = session.decryptControl(body, signCode: sign)
        if let dump {
            try? plain.write(to: URL(fileURLWithPath: "\(dump)-\(cmd ?? 0)-\(Int(Date().timeIntervalSince1970 * 1000)).bin"))
        }
        print("<- kind=\(kind) cmd=\(cmd.map(String.init) ?? "-") sign=\(sign) len=\(body.count): \(printable(plain.prefix(3000)))")
        if body.count < 200 { print("   hex " + body.map { String(format: "%02x", $0) }.joined()) }
    }
    try await session.open()
    print("open; level2 ok")
    // Each argument after the mode is `cmd[:mValue3]@channel@payload-json`, sent a few seconds apart.
    for spec in args.dropFirst(4) {
        let parts = spec.replacingOccurrences(of: "$RSA", with: rsa.modulusHex.uppercased())
            .split(separator: "@", maxSplits: 2).map(String.init)
        let ids = parts.first?.split(separator: ":").compactMap { Int($0) } ?? []
        guard parts.count == 3, let cmd = ids.first, let ch = UInt8(parts[1]) else { continue }
        print("-> cmd=\(cmd) ch=\(ch) \(parts[2].prefix(160))")
        session.sendSetPayload(cmd: cmd, channel: ch, mValue3: ids.count > 1 ? ids[1] : 0, payloadJSON: parts[2])
        try await Task.sleep(for: .seconds(Double(ProcessInfo.processInfo.environment["GAP"] ?? "5") ?? 5))
    }
    session.close()

case "list":
    let days = args.count > 4 ? Int(args[4]) ?? 2 : 2
    let reader = HomeBaseRecordings(homeBaseIP: ip, context: context)
    let end = Date(), start = Calendar.current.date(byAdding: .day, value: -days, to: end)!
    let events = try await reader.events(cameraSerials: cameras.map(\.serial), from: start, to: end)
    for e in events.prefix(Int(ProcessInfo.processInfo.environment["SHOW"] ?? "20") ?? 20) {
        let name = cameras.first { $0.serial == e.deviceSerial }?.name ?? e.deviceSerial
        print("\(e.startTime) \(Int(e.duration))s  ch\(e.channel ?? -1) \(name) [\(e.kindLabel)] id=\(e.recordID) \(e.storagePath)")
    }
    print("\(events.count) events over \(days + 1) days")
    // Fetch a few snapshots in a row, to check the HomeBase keeps answering.
    for (i, e) in events.prefix(Int(ProcessInfo.processInfo.environment["THUMBS"] ?? "3") ?? 3).enumerated() {
        guard let thumb = e.thumbnailPath else { continue }
        let t0 = Date()
        let data = try await reader.image(path: thumb)
        let out = URL(fileURLWithPath: "thumb\(i).jpg")
        try data.write(to: out)
        print(String(format: "snapshot %d: %d bytes in %.2fs → %@", i, data.count, Date().timeIntervalSince(t0), out.path))
    }
    await reader.close()

case "download":
    guard args.count >= 6, let ch = UInt8(args[4]) else { print("download <channel> <path> [out]"); exit(2) }
    let out = URL(fileURLWithPath: args.count > 6 ? args[6] : "clip.mp4")
    let reader = HomeBaseRecordings(homeBaseIP: ip, context: context)
    let started = Date()
    let clip = try await reader.downloadClip(channel: ch, storagePath: args[5]) { frames, bytes in
        if frames % 100 == 0 { print("  \(frames) frames, \(bytes / 1024) KB") }
    }
    let fetched = Date().timeIntervalSince(started)
    try await clip.writeMP4(to: out)
    print(String(format: "clip: %d video frames (%d keyframes), %d audio frames, %.1fs of video; fetched in %.1fs → %@",
                 clip.videoFrames, clip.keyframes, clip.audio.count, clip.duration, fetched, out.path))
    await reader.close()

default:
    print("unknown mode \(mode)"); exit(2)
}
