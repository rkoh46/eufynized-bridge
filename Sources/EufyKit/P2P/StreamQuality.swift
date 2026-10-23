import Foundation

/// A live-view quality level. `auto` lets the camera ramp its resolution with the link (its default).
public enum StreamQuality: String, CaseIterable, Codable, Sendable {
    case auto, hd720, fullHD, twoK, max

    public var label: String {
        switch self {
        case .auto: "Auto"
        case .hd720: "720p"
        case .fullHD: "1080p"
        case .twoK: "2K"
        case .max: "Max"
        }
    }
}

/// How one camera model takes its live-view quality, and which levels it offers.
///
/// This is the camera's own "Streaming Quality" setting (the official app's picker), not a per-session
/// option: it persists on the camera and applies to every live view, the Eufy app's included. Recording
/// quality is a separate setting and is left alone.
public struct StreamQualityProfile: Sendable, Equatable {
    public enum Wire: Sendable, Equatable {
        /// CMD_SET_PAYLOAD (1350) with inner cmd 2730 (`multicamSetVideoQuailty`): SoloCam S340, Indoor Cam E30.
        case setPayload2730
        /// CMD_BAT_DOORBELL_VIDEO_QUALITY (1705), a level-2 binary struct: eufyCam 3 / S3 Pro family.
        case videoQuality1705
    }

    public let wire: Wire
    /// Levels in menu order, each with its wire value.
    public let levels: [(quality: StreamQuality, value: Int)]

    public var options: [StreamQuality] { levels.map(\.quality) }

    public func value(for quality: StreamQuality) -> Int? {
        levels.first { $0.quality == quality }?.value
    }

    /// The profile for a model or serial (by its 5-character prefix), or nil if the model has no known
    /// streaming-quality setting (e.g. eufyCam 2C).
    public static func forModel(_ modelOrSerial: String) -> StreamQualityProfile? {
        guard modelOrSerial.count >= 5 else { return nil }
        switch String(modelOrSerial.prefix(5)).uppercased() {
        case "T8170":   // SoloCam S340: Auto / 720p / 1080p / 3K
            return .init(wire: .setPayload2730, levels: [(.auto, 0), (.hd720, 1), (.fullHD, 2), (.max, 3)])
        case "T8417":   // Indoor Cam E30: Auto / 720p / 1080p / 2K / 4K
            return .init(wire: .setPayload2730, levels: [(.auto, 0), (.hd720, 1), (.fullHD, 2), (.twoK, 3), (.max, 4)])
        case "T8160", "T8161", "T8162":   // eufyCam 3 / 3C / S3 Pro, high-encoding (H.265) values
            return .init(wire: .videoQuality1705, levels: [(.auto, 5), (.hd720, 6), (.fullHD, 7), (.twoK, 8), (.max, 10)])
        default:
            return nil
        }
    }

    public static func == (a: StreamQualityProfile, b: StreamQualityProfile) -> Bool {
        a.wire == b.wire && a.levels.elementsEqual(b.levels) { $0.quality == $1.quality && $0.value == $1.value }
    }
}

extension PPPPMessage {
    /// The 2730 streaming-quality SET_PAYLOAD envelope JSON for a HomeBase camera.
    public static func streamQuality2730JSON(channel: UInt8, accountID: String, value: Int,
                                             now: Date = Date()) -> String {
        let transaction = Int(now.timeIntervalSince1970 * 1000)
        let inner = "{\"channel\":\(channel),\"mode\":0,\"primary_view\":0,\"quality\":\(value),\"transaction\":\"\(transaction)\"}"
        return "{\"account_id\":\"\(accountID)\",\"cmd\":2730,\"mChannel\":\(channel),\"mValue3\":0,\"payload\":\(inner)}"
    }

    /// The 1705 video-quality body: `[u32 channel LE][u32 value LE][account id, ASCII, zero-padded to 128]`.
    public static func videoQuality1705Payload(channel: UInt8, accountID: String, value: Int) -> Data {
        var out = Data()
        withUnsafeBytes(of: UInt32(channel).littleEndian) { out.append(contentsOf: $0) }
        withUnsafeBytes(of: UInt32(clamping: value).littleEndian) { out.append(contentsOf: $0) }
        var account = Data(accountID.utf8.prefix(128))
        account.append(Data(count: 128 - account.count))
        return out + account
    }
}

extension HomeBaseConnection {
    /// Writes a camera's live-view (streaming) quality: `value` is the wire value for `wire`, e.g. from
    /// `StreamQualityProfile.value(for:)`. Needs the session's level-2 key; works with or without a live stream.
    public func setStreamQuality(wire: StreamQualityProfile.Wire, value: Int, channel: UInt8,
                                 accountID: String, level2Key: Data) {
        switch wire {
        case .setPayload2730:
            sendSetPayload(PPPPMessage.streamQuality2730JSON(channel: channel, accountID: accountID, value: value),
                           channel: channel, level2Key: level2Key)
        case .videoQuality1705:
            sendLevel2Command(1705, channel: channel,
                              plaintext: PPPPMessage.videoQuality1705Payload(channel: channel, accountID: accountID, value: value),
                              level2Key: level2Key)
        }
    }
}
