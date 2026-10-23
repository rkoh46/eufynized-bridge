import Foundation

/// Builds the camera list from Home Assistant entities (fuatakgun/eufy_security) and go2rtc streams.
public enum CameraDiscovery {
    /// Uses Home Assistant for names, battery and stream control, and go2rtc for playback.
    ///
    /// The eufy_security integration names a camera's entities after one object id, e.g.
    /// `camera.driveway`, `sensor.driveway_stream_url`, `button.driveway_start_p2p_stream`.
    public static func cameras(states: [HomeAssistantClient.EntityState],
                               streams: [String: Go2RTCClient.Stream]) -> [Camera] {
        let byID = Dictionary(states.map { ($0.entity_id, $0) }, uniquingKeysWith: { a, _ in a })

        return states
            .filter { $0.entity_id.hasPrefix("camera.") }
            .compactMap { cam -> Camera? in
                let object = String(cam.entity_id.dropFirst("camera.".count))
                let streamURL = byID["sensor.\(object)_stream_url"]?.state
                let battery = byID["sensor.\(object)_battery_percentage"].flatMap { Int($0.state) }
                // Only Eufy cameras: each has at least one of these integration-specific entities.
                let eufyMarkers = ["sensor.\(object)_stream_url", "switch.\(object)_rtsp_stream",
                                   "sensor.\(object)_battery_percentage", "button.\(object)_start_p2p_stream"]
                guard eufyMarkers.contains(where: { byID[$0] != nil }) else { return nil }

                // P2P relay stream is named after the serial: rtsp://127.0.0.1:8554/T8162T0000000001
                let serial = streamURL.flatMap { URL(string: $0)?.lastPathComponent }
                let candidates = [serial, "\(object)_rtsp", cam.entity_id].compactMap { $0 }
                let stream = candidates.first { streams[$0] != nil }

                func usableButton(_ suffix: String) -> String? {
                    let id = "button.\(object)_\(suffix)"
                    guard let s = byID[id], s.state != "unavailable" else { return nil }
                    return id
                }
                // Only start/stop P2P when we're actually playing the P2P relay.
                let usesP2P = stream != nil && stream == serial

                return Camera(
                    id: cam.entity_id,
                    name: cam.attributes.friendly_name ?? object,
                    model: serial.flatMap(EufyModel.name(forSerialOrModel:)),
                    streamName: stream,
                    cameraEntity: cam.entity_id,
                    startButton: usesP2P ? usableButton("start_p2p_stream") : nil,
                    stopButton: usesP2P ? usableButton("stop_p2p_stream") : nil,
                    batteryPercent: battery
                )
            }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// Without Home Assistant: one camera per go2rtc stream, named as nicely as possible.
    public static func cameras(streams: [String: Go2RTCClient.Stream]) -> [Camera] {
        streams.keys.map { name in
            Camera(id: name, name: displayName(forStream: name),
                   model: EufyModel.name(forSerialOrModel: name), streamName: name)
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    static func displayName(forStream name: String) -> String {
        if let model = EufyModel.name(forSerialOrModel: name) {
            return "\(model) …\(name.suffix(4))"
        }
        var base = name
        if base.hasPrefix("camera.") { base = String(base.dropFirst("camera.".count)) }
        var suffix = ""
        if base.hasSuffix("_rtsp") { base = String(base.dropLast("_rtsp".count)); suffix = " (RTSP)" }
        return base.split(separator: "_").map { $0.capitalized }.joined(separator: " ") + suffix
    }
}
