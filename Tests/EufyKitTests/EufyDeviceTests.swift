import Testing
import Foundation
@testable import EufyKit

/// A device-list entry with the given param 1295 (privacy zone) value.
private func camera(privacyParam: String?) -> EufyDevice? {
    var params: [[String: Any]] = [["param_type": 1045, "param_value": "1"]]
    if let privacyParam { params.append(["param_type": 1295, "param_value": privacyParam]) }
    return EufyDevice(json: ["device_sn": "T8417T0000000000", "device_name": "Cam", "device_model": "T8417",
                             "device_type": 105, "params": params])
}

@Test func privacyZoneWithRectanglesIsOn() {
    // Two masked rectangles, as the Living Room E30 reports them.
    let zones = #"{"points":[{"LeftPointX":784,"LeftPointY":99,"RightPointY":448,"RightPointX":999},{"LeftPointX":772,"LeftPointY":406,"RightPointY":824,"RightPointX":975}]}"#
    #expect(camera(privacyParam: Data(zones.utf8).base64EncodedString())?.hasPrivacyZone == true)
}

@Test func privacyZoneWithoutRectanglesIsOff() {
    #expect(camera(privacyParam: "eyJwb2ludHMiOltdfQ==")?.hasPrivacyZone == false)   // {"points":[]}
}

@Test func privacyZoneUnknownWhenNotReported() {
    #expect(camera(privacyParam: nil)?.hasPrivacyZone == nil)
    #expect(camera(privacyParam: "not base64")?.hasPrivacyZone == nil)
}

@Test func e30IsPanTiltByDeviceType() {
    #expect(EufyModels.isPanTilt("T8417", deviceType: 105))
    #expect(!EufyModels.isPanTilt("T8162", deviceType: 26))   // eufyCam S3 Pro
}

@Test func firmwareVersionsComeFromTheDeviceList() {
    let device = EufyDevice(json: ["device_sn": "T8030T0000000000", "device_model": "T8030",
                                   "main_sw_version": "3.7.4.3", "sec_sw_version": ""])
    #expect(device?.firmwareVersion == "3.7.4.3")
    #expect(device?.secondaryFirmwareVersion == nil)   // blank means not reported
}

@Test func storedInFileCheckNeverFindsAMissingAccount() {
    // The unattended health check relies on this to skip, rather than fall back to the Keychain.
    #expect(!SecretStore.isStoredInFile("eufy-test:never-written-\(UUID().uuidString)"))
}
