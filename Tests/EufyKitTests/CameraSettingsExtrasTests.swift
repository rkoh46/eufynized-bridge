import Testing
@testable import EufyKit

@Test func eufyCam3PowerSettingsAreEditable() {
    let list = CameraSettingsCatalog.settings(forDeviceType: 26)
    let power = try! #require(list.first { $0.id == "powerSourceMode" })
    #expect(CameraSettingsCatalog.isEditable(power, deviceType: 26))
    let frames = CameraSettingsCatalog.writeFrames(for: power, deviceType: 26, value: 2, channel: 1, accountID: "abc")
    #expect(frames?.count == 1)
    #expect(frames?.first?.body.contains("\"source\":2") == true)
    let cont = try! #require(list.first { $0.id == "continuousRecording" })
    #expect(CameraSettingsCatalog.isEditable(cont, deviceType: 26))
    #expect(CameraSettingsCatalog.merging([1101: "90"], remembered: [6445: 2])[6445] == "2")
}

@Test func labelsHaveNoDuplicateKeys() {
    // A duplicate key in the labels literal traps at first use (it took the bridge down on 2026-10-23).
    #expect(CameraSettingsCatalog.displayLabel(CameraSettingsCatalog.settings(forDeviceType: 26).first!) != "")
}
