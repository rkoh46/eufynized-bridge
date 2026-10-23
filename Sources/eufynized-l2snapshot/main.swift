import Foundation
import EufyKit
import AppKit

// Selects a specific camera with the level-2 media start, decodes the (encrypted) video, saves a PNG.
//   swift run eufynized-l2snapshot <station-serial> <channel> <homebase-ip> [out.png] [accountID]
// Uses the ECC key cached by eufynized-cipher.

let args = Array(CommandLine.arguments.dropFirst())
guard args.count >= 3 else {
    print("usage: eufynized-l2snapshot <station-serial> <channel> <homebase-ip> [out.png] [accountID]")
    exit(2)
}
let stationSerial = args[0]
let channel = UInt8(Int(args[1]) ?? 0)
let ip = args[2]
let out = args.count > 3 ? args[3] : "/tmp/eufy-l2.png"
// arg 5: a literal account id, or an email to load the account id from the cached session.
var accountID = args.count > 4 ? args[4] : ""
if accountID.contains("@") {
    let client = EufyCloudClient(configuration: .init(email: accountID, countryCode: "US"))
    accountID = await client.accountUserID ?? ""
    print("account_id from session: \(accountID.isEmpty ? "(none)" : accountID)")
}

guard let ecc = CipherKeyCache().eccPrivateKey(stationSerial: stationSerial) else {
    print("No cached ECC key for \(stationSerial). Run eufynized-cipher first.")
    exit(1)
}
guard let rsa = EufyRSA() else { print("RSA keygen failed."); exit(1) }

let box = NSLock()
nonisolated(unsafe) var rawGateway: Data?
nonisolated(unsafe) var saved = false
let decoder = HEVCDecoder()
let l2 = Level2VideoDecoder(rsa: rsa)
let done = DispatchSemaphore(value: 0)

do {
    let connection = try HomeBaseConnection(config: .init(stationSerial: stationSerial, p2pDID: nil, knownAddress: ip))
    connection.onFrame { kind, cmd, signCode, body in
        if cmd == 1100 { box.withLock { if rawGateway == nil { rawGateway = body } }; return }
        if ProcessInfo.processInfo.environment["EUFY_DEBUG"] != nil, let cmd {
            var note = "[frame] kind=\(kind) cmd=\(cmd) signCode=\(signCode) len=\(body.count)"
            if cmd == 1350 {
                let text = String(decoding: body.prefix(132), as: UTF8.self).filter { $0.isASCII && !$0.isNewline }
                note += " text=\(text.prefix(120)) hex=\(body.prefix(24).map { String(format: "%02x", $0) }.joined())"
            }
            FileHandle.standardError.write(Data((note + "\n").utf8))
        }
        guard cmd == 1300, !saved, let es = l2.decode(body, signCode: signCode) else { return }
        if ProcessInfo.processInfo.environment["DUMP_ES"] != nil, signCode == 1 {
            try? es.write(to: URL(fileURLWithPath: "/tmp/eufy-es-dump.h26x"))
            FileHandle.standardError.write(Data("[es] dumped \(es.count) bytes, first=\(es.prefix(8).map { String(format: "%02x", $0) }.joined())\n".utf8))
        }
        // es is the H.265 Annex-B after the 22-byte header (decrypted if it was level-2).
        if let image = (try? decoder.decode(annexB: es)) ?? nil {
            saved = true
            let rep = NSBitmapImageRep(cgImage: image)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: out))
            print("Saved \(image.width)x\(image.height) → \(out)")
            done.signal()
        }
    }

    print("Connecting…")
    _ = try await connection.connect()
    guard let did = connection.connectedDID,
          let level1Key = PPPPMessage.commandKey(stationSerial: stationSerial, p2pDID: did) else {
        print("level-1 key failed"); exit(1)
    }
    // Gateway info → level-2 key.
    connection.sendCommand(1100)
    for _ in 0..<12 where box.withLock({ rawGateway }) == nil { try await Task.sleep(for: .milliseconds(400)) }
    guard let raw = box.withLock({ rawGateway }) else { print("no gateway info"); exit(1) }
    let decrypted = PPPPMessage.decryptGatewayInfo(raw, level1Key: level1Key)
    guard let envelope = PPPPMessage.gatewayInfoEnvelope(decrypted: decrypted),
          let level2Key = EufyMediaDecryptor.deriveLevel2Key(gatewayEnvelope: envelope, eccPrivateKeyHex: ecc) else {
        print("level-2 key failed"); exit(1)
    }
    print("Level-2 key ready. Requesting camera on channel \(channel) (level-2 select)…")
    connection.startLiveLevel2(channel: channel, level2Key: level2Key, rsaModulusHex: rsa.modulusHex, accountID: accountID)

    if done.wait(timeout: .now() + 15) == .timedOut { print("No decoded keyframe within 15s."); connection.close(); exit(1) }
    connection.close()
} catch {
    print("error: \(error.localizedDescription)"); exit(1)
}
