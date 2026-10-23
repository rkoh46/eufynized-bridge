import Foundation
import EufynizedKit

// Lists the cameras Eufynized would show, without the UI.
// Usage: eufynized-probe <go2rtc-url>
// Optional: EUFYNIZED_HA_URL and EUFYNIZED_HA_TOKEN to include Home Assistant.

guard CommandLine.arguments.count > 1, let go2rtcURL = URL(string: CommandLine.arguments[1]) else {
    print("usage: eufynized-probe <go2rtc-url>   e.g. http://homeassistant.local:1984")
    exit(2)
}

let go2rtc = Go2RTCClient(baseURL: go2rtcURL)
let env = ProcessInfo.processInfo.environment

do {
    let streams = try await go2rtc.streams()
    let cameras: [Camera]
    if let ha = env["EUFYNIZED_HA_URL"].flatMap(URL.init(string:)), let token = env["EUFYNIZED_HA_TOKEN"] {
        cameras = CameraDiscovery.cameras(states: try await HomeAssistantClient(baseURL: ha, token: token).states(),
                                          streams: streams)
    } else {
        cameras = CameraDiscovery.cameras(streams: streams)
    }
    print("\(streams.count) go2rtc streams, \(cameras.count) cameras:")
    for camera in cameras {
        let battery = camera.batteryPercent.map { " battery \($0)%" } ?? ""
        print("- \(camera.name) [\(camera.model ?? "?")]\(battery)")
        print("    stream: \(camera.streamName ?? "none")")
        if let stream = camera.streamName {
            print("    player: \(go2rtc.playerURL(for: stream).absoluteString)")
        }
        if let start = camera.startButton { print("    wake:   \(start)") }
    }
} catch {
    print("error: \(error.localizedDescription)")
    exit(1)
}
