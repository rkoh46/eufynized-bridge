import Foundation
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

/// A direct HomeBase session with the level-2 command key negotiated — the base for anything that
/// talks to the station itself rather than streaming one camera (event history, clip downloads).
/// Cloud-free: the key comes from the gateway-info reply and the cached station ECC key.
public final class HomeBaseSession: @unchecked Sendable {
    public enum SessionError: LocalizedError {
        case noGatewayInfo, noLevel2Key
        public var errorDescription: String? {
            switch self {
            case .noGatewayInfo: "The HomeBase didn't send its gateway info."
            case .noLevel2Key: "Couldn't derive the HomeBase's session key. Re-run setup to refresh the station key."
            }
        }
    }

    public let connection: HomeBaseConnection
    private let context: EufyLiveStream.Level2Context
    private let lock = NSLock()
    private var rawGateway: Data?
    private var handlers: [UUID: @Sendable (PPPPMessage.DataKind, UInt16?, UInt8, Data) -> Void] = [:]
    public private(set) var level1Key: Data?
    public private(set) var level2Key: Data?

    public init(homeBaseIP: String?, context: EufyLiveStream.Level2Context) throws {
        self.context = context
        connection = try HomeBaseConnection(config: .init(stationSerial: context.stationSerial, p2pDID: nil,
                                                          knownAddress: homeBaseIP))
        connection.onFrame { [weak self] kind, cmd, signCode, body in
            guard let self else { return }
            if cmd == 1100 { self.lock.withLock { if self.rawGateway == nil { self.rawGateway = body } } }
            for handler in self.lock.withLock({ Array(self.handlers.values) }) { handler(kind, cmd, signCode, body) }
        }
    }

    public var accountID: String { context.accountID }

    /// Connects and negotiates the level-2 key.
    public func open() async throws {
        _ = try await connection.connect()
        guard let did = connection.connectedDID,
              let level1 = PPPPMessage.commandKey(stationSerial: context.stationSerial, p2pDID: did) else {
            throw HomeBaseConnection.ConnectionError.invalidP2PDID
        }
        level1Key = level1
        for attempt in 0..<24 where lock.withLock({ rawGateway }) == nil {
            if attempt % 4 == 0 { connection.sendCommand(1100) }   // resend each second until it answers
            try await Task.sleep(for: .milliseconds(250))
        }
        guard let raw = lock.withLock({ rawGateway }) else { throw SessionError.noGatewayInfo }
        let decrypted = PPPPMessage.decryptGatewayInfo(raw, level1Key: level1)
        guard let envelope = PPPPMessage.gatewayInfoEnvelope(decrypted: decrypted),
              let key = EufyMediaDecryptor.deriveLevel2Key(gatewayEnvelope: envelope, eccPrivateKeyHex: context.eccPrivateKeyHex)
        else { throw SessionError.noLevel2Key }
        level2Key = key
    }

    public func close() { connection.close() }

    /// Adds a handler for every inbound frame; returns a token to remove it with.
    @discardableResult
    public func addFrameHandler(_ handler: @escaping @Sendable (PPPPMessage.DataKind, UInt16?, UInt8, Data) -> Void) -> UUID {
        let id = UUID()
        lock.withLock { handlers[id] = handler }
        return id
    }

    public func removeFrameHandler(_ id: UUID) { _ = lock.withLock { handlers.removeValue(forKey: id) } }

    /// Sends `{account_id, cmd, mChannel, mValue3, payload}` through SET_PAYLOAD (1350), level-2 encrypted.
    public func sendSetPayload(cmd: Int, channel: UInt8, mValue3: Int = 0, payloadJSON: String) {
        guard let key = level2Key else { return }
        let json = "{\"account_id\":\"\(context.accountID)\",\"cmd\":\(cmd),\"mChannel\":\(channel),\"mValue3\":\(mValue3),\"payload\":\(payloadJSON)}"
        connection.sendSetPayload(json, channel: channel, level2Key: key)
    }

    /// Decrypts a station-sent control body: signCode 2/8 is level-2 GCM, other non-zero signCodes are
    /// level-1 AES-ECB (block-aligned head only), 0 is plaintext.
    public func decryptControl(_ body: Data, signCode: UInt8) -> Data {
        if signCode == 2 || signCode == 8, let key = level2Key,
           let plain = PPPPMessage.decryptLevel2(body, key: key, signCode: signCode) { return plain }
        if signCode > 0, let key = level1Key {
            let n = body.count - body.count % 16
            if n >= 16 { return PPPPMessage.decryptECB(body.prefix(n), key: key) }
        }
        return body
    }
}

extension PPPPMessage {
    /// Opens a level-2 frame: `tag(16) ‖ nonce(12) ‖ [sub(4) if signCode 8] ‖ ciphertext`, AES-256-GCM.
    public static func decryptLevel2(_ payload: Data, key: Data, signCode: UInt8) -> Data? {
        let offset = signCode == 8 ? 32 : 28
        let p = Data(payload)
        guard p.count >= offset, let nonce = try? AES.GCM.Nonce(data: p.subdata(in: 16 ..< 28)),
              let box = try? AES.GCM.SealedBox(nonce: nonce, ciphertext: p.subdata(in: offset ..< p.count), tag: p.prefix(16))
        else { return nil }
        return try? AES.GCM.open(box, using: SymmetricKey(data: key), authenticating: level2AAD)
    }
}
