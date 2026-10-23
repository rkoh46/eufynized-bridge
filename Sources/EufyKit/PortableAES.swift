import Foundation
#if canImport(CommonCrypto)
import CommonCrypto
#else
import Crypto
import _CryptoExtras
#endif

/// AES-ECB / AES-CBC for the Eufy protocol, the same on macOS/iOS and Linux (the Home Assistant add-on):
/// CommonCrypto on Apple platforms, swift-crypto's AES block function elsewhere.
enum PortableAES {
    /// AES-ECB without padding over block-aligned data; empty if the data isn't block-aligned or the key is bad.
    static func ecb(_ data: Data, key: Data, encrypt: Bool) -> Data {
        guard data.count % 16 == 0 else { return Data() }
        #if canImport(CommonCrypto)
        return commonCrypto(data, key: key, iv: nil, encrypt: encrypt, options: CCOptions(kCCOptionECBMode)) ?? Data()
        #else
        var out = Data(capacity: data.count)
        var offset = data.startIndex
        while offset < data.endIndex {
            let end = data.index(offset, offsetBy: 16)
            guard let block = block(Data(data[offset..<end]), key: key, encrypt: encrypt) else { return Data() }
            out.append(block)
            offset = end
        }
        return out
        #endif
    }

    /// AES-CBC. With `pkcs7`, pads on encrypt and strips on decrypt; without it the data must be block-aligned.
    static func cbc(_ data: Data, key: Data, iv: Data, encrypt: Bool, pkcs7: Bool) -> Data? {
        #if canImport(CommonCrypto)
        return commonCrypto(data, key: key, iv: iv, encrypt: encrypt, options: pkcs7 ? CCOptions(kCCOptionPKCS7Padding) : 0)
        #else
        var input = Data(data)
        if encrypt && pkcs7 {
            let pad = 16 - input.count % 16
            input.append(contentsOf: [UInt8](repeating: UInt8(pad), count: pad))
        }
        guard input.count % 16 == 0, iv.count == 16 else { return nil }
        var previous = [UInt8](iv)
        var out = Data(capacity: input.count)
        let bytes = [UInt8](input)
        for start in stride(from: 0, to: bytes.count, by: 16) {
            let chunk = Array(bytes[start..<start + 16])
            if encrypt {
                let mixed = zip(chunk, previous).map { $0 ^ $1 }
                guard let enc = block(Data(mixed), key: key, encrypt: true) else { return nil }
                out.append(enc)
                previous = [UInt8](enc)
            } else {
                guard let dec = block(Data(chunk), key: key, encrypt: false) else { return nil }
                out.append(contentsOf: zip([UInt8](dec), previous).map { $0 ^ $1 })
                previous = chunk
            }
        }
        if !encrypt && pkcs7 {
            guard let pad = out.last, pad >= 1, pad <= 16, Int(pad) <= out.count,
                  out.suffix(Int(pad)).allSatisfy({ $0 == pad }) else { return nil }
            out.removeLast(Int(pad))
        }
        return out
        #endif
    }

    #if canImport(CommonCrypto)
    private static func commonCrypto(_ data: Data, key: Data, iv: Data?, encrypt: Bool, options: CCOptions) -> Data? {
        var out = Data(count: data.count + kCCBlockSizeAES128)
        var moved = 0
        let cap = out.count
        let status = out.withUnsafeMutableBytes { o in
            data.withUnsafeBytes { d in
                key.withUnsafeBytes { k in
                    (iv ?? Data()).withUnsafeBytes { ivp in
                        CCCrypt(CCOperation(encrypt ? kCCEncrypt : kCCDecrypt), CCAlgorithm(kCCAlgorithmAES), options,
                                k.baseAddress, key.count, iv == nil ? nil : ivp.baseAddress,
                                d.baseAddress, data.count, o.baseAddress, cap, &moved)
                    }
                }
            }
        }
        guard status == kCCSuccess else { return nil }
        return out.prefix(moved)
    }
    #else
    /// One 16-byte block through AES (the primitive both modes are built from on Linux).
    private static func block(_ data: Data, key: Data, encrypt: Bool) -> Data? {
        var buffer = [UInt8](data)
        do {
            if encrypt { try AES.permute(&buffer, key: SymmetricKey(data: key)) }
            else { try AES.inversePermute(&buffer, key: SymmetricKey(data: key)) }
        } catch { return nil }
        return Data(buffer)
    }
    #endif
}
