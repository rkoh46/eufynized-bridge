import Foundation
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

extension PPPPMessage {
    static let level2SeqBase: UInt32 = 0x0102_0300
    static let level2AAD = Data("eufy security".utf8)

    /// Level-2 command encryption: `authTag(16) ‖ nonce(12) ‖ seqSub(4 LE) ‖ ciphertext`.
    public static func encryptLevel2(_ plaintext: Data, key: Data, seq: UInt32) -> Data? {
        let nonce = EufyCrypto.randomBytes(12)
        guard let gcmNonce = try? AES.GCM.Nonce(data: nonce),
              let sealed = try? AES.GCM.seal(plaintext, using: SymmetricKey(data: key), nonce: gcmNonce, authenticating: level2AAD)
        else { return nil }
        var sub = (level2SeqBase &+ seq).littleEndian
        let subData = withUnsafeBytes(of: &sub) { Data($0) }
        return Data(sealed.tag) + nonce + subData + Data(sealed.ciphertext)
    }

    /// A raw command payload: `len(2 LE) 0000 magic(2) channel signCode streamId 00 data`.
    public static func rawCommandPayload(_ data: Data, channel: UInt8, signCode: UInt8,
                                         magic: (UInt8, UInt8), streamID: UInt8) -> Data {
        var out = Data([UInt8(truncatingIfNeeded: data.count), UInt8(data.count >> 8),
                        0x00, 0x00, magic.0, magic.1, channel, signCode, streamID, 0x00])
        out.append(data)
        return out
    }

    /// The level-2 media-start JSON that selects a camera channel and hands the station our RSA modulus.
    public static func level2MediaStartJSON(channel: UInt8, accountID: String, rsaModulusHex: String,
                                            streamType: Int = 1) -> String {
        let inner = "{\"ClientOS\":\"Android\",\"accountId\":\"\(accountID)\",\"camera_type\":0,\"entrytype\":0,\"key\":\"\(rsaModulusHex)\",\"streamtype\":\(streamType)}"
        return "{\"account_id\":\"\(accountID)\",\"cmd\":1003,\"mChannel\":\(channel),\"mValue3\":1003,\"payload\":\(inner)}"
    }
}

/// Decrypts level-2 video frames. The station RSA-wraps the stream's AES key into each large frame; the
/// first 128 bytes of the body are AES-ECB encrypted and the remainder is plaintext H.265.
public final class Level2VideoDecoder: @unchecked Sendable {
    private let rsa: EufyRSA
    private let lock = NSLock()
    private var cachedKey: Data?
    /// The last wrapped blob and its unwrapped key: a stream repeats the same wrapped key, and the RSA
    /// private-key operation is the expensive part (especially on Linux, without Security's RSA).
    private var lastWrapped: Data?
    public private(set) var rsaUnwraps = 0, rsaCacheHits = 0

    public init(rsa: EufyRSA) { self.rsa = rsa }

    /// Returns the H.265 elementary-stream bytes of one `CMD_VIDEO_FRAME` body (the payload after the DATA
    /// frame header), given the frame's sign code. signCode 0 means the body is already plaintext.
    public func decode(_ body: Data, signCode: UInt8) -> Data? {
        guard body.count >= 22 else { return nil }
        let b = [UInt8](body.prefix(4))
        let videoLen = Int(UInt32(b[0]) | UInt32(b[1]) << 8 | UInt32(b[2]) << 16 | UInt32(b[3]) << 24)
        var payloadStart = 22
        var aesKey: Data?

        if signCode > 0 && videoLen >= 128 {
            guard body.count >= 150 else { return nil }
            let wrapped = body.subdata(in: 22 ..< 150)
            if let hit = lock.withLock({ lastWrapped == wrapped ? cachedKey : nil }) {
                aesKey = hit
                lock.withLock { rsaCacheHits += 1 }
            } else if let unwrapped = rsa.unwrap(wrapped) {
                aesKey = unwrapped
                lock.withLock { cachedKey = unwrapped; lastWrapped = wrapped; rsaUnwraps += 1 }
            } else {
                aesKey = lock.withLock { cachedKey }   // reuse last key (P/B frames may not re-wrap)
            }
            if ProcessInfo.processInfo.environment["EUFY_DEBUG"] != nil {
                FileHandle.standardError.write(Data("[l2dec] signCode=\(signCode) videoLen=\(videoLen) bodyLen=\(body.count) rsaKey=\(aesKey?.count ?? -1)\n".utf8))
            }
            guard aesKey != nil else { return nil }
            payloadStart = 151
        }

        if let aesKey, aesKey.count >= 16, body.count >= payloadStart + 128 {
            let use256 = aesKey.count >= 32
            let enc = body.subdata(in: payloadStart ..< payloadStart + 128)
            let tailEnd = min(body.count, payloadStart + videoLen)
            let tail = tailEnd > payloadStart + 128 ? body.subdata(in: payloadStart + 128 ..< tailEnd) : Data()
            let dec = PPPPMessage.decryptECB(enc, key: aesKey.prefix(use256 ? 32 : 16))
            return dec + tail
        }
        let end = min(body.count, payloadStart + videoLen)
        return end > payloadStart ? body.subdata(in: payloadStart ..< end) : nil
    }
}
