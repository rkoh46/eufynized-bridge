import Foundation
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

/// The `algo_ecdh` scheme Eufy's cloud ("mega" API) uses for every request.
///
/// 1. Key exchange: an ephemeral P-256 key pair, its public key wrapped in AES-128-CBC under the app's
///    bootstrap key. The server answers with its own wrapped public key; ECDH gives the session
///    `shareKey` (first 32 hex chars of the shared secret).
/// 2. Bodies: base64(IV ‖ AES-128-CBC-PKCS7(plaintext)), key = shareKey.
/// 3. `x-signature`: HMAC-SHA256(shareKey hex as UTF-8, "ts+once[+encryptedBody]").
/// 4. The login password is encrypted separately, with ECDH against a fixed server key.
///
/// Scheme documented by eufy-sdk (Apache-2.0, github.com/mega-yfue/eufy-sdk). The keys below were
/// confirmed present in the Eufy iOS app 6.1.11 (MegaCommonFramework).
public enum EufyCrypto {
    /// Bootstrap key for the mega key exchange (app-openapi / passport / app-* hosts).
    public static let megaLocalKeyHex = "2500a7d5617812f9d52515b2c8f20a3d"
    /// Bootstrap key for the security-app.eufylife.com data host.
    public static let eufylifeLocalKeyHex = "118c12c81e211149304bd70a0c071d01"
    /// Server P-256 public key (uncompressed) used only to encrypt the login password.
    public static let serverStaticPublicKeyHex =
        "04c5c00c4f8d1197cc7c3167c52bf7acb054d722f0ef08dcd7e0883236e0d72a3868d9750cb47fa4619248f3d83f0f662671dadc6e2d31c2f41db0161651c7c076"

    public enum CryptoError: Error {
        case invalidHex, invalidBase64, cipherFailed(Int32), invalidServerKey
    }

    // MARK: Session bodies and signatures

    /// base64(IV ‖ AES-128-CBC(plaintext)) under the session key.
    public static func encryptBody(_ plaintext: Data, shareKeyHex: String, iv: Data = randomBytes(16)) throws -> String {
        let ct = try aesCBC(encrypt: true, key: aesKey(shareKeyHex), iv: iv, data: plaintext)
        return (iv + ct).base64EncodedString()
    }

    public static func decryptBody(_ base64: String, shareKeyHex: String) throws -> Data {
        guard let raw = Data(base64Encoded: base64), raw.count > 16 else { throw CryptoError.invalidBase64 }
        return try aesCBC(encrypt: false, key: aesKey(shareKeyHex), iv: raw.prefix(16), data: raw.dropFirst(16))
    }

    /// `x-signature`: HMAC-SHA256 over "ts+once" plus "+body" when there is a body.
    public static func sign(shareKeyHex: String, ts: String, once: String, encryptedBody: String?) -> String {
        hmacHex(key: Data(shareKeyHex.prefix(32).utf8), message: [ts, once, encryptedBody].compactMap { $0 }.joined(separator: "+"))
    }

    /// `gtoken` header: md5(user_id) as hex.
    public static func gtoken(userId: String) -> String { md5Hex(userId) }

    static func md5Hex(_ string: String) -> String {
        Insecure.MD5.hash(data: Data(string.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    static func aesKey(_ shareKeyHex: String) throws -> Data {
        guard let key = Data(hex: String(shareKeyHex.prefix(32))), key.count == 16 else { throw CryptoError.invalidHex }
        return key
    }

    // MARK: Key exchange

    public struct KeyExchangeRequest {
        let privateKey: P256.KeyAgreement.PrivateKey
        let localKey: Data
        public let keyIdent: String
        /// Body field `client_public_key`.
        public let encryptedClientPublicKey: String
        public let headers: [String: String]
    }

    public static func prepareKeyExchange(localKeyHex: String = megaLocalKeyHex) throws -> KeyExchangeRequest {
        guard let localKey = Data(hex: localKeyHex) else { throw CryptoError.invalidHex }
        let privateKey = P256.KeyAgreement.PrivateKey()
        let publicHex = privateKey.publicKey.x963Representation.hexString
        let iv = randomBytes(16)
        let wrapped = (iv + (try aesCBC(encrypt: true, key: localKey, iv: iv, data: Data(publicHex.utf8)))).base64EncodedString()
        let ts = unixTimestamp(), once = randomID(), keyIdent = randomID()
        return KeyExchangeRequest(
            privateKey: privateKey, localKey: localKey, keyIdent: keyIdent, encryptedClientPublicKey: wrapped,
            headers: [
                "x-encryption-info": "algo_ecdh",
                "x-replay-info": "replay",
                "x-key-ident": keyIdent,
                "x-request-ts": ts,
                "x-request-once": once,
                "x-signature": hmacHex(key: Data(localKeyHex.utf8), message: "\(ts)+\(once)+\(wrapped)"),
            ])
    }

    /// Unwraps the server's public key and derives the session key (32 hex chars).
    public static func finishKeyExchange(_ request: KeyExchangeRequest, serverPublicKeyBase64: String) throws -> String {
        guard let blob = Data(base64Encoded: serverPublicKeyBase64), blob.count > 16 else { throw CryptoError.invalidBase64 }
        let serverHexData = try aesCBC(encrypt: false, key: request.localKey, iv: blob.prefix(16), data: blob.dropFirst(16))
        guard let serverHex = String(data: serverHexData, encoding: .utf8), let serverKeyData = Data(hex: serverHex),
              let serverKey = try? P256.KeyAgreement.PublicKey(x963Representation: serverKeyData) else {
            throw CryptoError.invalidServerKey
        }
        let shared = try request.privateKey.sharedSecretFromKeyAgreement(with: serverKey)
        return String(shared.withUnsafeBytes { Data($0) }.hexString.prefix(32))
    }

    // MARK: Login password

    /// AES-256-CBC with the full ECDH secret against the fixed server key; IV = first 16 bytes of it.
    public static func encryptLoginPassword(_ password: String) throws -> (clientPublicKeyHex: String, encryptedPassword: String) {
        guard let serverData = Data(hex: serverStaticPublicKeyHex),
              let serverKey = try? P256.KeyAgreement.PublicKey(x963Representation: serverData) else {
            throw CryptoError.invalidServerKey
        }
        let privateKey = P256.KeyAgreement.PrivateKey()
        let secret = try privateKey.sharedSecretFromKeyAgreement(with: serverKey).withUnsafeBytes { Data($0) }
        let ct = try aesCBC(encrypt: true, key: secret, iv: secret.prefix(16), data: Data(password.utf8))
        return (privateKey.publicKey.x963Representation.hexString, ct.base64EncodedString())
    }

    // MARK: Primitives

    static func aesCBC(encrypt: Bool, key: Data, iv: Data, data: Data) throws -> Data {
        guard let out = PortableAES.cbc(data, key: key, iv: iv, encrypt: encrypt, pkcs7: true) else {
            throw CryptoError.cipherFailed(-1)
        }
        return out
    }

    static func hmacHex(key: Data, message: String) -> String {
        Data(HMAC<SHA256>.authenticationCode(for: Data(message.utf8), using: SymmetricKey(data: key))).hexString
    }

    public static func randomBytes(_ count: Int) -> Data {
        Data((0..<count).map { _ in UInt8.random(in: .min ... .max) })
    }

    /// 32 hex characters, for X-Key-Ident and X-Request-Once.
    static func randomID() -> String { randomBytes(16).hexString }

    static func unixTimestamp() -> String { String(Int(Date().timeIntervalSince1970)) }
}

extension Data {
    init?(hex: String) {
        guard hex.count.isMultiple(of: 2) else { return nil }
        var bytes = [UInt8]()
        bytes.reserveCapacity(hex.count / 2)
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        self.init(bytes)
    }

    var hexString: String { map { String(format: "%02x", $0) }.joined() }
}
