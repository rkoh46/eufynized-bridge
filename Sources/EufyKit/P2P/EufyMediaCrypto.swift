import Foundation
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

/// Decrypts Eufy P2P video frames. Each keyframe carries an ECIES envelope that, unwrapped with the
/// camera's ECC private key, yields a media key; that key (AES-256-GCM) decrypts every frame body until
/// the next keyframe. Ported from eufy-sdk (Apache-2.0, src/transport/p2p/video.ts + codec.ts).
public struct EufyMediaDecryptor: Sendable {
    /// Frame layout offsets (bytes).
    enum Layout {
        static let envelopeOffset = 0x16   // keyframes only
        static let envelopeLength = 0x81   // 129
        static let gcmTagOffset = 0x97
        static let gcmTagLength = 16
        static let gcmNonceOffset = 0xA7
        static let gcmNonceLength = 12
        static let bodyOffset = 0xB3
    }
    static let videoAAD = Data("eufy security".utf8)

    let eccPrivateKey: P256.KeyAgreement.PrivateKey
    private var mediaKeyBox = MediaKeyBox()

    /// - Parameter eccPrivateKeyHex: the camera's 32-byte P-256 scalar as hex (from cloud get_ciphers).
    public init?(eccPrivateKeyHex: String) {
        guard let raw = Data(hex: eccPrivateKeyHex.trimmingCharacters(in: .whitespaces)), raw.count == 32,
              let key = try? P256.KeyAgreement.PrivateKey(rawRepresentation: raw) else { return nil }
        eccPrivateKey = key
    }

    /// Decodes one `CMD_VIDEO_FRAME` payload to its H.264/H.265 elementary-stream bytes, or nil on failure
    /// (a wrong key, a P/B-frame before any keyframe, or a short/tampered frame).
    public func decode(_ payload: Data) -> (bytes: Data, header: VideoFrameHeader)? {
        guard let header = VideoFrameHeader(payload) else { return nil }

        if header.keyframe {
            guard payload.count >= Layout.envelopeOffset + Layout.envelopeLength else { return nil }
            let envelope = payload.subdata(in: Layout.envelopeOffset ..< Layout.envelopeOffset + Layout.envelopeLength)
            guard let key = unwrapMediaKey(envelope) else { return nil }
            mediaKeyBox.set(key)
        }
        guard let mediaKey = mediaKeyBox.value, payload.count >= Layout.bodyOffset else { return nil }

        let tag = payload.subdata(in: Layout.gcmTagOffset ..< Layout.gcmTagOffset + Layout.gcmTagLength)
        let nonce = payload.subdata(in: Layout.gcmNonceOffset ..< Layout.gcmNonceOffset + Layout.gcmNonceLength)
        let body = payload.subdata(in: Layout.bodyOffset ..< payload.count)
        do {
            let box = try AES.GCM.SealedBox(nonce: AES.GCM.Nonce(data: nonce), ciphertext: body, tag: tag)
            let plain = try AES.GCM.open(box, using: SymmetricKey(data: mediaKey), authenticating: Self.videoAAD)
            return (plain, header)
        } catch {
            return nil
        }
    }

    /// ECIES unwrap for the video envelope: `ephPub(33) ‖ iv(16) ‖ ct(48) ‖ HMAC(32)` → 32-byte media key.
    func unwrapMediaKey(_ envelope: Data) -> Data? {
        Self.eciesUnwrap(envelope, eccPrivateKey: eccPrivateKey, verifyHMAC: true, stripPadding: true)
    }

    /// ECIES unwrap. The video envelope verifies a trailing HMAC and strips PKCS7; the gateway-info
    /// envelope does neither.
    public static func eciesUnwrap(_ envelope: Data, eccPrivateKey: P256.KeyAgreement.PrivateKey,
                                   verifyHMAC: Bool, stripPadding: Bool) -> Data? {
        let minLen = 33 + 16 + 48 + (verifyHMAC ? 32 : 0)
        guard envelope.count >= minLen else { return nil }
        let base = envelope.startIndex
        let ephemeralPub = envelope.subdata(in: base ..< base + 33)
        let iv = envelope.subdata(in: base + 33 ..< base + 49)
        let ct = envelope.subdata(in: base + 49 ..< base + 97)

        guard let peer = try? P256.KeyAgreement.PublicKey(compressedRepresentation: ephemeralPub),
              let shared = try? eccPrivateKey.sharedSecretFromKeyAgreement(with: peer) else { return nil }
        let sharedBytes = shared.withUnsafeBytes { Data($0) }   // 32-byte X coordinate
        let kdf = eufyKDF(shared: sharedBytes, length: 48)

        if verifyHMAC {
            let macKey = kdf.subdata(in: 16 ..< 48)
            let tag = envelope.subdata(in: base + 97 ..< base + 129)
            let computed = Data(HMAC<SHA256>.authenticationCode(for: envelope.subdata(in: base + 33 ..< base + 97),
                                                                using: SymmetricKey(data: macKey)))
            guard computed == tag else { return nil }
        }
        let aesKey = kdf.subdata(in: 0 ..< 16)
        let decrypted = PPPPMessage.decryptCBCNoPadding(ct, key: aesKey, iv: iv)
        return stripPadding ? stripPKCS7Static(decrypted) : decrypted
    }

    /// The level-2 command key: ECIES-unwrap the gateway-info envelope (no HMAC), take its first 32 bytes.
    public static func deriveLevel2Key(gatewayEnvelope: Data, eccPrivateKeyHex: String) -> Data? {
        guard let raw = Data(hex: eccPrivateKeyHex.trimmingCharacters(in: .whitespaces)), raw.count == 32,
              let key = try? P256.KeyAgreement.PrivateKey(rawRepresentation: raw),
              let plain = eciesUnwrap(gatewayEnvelope, eccPrivateKey: key, verifyHMAC: false, stripPadding: false),
              plain.count >= 32 else { return nil }
        return plain.prefix(32)
    }

    /// HMAC-based KDF: repeatedly `T = HMAC(shared, T)`, output `HMAC(shared, T ‖ "ECIES")`.
    static func eufyKDF(shared: Data, length: Int) -> Data {
        let label = Data("ECIES".utf8)
        let key = SymmetricKey(data: shared)
        var out = Data()
        var t = label
        while out.count < length {
            t = Data(HMAC<SHA256>.authenticationCode(for: t, using: key))
            out.append(Data(HMAC<SHA256>.authenticationCode(for: t + label, using: key)))
        }
        return out.prefix(length)
    }

    static func stripPKCS7Static(_ data: Data) -> Data? {
        guard let pad = data.last, pad >= 1, pad <= 16, data.count >= Int(pad) else { return data.isEmpty ? nil : data }
        let body = data.dropLast(Int(pad))
        return data.suffix(Int(pad)).allSatisfy { $0 == pad } ? Data(body) : data
    }

    /// Box so the cached media key survives across the struct's immutable `decode` calls.
    final class MediaKeyBox: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: Data?
        var value: Data? { lock.withLock { stored } }
        func set(_ key: Data) { lock.withLock { stored = key } }
    }
}

extension PPPPMessage {
    /// AES-128-CBC decrypt with no padding (ECIES ct is block-aligned; PKCS7 is stripped by the caller).
    static func decryptCBCNoPadding(_ data: Data, key: Data, iv: Data) -> Data {
        PortableAES.cbc(data, key: key, iv: iv, encrypt: false, pkcs7: false) ?? Data()
    }
}
