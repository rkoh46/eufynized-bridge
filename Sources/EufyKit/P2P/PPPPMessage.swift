import Foundation

/// PPPP (CS2 Network P2P) packet framing used between Eufy apps and HomeBases.
///
/// Every datagram is `F1 <type> <payload length, UInt16 BE> <payload>`.
/// Ported from eufy-sdk (Apache-2.0, github.com/mega-yfue/eufy-sdk, src/transport/p2p/codec.ts).
public enum PPPPMessage {
    public enum Request {
        public static let localLookup: UInt8 = 0x30
        public static let checkCam: UInt8 = 0x41
        public static let ping: UInt8 = 0xE0
        public static let pong: UInt8 = 0xE1
        public static let data: UInt8 = 0xD0
        public static let ack: UInt8 = 0xD1
        public static let end: UInt8 = 0xF0
    }

    public enum Response {
        /// Same byte as CAM_ID's request; before connecting it means "a device answered the lookup".
        public static let localLookupResponse: UInt8 = 0x41
        public static let camID: UInt8 = 0x42
        public static let camAddress: UInt8 = 0x43
        public static let turnServerCamID: UInt8 = 0x84
        public static let ping: UInt8 = 0xE0
        public static let pong: UInt8 = 0xE1
        public static let data: UInt8 = 0xD0
        public static let ack: UInt8 = 0xD1
        public static let end: UInt8 = 0xF0
    }

    public static let magic: UInt8 = 0xF1
    /// UDP port HomeBases listen on for local lookups.
    public static let lookupPort: UInt16 = 32108

    public static func frame(_ type: UInt8, payload: Data = Data()) -> Data {
        var out = Data([magic, type])
        out.append(UInt8(truncatingIfNeeded: payload.count >> 8))
        out.append(UInt8(truncatingIfNeeded: payload.count))
        out.append(payload)
        return out
    }

    /// The message type byte, or nil when the datagram isn't PPPP.
    public static func type(of datagram: Data) -> UInt8? {
        guard datagram.count >= 2, datagram[datagram.startIndex] == magic else { return nil }
        return datagram[datagram.startIndex + 1]
    }

    public static func localLookup() -> Data {
        frame(Request.localLookup, payload: Data([0x00, 0x00]))
    }

    /// CHECK_CAM: the station's 20-byte P2P id followed by three zero bytes.
    public static func checkCam(p2pDID: String) throws -> Data {
        frame(Request.checkCam, payload: try encode(p2pDID: p2pDID) + Data([0, 0, 0]))
    }

    public enum EncodingError: Error, Equatable {
        case invalidP2PDID
    }

    /// `PREFIX-123456-SUFFIX` → 8-byte prefix, UInt32 BE number, 8-byte suffix (strings zero-padded).
    public static func encode(p2pDID: String) throws -> Data {
        let parts = p2pDID.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3, let number = UInt32(parts[1]),
              parts[0].utf8.count <= 8, parts[2].utf8.count <= 8 else { throw EncodingError.invalidP2PDID }
        func padded(_ s: Substring) -> Data {
            var d = Data(s.utf8)
            d.append(Data(count: 8 - d.count))
            return d
        }
        var out = padded(parts[0])
        out.append(contentsOf: [UInt8(number >> 24 & 0xFF), UInt8(number >> 16 & 0xFF), UInt8(number >> 8 & 0xFF), UInt8(number & 0xFF)])
        out.append(padded(parts[2]))
        return out
    }

    /// Reverse of `encode`: reads a 20-byte DID structure back into `PREFIX-123456-SUFFIX`.
    /// Used to read the DID a HomeBase announces in its lookup reply, so we never need the cloud for it.
    public static func decodeP2PDID(_ payload: Data) -> String? {
        guard payload.count >= 20 else { return nil }
        let bytes = Array(payload.prefix(20))
        func string(_ slice: ArraySlice<UInt8>) -> String {
            String(decoding: slice.prefix { $0 != 0 }, as: UTF8.self)
        }
        let prefix = string(bytes[0..<8])
        let number = (UInt32(bytes[8]) << 24) | (UInt32(bytes[9]) << 16) | (UInt32(bytes[10]) << 8) | UInt32(bytes[11])
        let suffix = string(bytes[12..<20])
        guard !prefix.isEmpty, !suffix.isEmpty else { return nil }
        return "\(prefix)-\(String(format: "%06d", number))-\(suffix)"
    }

    /// The DID a lookup reply carries in its payload (after the 4-byte header), if any.
    public static func announcedDID(in datagram: Data) -> String? {
        guard datagram.count >= 4 + 20 else { return nil }
        return decodeP2PDID(datagram.dropFirst(4))
    }

    // MARK: Command channel

    /// The four data channels a DATA packet can carry.
    public enum DataKind: UInt8 { case data = 0, video = 1, control = 2, binary = 3 }

    /// `XZYH` — the marker that precedes a command id inside a DATA body.
    static let commandMagic = Data("XZYH".utf8)
    public static let stationChannel: UInt8 = 255

    /// A command header: `<kind d1,k> <seq BE> XZYH <cmd LE>`.
    public static func commandHeader(seq: UInt16, commandType: UInt16, kind: DataKind = .data) -> Data {
        var out = Data([0xD1, kind.rawValue])
        out.append(UInt8(seq >> 8)); out.append(UInt8(truncatingIfNeeded: seq))
        out.append(commandMagic)
        out.append(UInt8(truncatingIfNeeded: commandType)); out.append(UInt8(commandType >> 8))
        return out
    }

    /// The fixed "void" payload used by control commands that carry only a channel.
    public static func voidCommandPayload(channel: UInt8) -> Data {
        Data([0x00, 0x00, 0x00, 0x00, 0x01, 0x00, channel, 0x00, 0x00, 0x00])
    }

    /// A string-valued command payload, optionally AES-128-ECB encrypted under `key` (level 1).
    public static func stringCommandPayload(_ value: String, channel: UInt8, key: Data? = nil, encType: UInt8 = 1) -> Data {
        let raw = Data(value.utf8)
        let encrypted = key?.count == 16
        let data = encrypted ? encryptECB(pad16(raw), key: key!) : raw
        var out = Data([UInt8(truncatingIfNeeded: data.count), UInt8(data.count >> 8)])
        out.append(contentsOf: [0x00, 0x00, 0x01, 0x00, channel, encrypted ? encType : 0x00, 0x00, 0x00])
        out.append(data)
        return out
    }

    /// An ACK payload: `<kind d1,k> <count=1 BE> <seq BE>`.
    public static func ackPayload(kind: DataKind, seq: UInt16) -> Data {
        Data([0xD1, kind.rawValue, 0x00, 0x01, UInt8(seq >> 8), UInt8(truncatingIfNeeded: seq)])
    }

    /// The level-1 command key: last 7 chars of the station serial + 9 chars of the DID from its first "-".
    public static func commandKey(stationSerial: String, p2pDID: String) -> Data? {
        guard let dash = p2pDID.firstIndex(of: "-") else { return nil }
        let didPart = p2pDID[dash...].prefix(9)
        let key = String(stationSerial.suffix(7)) + didPart
        let data = Data(key.utf8)
        return data.count == 16 ? data : nil
    }

    static func pad16(_ data: Data) -> Data {
        let size = data.count < 16 ? 16 : (data.count + 15) / 16 * 16
        var out = data
        out.append(Data(count: size - data.count))
        return out
    }
}
