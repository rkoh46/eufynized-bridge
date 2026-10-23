import Foundation
import EufyKit
import AppKit

// Connects to the HomeBase over the LAN, requests a camera's video, decodes the first keyframe, and saves
// it as a PNG — the full pipeline end to end, no cloud, no account.
//   swift run eufynized-snapshot [lan-ip] [channel] [out.png]
// Or decode a previously captured elementary stream:
//   swift run eufynized-snapshot --file /tmp/eufy-keyframe.h265 out.png

func savePNG(_ image: CGImage, to path: String) {
    let rep = NSBitmapImageRep(cgImage: image)
    if let data = rep.representation(using: .png, properties: [:]) {
        try? data.write(to: URL(fileURLWithPath: path))
        print("Saved \(image.width)x\(image.height) PNG to \(path)")
    } else {
        print("Could not encode PNG")
    }
}

let args = Array(CommandLine.arguments.dropFirst())

if args.first == "--file" {
    let esPath = args.count > 1 ? args[1] : "/tmp/eufy-keyframe.h265"
    let out = args.count > 2 ? args[2] : "/tmp/eufy-snapshot.png"
    let es = try Data(contentsOf: URL(fileURLWithPath: esPath))
    if let image = try HEVCDecoder().decode(annexB: es) {
        savePNG(image, to: out)
    } else {
        print("Decoder produced no image from \(esPath)")
        exit(1)
    }
    exit(0)
}

let ip = args.first ?? "192.168.1.50"
let channel = UInt8(args.dropFirst().first.flatMap { Int($0) } ?? 0)
let out = args.dropFirst(2).first ?? "/tmp/eufy-snapshot.png"

let decoder = HEVCDecoder()
let done = DispatchSemaphore(value: 0)
nonisolated(unsafe) var saved = false

do {
    let connection = try HomeBaseConnection(config: .init(stationSerial: "snap", p2pDID: nil, knownAddress: ip))
    connection.onFrame { _, cmd, _, body in
        guard cmd == 1300, !saved, let header = VideoFrameHeader(body), header.keyframe else { return }
        let es = body.dropFirst(0x16)   // strip the 22-byte frame header → H.265 Annex-B
        if let image = (try? decoder.decode(annexB: Data(es))) ?? nil {
            saved = true
            savePNG(image, to: out)
            done.signal()
        }
    }
    print("Connecting to \(ip) and requesting channel \(channel)…")
    let peer = try await connection.connect()
    print("Connected to \(peer.host):\(peer.port). Starting video…")
    if ProcessInfo.processInfo.environment["USE_STARTLIVE"] != nil {
        connection.startLive(channel: channel)        // mChannel camera selection
    } else {
        connection.sendCommand(1003, channel: channel)   // CMD_START_REALTIME_MEDIA
    }

    if done.wait(timeout: .now() + 15) == .timedOut {
        print("No keyframe decoded within 15s.")
        connection.close()
        exit(1)
    }
    connection.close()
} catch {
    print("error: \(error.localizedDescription)")
    exit(1)
}
