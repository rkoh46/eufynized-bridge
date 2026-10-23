import Foundation

/// Pan-tilt-zoom control for cameras that support it (e.g. SoloCam S340 / T8170).
public enum PTZDirection: Int, Sendable, CaseIterable {
    case left = 1, right = 2, up = 3, down = 4

    public var symbolName: String {
        switch self {
        case .left: "arrow.left"
        case .right: "arrow.right"
        case .up: "arrow.up"
        case .down: "arrow.down"
        }
    }
}

/// A pan-tilt camera's saved positions (the S340 keeps four): jump to one, save the current position as one, or
/// forget one. eufy-security-client sends these through the 1700 payload with `{"value": index}` (0–3).
public enum PTZPresetAction: String, Sendable { case go, save, delete }

extension PPPPMessage {
    /// `{commandType: 6035|6032|6033, data: {value: index}}`: go to / save / delete a preset position.
    public static func ptzPresetJSON(_ action: PTZPresetAction, index: Int) -> String {
        let command = switch action { case .go: 6035; case .save: 6032; case .delete: 6033 }
        return "{\"commandType\":\(command),\"data\":{\"value\":\(index)}}"
    }

    /// Command id for a PTZ rotate, carried inside the 1700 control-payload wrapper.
    static let ptzRotateCommand = 6030

    /// The JSON body for a PTZ rotate: `{commandType:6030, data:{cmd_type:1, rotate_type:N, zoom}}`.
    /// Matches the app's JSON byte for byte (JavaScript prints a whole-number zoom as `1`, not `1.0`).
    public static func ptzRotateJSON(_ direction: PTZDirection, zoom: Double = 1.0) -> String {
        let zoomText = zoom.rounded() == zoom ? String(Int(zoom)) : String(zoom)
        return "{\"commandType\":\(ptzRotateCommand),\"data\":{\"cmd_type\":1,\"rotate_type\":\(direction.rawValue),\"zoom\":\(zoomText)}}"
    }

    /// Control-payload command id (the 1700 wrapper) PTZ and live-control commands ride on.
    public static let controlPayloadCommand: UInt16 = 1700

    /// Decrypts a CMD_GATEWAYINFO (1100) reply, which arrives AES-128-ECB encrypted under the level-1 key.
    /// Decrypted layout: `cipher_id(2 LE) ‖ 0000 ‖ ECIES-envelope(129) ‖ padding`.
    public static func decryptGatewayInfo(_ payload: Data, level1Key: Data) -> Data {
        decryptECB(payload, key: level1Key)
    }

    /// The `cipher_id` from a decrypted gateway-info payload — what `get_ciphers` looks up for the ECC key.
    public static func gatewayInfoCipherID(decrypted: Data) -> Int? {
        guard decrypted.count >= 2 else { return nil }
        let b = Array(decrypted.prefix(2))
        return Int(b[0]) | Int(b[1]) << 8
    }

    /// The ECIES envelope inside a decrypted gateway-info payload (offset 4, 129 bytes) — unwrapped with
    /// the station's ECC key to derive the level-2 command key.
    public static func gatewayInfoEnvelope(decrypted: Data) -> Data? {
        guard decrypted.count >= 4 + 129 else { return nil }
        return decrypted.subdata(in: 4 ..< 4 + 129)
    }
}
