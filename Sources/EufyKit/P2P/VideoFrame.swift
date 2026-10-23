import Foundation

/// The header on each `CMD_VIDEO_FRAME` (1300) payload. The header is in the clear; the frame body is
/// encrypted (keyframes carry an ECIES envelope unlocked by the camera's ECC key). Ported from eufy-sdk.
public struct VideoFrameHeader: Sendable, Equatable {
    public var payloadLength: UInt32
    /// True when the frame is a keyframe carrying the ECIES key envelope.
    public var keyframe: Bool
    public var flags: UInt8
    public var sequence: UInt16
    public var width: Int
    public var height: Int
    public var timestamp: UInt32

    static let headerLength = 0x12

    public init?(_ payload: Data) {
        guard payload.count >= Self.headerLength else { return nil }
        let b = Array(payload)
        func u16(_ o: Int) -> UInt16 { UInt16(b[o]) | UInt16(b[o + 1]) << 8 }
        func u32(_ o: Int) -> UInt32 { UInt32(b[o]) | UInt32(b[o + 1]) << 8 | UInt32(b[o + 2]) << 16 | UInt32(b[o + 3]) << 24 }
        func s16(_ o: Int) -> Int { Int(Int16(bitPattern: u16(o))) }
        payloadLength = u32(0x00)
        flags = b[0x04]
        keyframe = (flags & 0x01) == 1
        sequence = u16(0x06)
        width = s16(0x0a)
        height = s16(0x0c)
        timestamp = u32(0x0e)
    }

    public var resolution: String { "\(width)x\(height)" }
}
