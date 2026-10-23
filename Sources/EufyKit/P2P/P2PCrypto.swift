import Foundation

extension PPPPMessage {
    /// AES-128-ECB with no padding (the data is block-aligned already). Used for level-1 command bodies.
    static func encryptECB(_ data: Data, key: Data) -> Data { ecb(data, key: key, encrypt: true) }
    static func decryptECB(_ data: Data, key: Data) -> Data { ecb(data, key: key, encrypt: false) }

    private static func ecb(_ data: Data, key: Data, encrypt: Bool) -> Data {
        PortableAES.ecb(data, key: key, encrypt: encrypt)
    }
}
