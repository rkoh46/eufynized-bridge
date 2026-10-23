import Foundation

/// Whether a camera can stream right now, as its HomeBase reports it: param 1131 ("State") in the camera's
/// own settings report (1103 reply or 1351 notify). Cloud-free. An unplugged Indoor Cam E30 reports 0 with
/// Wi-Fi signal (1142) -100 dBm; a working one 1 and about -30 dBm.
public enum CameraAvailability: Equatable, Sendable {
    case online
    case offline
    /// Switched off by the user (the app's camera on/off switch).
    case disabled
    case offlineLowBattery
    /// The HomeBase lost the pairing: the camera has to be removed and added again in the eufy app.
    case needsReAdd

    public init?(stateParam value: Int) {
        switch value {
        case 0: self = .offline
        case 1: self = .online
        case 2: self = .disabled
        case 3: self = .offlineLowBattery
        case 4, 5: self = .needsReAdd
        default: return nil
        }
    }

    /// From a parsed settings report (`CameraSettings.paramReport`); nil when it doesn't carry the state.
    public init?(params: [Int: String]) {
        guard let raw = params[1131], let value = Int(raw.trimmingCharacters(in: .whitespaces)) else { return nil }
        self.init(stateParam: value)
    }

    public var canStream: Bool { self == .online }

    public var title: String {
        switch self {
        case .online: "Online"
        case .offline: "Offline"
        case .disabled: "Turned off"
        case .offlineLowBattery: "Battery empty"
        case .needsReAdd: "Needs re-adding"
        }
    }

    public var advice: String {
        switch self {
        case .online: ""
        case .offline: "The HomeBase can't reach this camera. Check that it's powered and on Wi-Fi."
        case .disabled: "This camera is switched off. Turn it back on to watch it."
        case .offlineLowBattery: "The battery is flat. Charge the camera or check its solar panel."
        case .needsReAdd: "The HomeBase lost this camera's pairing. Remove it and add it again in the eufy app."
        }
    }

    public var systemImage: String {
        switch self {
        case .online: "video"
        case .offline: "wifi.slash"
        case .disabled: "video.slash"
        case .offlineLowBattery: "battery.0percent"
        case .needsReAdd: "exclamationmark.triangle"
        }
    }
}

extension CameraAvailability {
    /// Opens a short stream to learn whether the camera can stream: `.online` as soon as video arrives,
    /// otherwise the state the HomeBase reports. nil when neither comes within `timeout`.
    public static func probe(_ config: EufyLiveStream.Config, timeout: Duration = .seconds(14)) async -> CameraAvailability? {
        let box = ProbeBox()
        var config = config
        config.audio = false
        #if canImport(CoreMedia)
        let stream = EufyLiveStream(config: config, onSample: { _ in box.finish(.online) })
        #else
        let stream = EufyLiveStream(config: config)
        stream.onVideoFrame = { _, _, _, _ in box.finish(.online) }
        #endif
        stream.onAvailability = { box.finish($0) }
        return await withCheckedContinuation { (continuation: CheckedContinuation<CameraAvailability?, Never>) in
            box.install(continuation) { stream.stop() }
            stream.start()
            Task {
                try? await Task.sleep(for: timeout)
                box.finish(nil)
            }
        }
    }
}

/// Resumes the probe once, with whichever answer comes first, then stops its stream.
private final class ProbeBox: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<CameraAvailability?, Never>?
    private var cleanup: (() -> Void)?

    func install(_ c: CheckedContinuation<CameraAvailability?, Never>, cleanup: @escaping () -> Void) {
        lock.withLock { continuation = c; self.cleanup = cleanup }
    }

    func finish(_ value: CameraAvailability?) {
        let (c, done) = lock.withLock { () -> (CheckedContinuation<CameraAvailability?, Never>?, (() -> Void)?) in
            defer { continuation = nil; cleanup = nil }
            return (continuation, cleanup)
        }
        guard let c else { return }
        done?()
        c.resume(returning: value)
    }
}
