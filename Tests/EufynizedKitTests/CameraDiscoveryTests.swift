import Testing
import Foundation
@testable import EufynizedKit

private typealias State = HomeAssistantClient.EntityState
private let stream = Go2RTCClient.Stream(producers: [.init(url: "tcp://127.0.0.1:65535")])

@Test func batteryCameraUsesP2PRelayAndWakeButtons() {
    let states = [
        State(entity_id: "camera.driveway", state: "idle", friendlyName: "Driveway"),
        State(entity_id: "sensor.driveway_stream_url", state: "rtsp://127.0.0.1:8554/T8162T0000000001"),
        State(entity_id: "sensor.driveway_battery_percentage", state: "100"),
        State(entity_id: "button.driveway_start_p2p_stream", state: "2026-01-04T03:18:09+00:00"),
        State(entity_id: "button.driveway_stop_p2p_stream", state: "2026-01-04T03:20:00+00:00"),
    ]
    let cameras = CameraDiscovery.cameras(states: states, streams: ["T8162T0000000001": stream])

    #expect(cameras.count == 1)
    let cam = cameras[0]
    #expect(cam.name == "Driveway")
    #expect(cam.model == "eufyCam S3 Pro")
    #expect(cam.streamName == "T8162T0000000001")
    #expect(cam.startButton == "button.driveway_start_p2p_stream")
    #expect(cam.stopButton == "button.driveway_stop_p2p_stream")
    #expect(cam.batteryPercent == 100)
}

@Test func wiredCameraFallsBackToRTSPStreamWithoutWaking() {
    let states = [
        State(entity_id: "camera.living_room", state: "idle", friendlyName: "Living Room"),
        State(entity_id: "switch.living_room_rtsp_stream", state: "on"),
        State(entity_id: "button.living_room_start_p2p_stream", state: "unknown"),
    ]
    let cameras = CameraDiscovery.cameras(states: states, streams: ["living_room_rtsp": stream])

    #expect(cameras.first?.streamName == "living_room_rtsp")
    #expect(cameras.first?.startButton == nil)
    #expect(cameras.first?.isBatteryPowered == false)
}

@Test func batteryOnlyCameraFallsBackToHomeAssistantStream() {
    // e.g. a SoloCam with no stream URL sensor or RTSP switch
    let states = [
        State(entity_id: "camera.front360", state: "idle", friendlyName: "Front360"),
        State(entity_id: "sensor.front360_battery_percentage", state: "97"),
    ]
    let cam = CameraDiscovery.cameras(states: states, streams: ["camera.front360": stream]).first
    #expect(cam?.streamName == "camera.front360")
    #expect(cam?.batteryPercent == 97)
}

@Test func ignoresNonEufyCameras() {
    let states = [State(entity_id: "camera.doorbell_other_brand", state: "idle")]
    #expect(CameraDiscovery.cameras(states: states, streams: [:]).isEmpty)
}

@Test func unavailableWakeButtonIsSkipped() {
    let states = [
        State(entity_id: "camera.front", state: "idle"),
        State(entity_id: "sensor.front_stream_url", state: "rtsp://127.0.0.1:8554/T8170T0000000002"),
        State(entity_id: "button.front_start_p2p_stream", state: "unavailable"),
    ]
    let cam = CameraDiscovery.cameras(states: states, streams: ["T8170T0000000002": stream]).first
    #expect(cam?.startButton == nil)
    #expect(cam?.model == "SoloCam S340")
}

@Test func streamOnlyNames() {
    #expect(CameraDiscovery.displayName(forStream: "living_room_rtsp") == "Living Room (RTSP)")
    #expect(CameraDiscovery.displayName(forStream: "camera.back_laundry") == "Back Laundry")
    #expect(CameraDiscovery.displayName(forStream: "T8417T0000000003") == "Indoor Cam E30 …0003")
}

@Test func detectsUnstartedEufyP2PStream() {
    #expect(stream.isWaitingForEufyP2P)
    #expect(!stream.isReceiving)
    let live = Go2RTCClient.Stream(producers: [.init(url: Go2RTCClient.Stream.eufyPlaceholderURL), .init(bytes_recv: 1_608_017)])
    #expect(!live.isWaitingForEufyP2P)
    #expect(live.isReceiving)
    let rtsp = Go2RTCClient.Stream(producers: [.init(url: "rtsp://camera.local/live0")])
    #expect(!rtsp.isWaitingForEufyP2P)
}

@Test func playerAndRTSPURLs() {
    let client = Go2RTCClient(baseURL: URL(string: "http://pi.local:1984")!)
    #expect(client.playerURL(for: "T8162T1").absoluteString == "http://pi.local:1984/stream.html?src=T8162T1&mode=webrtc,mse,hls")
    #expect(client.rtspURL(for: "T8162T1")?.absoluteString == "rtsp://pi.local:8554/T8162T1")
}
