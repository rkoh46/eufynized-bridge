import Testing
import Foundation
@testable import EufyKit

@Test func stateParamMapsToAvailability() {
    #expect(CameraAvailability(stateParam: 1) == .online)
    #expect(CameraAvailability(stateParam: 0) == .offline)
    #expect(CameraAvailability(stateParam: 2) == .disabled)
    #expect(CameraAvailability(stateParam: 3) == .offlineLowBattery)
    #expect(CameraAvailability(stateParam: 4) == .needsReAdd)
    #expect(CameraAvailability(stateParam: 5) == .needsReAdd)
    #expect(CameraAvailability(stateParam: 9) == nil)
}

@Test func unpluggedCameraReportReadsOffline() {
    // The Kids Room E30's own 1103 reply while unplugged: state 0, Wi-Fi -100 dBm.
    let reply = #"{"params":[{"param_type":1131,"param_value":0},{"param_type":1142,"param_value":-100}]}"#
    let params = CameraSettingsCatalog.paramReport(Data(reply.utf8))
    #expect(params.flatMap(CameraAvailability.init(params:)) == .offline)
    #expect(CameraAvailability.offline.canStream == false)
    #expect(CameraAvailability.online.canStream)
}

@Test func reportWithoutStateSaysNothing() {
    #expect(CameraAvailability(params: [1142: "-30"]) == nil)
}
