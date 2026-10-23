import Foundation
#if canImport(Security)
import Security
#else
import _CryptoExtras
#endif

/// An RSA-1024 key pair for the level-2 media handshake: the station wraps each stream's AES media key
/// with our public modulus; we unwrap it with the private key (PKCS#1 v1.5).
///
/// Apple platforms use Security. On Linux (the Home Assistant add-on) swift-crypto generates the key, but it
/// deliberately has no PKCS#1 v1.5 *decryption*, which the HomeBase protocol requires — so the private-key
/// operation (CRT) and the v1.5 unpadding are done here. It runs once per stream key, not per frame.
public final class EufyRSA: @unchecked Sendable {
    /// The 128-byte modulus as hex — sent to the station as `encryptkey`.
    public let modulusHex: String

    #if canImport(Security)
    private let privateKey: SecKey

    public init?() {
        let attrs: [CFString: Any] = [
            kSecAttrKeyType: kSecAttrKeyTypeRSA,
            kSecAttrKeySizeInBits: 1024,
        ]
        guard let priv = SecKeyCreateRandomKey(attrs as CFDictionary, nil),
              let pub = SecKeyCopyPublicKey(priv),
              let der = SecKeyCopyExternalRepresentation(pub, nil) as Data?,
              let modulus = Self.modulus(fromPKCS1: der) else { return nil }
        privateKey = priv
        modulusHex = modulus.hexString
    }

    /// Unwraps a PKCS#1 v1.5 RSA-encrypted key blob (the station's wrapped AES media key).
    public func unwrap(_ wrapped: Data) -> Data? {
        SecKeyCreateDecryptedData(privateKey, .rsaEncryptionPKCS1, wrapped as CFData, nil) as Data?
    }
    #else
    private let p, q, dP, dQ, qInv: BigUInt
    private let modulusLength: Int

    public init?() {
        guard let key = try? _RSA.Encryption.PrivateKey(unsafeKeySize: .init(bitCount: 1024)),
              let ints = Self.integers(fromPKCS1: key.derRepresentation), ints.count >= 9 else { return nil }
        // RSAPrivateKey ::= SEQUENCE { version, n, e, d, p, q, dP, dQ, qInv }
        let n = ints[1]
        p = BigUInt(bytes: ints[4]); q = BigUInt(bytes: ints[5])
        dP = BigUInt(bytes: ints[6]); dQ = BigUInt(bytes: ints[7]); qInv = BigUInt(bytes: ints[8])
        modulusLength = n.count
        modulusHex = n.hexString
    }

    /// Unwraps a PKCS#1 v1.5 RSA-encrypted key blob (the station's wrapped AES media key).
    public func unwrap(_ wrapped: Data) -> Data? {
        let c = BigUInt(bytes: wrapped)
        // CRT: m1 = c^dP mod p, m2 = c^dQ mod q, h = qInv·(m1 − m2) mod p, m = m2 + h·q.
        let m1 = (c % p).power(dP, modulus: p)
        let m2 = (c % q).power(dQ, modulus: q)
        let m2p = m2 % p
        let diff = m1 >= m2p ? m1 - m2p : m1 + p - m2p
        let h = (qInv * diff) % p
        let m = m2 + h * q
        // EM = 0x00 ‖ 0x02 ‖ PS (≥ 8 non-zero bytes) ‖ 0x00 ‖ M
        let em = m.bytes(length: modulusLength)
        guard em.count >= 11, em[0] == 0x00, em[1] == 0x02,
              let sep = em[2...].firstIndex(of: 0x00), sep >= 10 else { return nil }
        return Data(em[(sep + 1)...])
    }

    /// The INTEGERs of a DER SEQUENCE (unsigned, big-endian, leading sign byte dropped).
    static func integers(fromPKCS1 der: Data) -> [Data]? {
        let bytes = [UInt8](der)
        var i = 0
        guard bytes.first == 0x30 else { return nil }
        i = 1 + derLengthSize(bytes, at: 1)
        var out: [Data] = []
        while i < bytes.count, bytes[i] == 0x02 {
            let (len, lenBytes) = derLength(bytes, at: i + 1)
            let start = i + 1 + lenBytes
            guard len > 0, start + len <= bytes.count else { return nil }
            var value = Array(bytes[start ..< start + len])
            while value.count > 1, value.first == 0x00 { value.removeFirst() }
            out.append(Data(value))
            i = start + len
        }
        return out
    }
    #endif

    /// Parses the modulus (a 128-byte integer for RSA-1024) out of a PKCS#1 RSAPublicKey DER:
    /// `SEQUENCE { INTEGER modulus, INTEGER exponent }`.
    static func modulus(fromPKCS1 der: Data) -> Data? {
        let bytes = [UInt8](der)
        var i = 0
        guard i < bytes.count, bytes[i] == 0x30 else { return nil }   // SEQUENCE
        i += 1
        i += derLengthSize(bytes, at: i)                               // skip sequence length
        guard i < bytes.count, bytes[i] == 0x02 else { return nil }    // INTEGER (modulus)
        i += 1
        let (len, lenBytes) = derLength(bytes, at: i)
        i += lenBytes
        guard len > 0, i + len <= bytes.count else { return nil }
        var modulus = Array(bytes[i ..< i + len])
        if modulus.first == 0x00 { modulus.removeFirst() }            // drop the sign byte
        return Data(modulus)
    }

    private static func derLength(_ bytes: [UInt8], at index: Int) -> (length: Int, bytesUsed: Int) {
        guard index < bytes.count else { return (0, 0) }
        let first = bytes[index]
        if first & 0x80 == 0 { return (Int(first), 1) }
        let count = Int(first & 0x7F)
        var value = 0
        for k in 0..<count where index + 1 + k < bytes.count { value = value << 8 | Int(bytes[index + 1 + k]) }
        return (value, 1 + count)
    }

    private static func derLengthSize(_ bytes: [UInt8], at index: Int) -> Int {
        derLength(bytes, at: index).bytesUsed
    }
}

/// Just enough unsigned big-integer arithmetic for one RSA private-key operation (Linux). Little-endian
/// 32-bit limbs; schoolbook multiply and bitwise long division — fine for a once-per-stream unwrap.
struct BigUInt: Comparable {
    var limbs: [UInt32]   // little-endian, no trailing zeros (zero is [])

    init(limbs: [UInt32]) {
        var l = limbs
        while l.last == 0 { l.removeLast() }
        self.limbs = l
    }

    init(bytes: Data) {
        var l: [UInt32] = []
        let b = [UInt8](bytes)
        var i = b.count
        while i > 0 {
            var limb: UInt32 = 0
            for k in 0..<4 where i - 1 - k >= 0 { limb |= UInt32(b[i - 1 - k]) << (8 * UInt32(k)) }
            l.append(limb)
            i -= 4
        }
        self.init(limbs: l)
    }

    func bytes(length: Int) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: length)
        for (index, limb) in limbs.enumerated() {
            for k in 0..<4 {
                let position = length - 1 - (index * 4 + k)
                if position >= 0 { out[position] = UInt8(truncatingIfNeeded: limb >> (8 * UInt32(k))) }
            }
        }
        return out
    }

    var bitWidth: Int { limbs.isEmpty ? 0 : (limbs.count - 1) * 32 + (32 - limbs.last!.leadingZeroBitCount) }
    func bit(_ i: Int) -> Bool { i / 32 < limbs.count && (limbs[i / 32] >> UInt32(i % 32)) & 1 == 1 }

    static func < (a: BigUInt, b: BigUInt) -> Bool {
        if a.limbs.count != b.limbs.count { return a.limbs.count < b.limbs.count }
        for i in stride(from: a.limbs.count - 1, through: 0, by: -1) where a.limbs[i] != b.limbs[i] {
            return a.limbs[i] < b.limbs[i]
        }
        return false
    }

    static func + (a: BigUInt, b: BigUInt) -> BigUInt {
        var out = [UInt32](repeating: 0, count: max(a.limbs.count, b.limbs.count) + 1)
        var carry: UInt64 = 0
        for i in 0..<out.count {
            let s = UInt64(i < a.limbs.count ? a.limbs[i] : 0) + UInt64(i < b.limbs.count ? b.limbs[i] : 0) + carry
            out[i] = UInt32(truncatingIfNeeded: s); carry = s >> 32
        }
        return BigUInt(limbs: out)
    }

    /// a − b, for a ≥ b.
    static func - (a: BigUInt, b: BigUInt) -> BigUInt {
        var out = a.limbs
        var borrow: Int64 = 0
        for i in 0..<out.count {
            var d = Int64(out[i]) - Int64(i < b.limbs.count ? b.limbs[i] : 0) - borrow
            borrow = d < 0 ? 1 : 0
            if d < 0 { d += 1 << 32 }
            out[i] = UInt32(d)
        }
        return BigUInt(limbs: out)
    }

    static func * (a: BigUInt, b: BigUInt) -> BigUInt {
        if a.limbs.isEmpty || b.limbs.isEmpty { return BigUInt(limbs: []) }
        var out = [UInt32](repeating: 0, count: a.limbs.count + b.limbs.count)
        for i in 0..<a.limbs.count {
            var carry: UInt64 = 0
            for j in 0..<b.limbs.count {
                let t = UInt64(a.limbs[i]) * UInt64(b.limbs[j]) + UInt64(out[i + j]) + carry
                out[i + j] = UInt32(truncatingIfNeeded: t); carry = t >> 32
            }
            out[i + b.limbs.count] = UInt32(carry)
        }
        return BigUInt(limbs: out)
    }

    /// a mod m, by bitwise long division.
    static func % (a: BigUInt, m: BigUInt) -> BigUInt {
        if a < m { return a }
        var r = BigUInt(limbs: [])
        for i in stride(from: a.bitWidth - 1, through: 0, by: -1) {
            r = r.shiftedLeftOne(orBit: a.bit(i))
            if r >= m { r = r - m }
        }
        return r
    }

    private func shiftedLeftOne(orBit: Bool) -> BigUInt {
        var out = [UInt32](repeating: 0, count: limbs.count + 1)
        var carry: UInt32 = orBit ? 1 : 0
        for i in 0..<limbs.count {
            out[i] = (limbs[i] << 1) | carry
            carry = limbs[i] >> 31
        }
        out[limbs.count] = carry
        return BigUInt(limbs: out)
    }

    /// selfᵉ mod m (square-and-multiply).
    func power(_ e: BigUInt, modulus m: BigUInt) -> BigUInt {
        var result = BigUInt(limbs: [1]) % m
        var base = self % m
        for i in 0..<e.bitWidth {
            if e.bit(i) { result = (result * base) % m }
            base = (base * base) % m
        }
        return result
    }
}
