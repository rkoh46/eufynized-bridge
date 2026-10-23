import Foundation
import EufyKit

// Gets the HomeBase's cipher_id locally (gateway-info), then fetches the station's ECC key from the
// eufylife cloud host (get_ciphers) — the key that unlocks per-camera selection. One-time; cacheable.
//   swift run eufynized-cipher <email> <station-serial> [homebase-ip] [country]

let args = Array(CommandLine.arguments.dropFirst())
guard args.count >= 2, args[0].contains("@") else {
    print("usage: eufynized-cipher <email> <station-serial> [homebase-ip] [country]")
    exit(2)
}
let email = args[0], stationSerial = args[1]
let ip = args.count > 2 ? args[2] : nil
let country = args.count > 3 ? args[3] : "US"

let box = NSLock()
nonisolated(unsafe) var rawGateway: Data?

do {
    // 1. Local gateway-info → cipher_id (no cloud). The reply is AES-ECB encrypted under the level-1 key.
    let connection = try HomeBaseConnection(config: .init(stationSerial: stationSerial, p2pDID: nil, knownAddress: ip))
    connection.onFrame { _, cmd, _, payload in
        guard cmd == 1100 else { return }
        box.withLock { if rawGateway == nil { rawGateway = payload } }
    }
    print("Connecting to HomeBase…")
    _ = try await connection.connect()
    guard let did = connection.connectedDID, let level1Key = PPPPMessage.commandKey(stationSerial: stationSerial, p2pDID: did) else {
        print("Couldn't derive the level-1 key."); exit(1)
    }
    connection.sendCommand(1100)   // CMD_GATEWAYINFO
    for _ in 0..<12 where box.withLock({ rawGateway }) == nil { try await Task.sleep(for: .milliseconds(400)) }
    connection.close()

    guard let raw = box.withLock({ rawGateway }) else { print("No gateway-info reply."); exit(1) }
    let decrypted = PPPPMessage.decryptGatewayInfo(raw, level1Key: level1Key)
    nonisolated(unsafe) let cipherID = PPPPMessage.gatewayInfoCipherID(decrypted: decrypted)

    guard let id = cipherID else {
        print("No cipher_id in the decrypted gateway-info reply.")
        exit(1)
    }
    print("cipher_id = \(id)  (decrypted gateway-info: \(decrypted.prefix(8).map { String(format: "%02x", $0) }.joined()))")

    // 2. Cloud get_ciphers on the eufylife host → ECC key.
    let client = EufyCloudClient(configuration: .init(email: email, countryCode: country))
    guard await client.isSignedIn else {
        print("Not signed in. Run eufynized-login \(email) first.")
        exit(1)
    }
    print("Fetching ECC key from the eufylife host…")
    let ciphers = try await client.getCiphers(cipherIDs: [id], stationSerial: stationSerial)
    guard let ecc = ciphers.first(where: { $0.cipherID == id })?.eccPrivateKey ?? ciphers.first?.eccPrivateKey else {
        print("get_ciphers returned no ECC key.")
        exit(1)
    }
    print("ECC key received (\(ecc.count) hex chars).")

    // 3. Derive the level-2 command key from the gateway envelope + ECC key (all local now).
    guard let envelope = PPPPMessage.gatewayInfoEnvelope(decrypted: decrypted),
          let level2Key = EufyMediaDecryptor.deriveLevel2Key(gatewayEnvelope: envelope, eccPrivateKeyHex: ecc) else {
        print("Could not derive the level-2 key from the gateway envelope.")
        exit(1)
    }
    print("Level-2 key derived: \(level2Key.count) bytes ✓  — per-camera selection is unlocked.")

    CipherKeyCache().save(eccPrivateKey: ecc, stationSerial: stationSerial)
    print("Cached the ECC key in the Keychain — future runs need no cloud.")
} catch {
    print("error: \(error.localizedDescription)")
    exit(1)
}
