import Foundation
import EufyKit

// Opens a direct P2P session with your HomeBase and holds it open to confirm the keepalive works.
// Uses the session saved by `eufynized-login`, and caches the station info so repeated runs don't hit
// the cloud. Pass --refresh to re-fetch the device list.
//   swift run eufynized-connect <email> [country] [--refresh]

let flags = Set(CommandLine.arguments.filter { $0.hasPrefix("--") })
let args = CommandLine.arguments.dropFirst().filter { !$0.hasPrefix("--") }

// --local: connect purely over the LAN, learning the HomeBase's DID from its own reply. No cloud, no
// account — the HomeBase just has to be on the same network.
if flags.contains("--local") {
    do {
        let connection = try HomeBaseConnection(config: .init(
            stationSerial: "local", p2pDID: nil, knownAddress: args.first))
        let reported = NSLock()
        nonisolated(unsafe) var savedKeyframe = false
        connection.onFrame { kind, cmd, _, body in
            if cmd == 1300, let header = VideoFrameHeader(body) {
                FileHandle.standardError.write(Data("[video] \(header.resolution) keyframe=\(header.keyframe) frameBytes=\(body.count) declaredLen=\(header.payloadLength)\n".utf8))
                if header.keyframe {
                    let save = reported.withLock { if savedKeyframe { return false }; savedKeyframe = true; return true }
                    if save {
                        try? body.write(to: URL(fileURLWithPath: "/tmp/eufy-keyframe.bin"))
                        FileHandle.standardError.write(Data("[video] saved keyframe (\(body.count) bytes) to /tmp/eufy-keyframe.bin\n".utf8))
                    }
                }
            }
        }
        print("Opening a direct session over the LAN (no cloud, no account)…")
        let peer = try await connection.connect()
        print("Connected to \(peer.host):\(peer.port) as \(connection.connectedDID ?? "?") in \(String(format: "%.2f", peer.elapsed))s")

        // Prove the command channel: ask the HomeBase for its gateway info (cloud-free control command).
        print("Sending gateway-info command…")
        connection.sendCommand(1100)    // CMD_GATEWAYINFO
        try await Task.sleep(for: .seconds(3))
        print("Frames received so far: \(connection.frameCounts())")

        // Try to start realtime video on the given camera channel (default 0), level-1, and watch for frames.
        let channel = UInt8(args.dropFirst().first.flatMap { Int($0) } ?? 0)
        print("Requesting realtime video on channel \(channel)…")
        connection.sendCommand(1003, channel: channel)   // CMD_START_REALTIME_MEDIA
        for i in 0..<4 {
            try await Task.sleep(for: .seconds(3))
            let counts = connection.frameCounts()
            let video = counts[.video] ?? 0
            print("  [\(3 * (i + 1))s] frames=\(counts) video=\(video)")
        }
        connection.close()
        print("Closed. (See [frame] lines for what the HomeBase sent.)")
    } catch {
        print("error: \(error.localizedDescription)")
        exit(1)
    }
    exit(0)
}

guard let email = args.first, email.contains("@") else {
    print("usage: eufynized-connect <email> [country] [--refresh]   or   eufynized-connect [lan-ip] --local")
    exit(2)
}
let country = args.dropFirst().first ?? "US"
let cache = StationCache()

func stations() async throws -> [StationInfo] {
    if !flags.contains("--refresh"), let cached = cache.load(email: email), !cached.isEmpty {
        return cached
    }
    let client = EufyCloudClient(configuration: .init(email: email, countryCode: country))
    guard await client.isSignedIn else {
        print("Not signed in. Run eufynized-login \(email) first.")
        exit(1)
    }
    let found = try await client.devices()
        .filter { $0.isStation }
        .compactMap { device -> StationInfo? in
            guard let did = device.p2pDID else { return nil }
            return StationInfo(serial: device.serial, name: device.name,
                               model: device.productName ?? device.model, p2pDID: did, localIP: device.localIP)
        }
    cache.save(found, email: email)
    return found
}

do {
    guard let station = try await stations().first else {
        print("No HomeBase with a P2P id found on the account.")
        exit(1)
    }
    print("HomeBase: \(station.name) [\(station.model)]")

    let connection = try HomeBaseConnection(config: .init(
        stationSerial: station.serial, p2pDID: station.p2pDID, knownAddress: station.localIP))
    print("Opening a direct session (no cloud)…")
    let peer = try await connection.connect()
    print("Connected to \(peer.host):\(peer.port) in \(String(format: "%.2f", peer.elapsed))s")

    for _ in 0..<4 {
        try await Task.sleep(for: .seconds(5))
        if let last = connection.lastContact {
            print("  holding — last reply \(String(format: "%.1f", -last.timeIntervalSinceNow))s ago")
        }
    }
    connection.close()
    print("Closed cleanly. Direct HomeBase session works.")
} catch {
    print("error: \(error.localizedDescription)")
    exit(1)
}
