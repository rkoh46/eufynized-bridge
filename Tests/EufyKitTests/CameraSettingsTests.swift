import Testing
import Foundation
@testable import EufyKit

private func setting(_ id: String, deviceType: Int = 105) -> CameraSetting {
    CameraSettingsCatalog.settings(forDeviceType: deviceType).first { $0.id == id }!
}

@Test func catalogCoversTheOwnedCameraTypes() {
    for type in [8, 26, 48, 105] {
        let settings = CameraSettingsCatalog.settings(forDeviceType: type)
        #expect(settings.count > 20, "device type \(type)")
        #expect(settings.allSatisfy { CameraSettingsCatalog.groupOrder.contains($0.group) })
    }
    #expect(CameraSettingsCatalog.settings(forDeviceType: 9999).isEmpty)
}

@Test func decodesPlainValues() {
    // Values as Kodi Cam (Indoor Cam E30) reported them over the HomeBase.
    let params = [1214: "2", 1240: "1", 1230: "80", 6014: "0"]
    #expect(CameraSettingsCatalog.value(of: setting("watermark"), in: params) == .int(2))
    #expect(CameraSettingsCatalog.value(of: setting("microphone"), in: params) == .bool(true))
    #expect(CameraSettingsCatalog.value(of: setting("speakerVolume"), in: params) == .int(80))
    #expect(CameraSettingsCatalog.value(of: setting("statusLed"), in: params) == .bool(false))
    #expect(CameraSettingsCatalog.value(of: setting("motionDetection"), in: params) == nil)   // not reported
}

@Test func decodesPackedDetectionAndNotificationBits() {
    let params = [1298: "229387", 6027: "831"]   // 229387 = bits 1, 2, 8 and 32768 (as Front360 reported it)
    #expect(CameraSettingsCatalog.value(of: setting("motionDetectionTypeHuman"), in: params) == .bool(true))
    #expect(CameraSettingsCatalog.value(of: setting("motionDetectionTypePet"), in: params) == .bool(true))
    #expect(CameraSettingsCatalog.value(of: setting("motionDetectionTypeAllOtherMotions"), in: params) == .bool(true))
    #expect(CameraSettingsCatalog.isPacked(setting("motionDetectionTypeHuman")))
    #expect(!CameraSettingsCatalog.isPacked(setting("watermark")))
}

@Test func parsesCameraInfoReply() {
    let reply = Data(#"{"params":[{"param_type":1214,"param_value":2},{"param_type":1230,"param_value":"80"}]}"#.utf8) + Data([0, 0])
    #expect(CameraSettingsCatalog.paramReport(reply) == [1214: "2", 1230: "80"])
    #expect(CameraSettingsCatalog.paramReport(Data("not json".utf8)) == nil)
}

@Test func directBinaryBodyLayout() throws {
    let body = try #require(CameraSettingsCatalog.directBinaryBody(channel: 6, value: 1, accountID: "abc"))
    #expect(body.count == 136)
    #expect(Array(body.prefix(8)) == [6, 0, 0, 0, 1, 0, 0, 0])
    #expect(Array(body[8..<11]) == Array("abc".utf8))
    #expect(body[11...].allSatisfy { $0 == 0 })
    #expect(CameraSettingsCatalog.directBinaryBody(channel: 0, value: 1, accountID: "") == nil)
}

@Test func factoryResetCommandsAreForbidden() {
    #expect(CameraSettingsCatalog.forbiddenCommands.isSuperset(of: [1034, 1036, 1037]))
}

@Test func recipesFillPlaceholders() throws {
    // E30 audio recording goes out as the inverted record_mute in a SET_PAYLOAD envelope.
    let frames = try #require(CameraSettingsCatalog.writeFrames(for: setting("audioRecording"), deviceType: 105,
                                                                value: 1, channel: 6, accountID: "acct"))
    #expect(frames.count == 1)
    #expect(frames[0].form == .setPayload)
    #expect(frames[0].body.contains(#""account_id":"acct""#))
    #expect(frames[0].body.contains(#""channel":6"#))
    #expect(frames[0].body.contains(#""record_mute":0"#))
    #expect(!frames[0].body.contains("{"+"account}"))
}

@Test func statusLedOnHomeBaseUsesTheLedSwitchCommand() throws {
    // Read from 6014 on an E30, but written as CMD_DEV_LED_SWITCH (1045) behind a HomeBase.
    let frames = try #require(CameraSettingsCatalog.writeFrames(for: setting("statusLed"), deviceType: 105,
                                                                value: 0, channel: 6, accountID: "acct"))
    #expect(frames.map(\.command) == [1045])
    #expect(frames.map(\.body) == ["0"])
}

@Test func perValueRecipesMapToDeviceCodes() throws {
    // eufyCam 2C motion sensitivity 1…7 goes out as device codes, not the number itself.
    let s = setting("motionDetectionSensitivity", deviceType: 8)
    #expect(CameraSettingsCatalog.recipe(for: s, deviceType: 8)?.supportedValues == Array(1...7))
    let frames = try #require(CameraSettingsCatalog.writeFrames(for: s, deviceType: 8, value: 1, channel: 3, accountID: "a"))
    #expect(frames.map(\.body) == ["192"])
    #expect(CameraSettingsCatalog.writeFrames(for: s, deviceType: 8, value: 99, channel: 3, accountID: "a") == nil)
}

@Test func framesInvokingForbiddenCommandsAreRefused() {
    let hidden = CameraSettingWriteFrame(form: .setPayload, command: 1350,
                                         body: #"{"account_id":"a","cmd":1036,"mChannel":0,"payload":{}}"#)
    #expect(hidden.invokedCommands.contains(1036))
    #expect(!hidden.invokedCommands.isDisjoint(with: CameraSettingsCatalog.forbiddenCommands))
    let fine = CameraSettingWriteFrame(form: .control, command: 1700, body: #"{"commandType":6015,"data":{"value":1}}"#)
    #expect(fine.invokedCommands == [1700, 6015])
}

@Test func audioRecordingMuteParamDecodesInverted() {
    // 1288 is CMD_SET_AUDIO_MUTE_RECORD: "0" means recording is on (eufy-security-client reads it this way).
    let s = setting("audioRecording", deviceType: 26)
    #expect(CameraSettingsCatalog.value(of: s, in: [1288: "0"]) == .bool(true))
    #expect(CameraSettingsCatalog.value(of: s, in: [1288: "1"]) == .bool(false))
}

@Test func unlistedValuesUseTheFieldThatCarriesTheSetting() throws {
    // S3 Pro night vision: the library lists 0…2, the camera can report 6; the envelope also has "mValue3":0,
    // so the carrying field must be found across all captured values, not by matching the number once.
    let frames = try #require(CameraSettingsCatalog.writeFrames(for: setting("nightvision", deviceType: 26), deviceType: 26,
                                                                value: 6, channel: 2, accountID: "a"))
    #expect(frames.count == 1)
    #expect(frames[0].body.contains(#""night_sion":6"#))
    #expect(frames[0].body.contains(#""mValue3":0"#))
}

@Test func recordingSettingsGoOutAsStationScalars() throws {
    // Sent as direct values (with a channel field) these stalled the HomeBase; eufy-sdk's verified form is the
    // 132-byte station scalar [u32 value][account id], and 1251 is inverted (0 = end the clip early).
    let clip = try #require(CameraSettingsCatalog.writeFrames(for: setting("recordingClipLength", deviceType: 48),
                                                              deviceType: 48, value: 60, channel: 0, accountID: "a"))
    #expect(clip.map(\.form) == [.stationScalar])
    #expect(clip.map(\.command) == [1249])
    #expect(clip.map(\.body) == ["60"])
    let endEarly = setting("recordingEndClipMotionStops", deviceType: 48)
    let on = try #require(CameraSettingsCatalog.writeFrames(for: endEarly, deviceType: 48, value: 1, channel: 0, accountID: "a"))
    #expect(on.map(\.body) == ["0"])
    #expect(CameraSettingsCatalog.value(of: endEarly, in: [1251: "0"], deviceType: 48) == .bool(true))
    #expect(CameraSettingsCatalog.directBinaryBody(channel: nil, value: 60, accountID: "a")?.count == 132)
}

@Test func deviceCodesDecodeBackToSteps() {
    // The 2C stores motion sensitivity as the code its recipe writes: step 4 is 46, step 1 is 192.
    let s = setting("motionDetectionSensitivity", deviceType: 8)
    #expect(CameraSettingsCatalog.value(of: s, in: [1210: "46"], deviceType: 8) == .int(4))
    #expect(CameraSettingsCatalog.value(of: s, in: [1210: "192"], deviceType: 8) == .int(1))
    // The S3 Pro writes the step itself, so its value isn't remapped.
    let pro = setting("motionDetectionSensitivity", deviceType: 26)
    #expect(CameraSettingsCatalog.value(of: pro, in: [1210: "7"], deviceType: 26) == .int(7))
}

@Test func packedWritesFlipOnlyTheirBit() throws {
    // Kodi Cam reads 1298 = 196995; turning pets on adds bit 8 and leaves the rest alone.
    let pet = setting("motionDetectionTypePet")
    let frame = try #require(CameraSettingsCatalog.packedWriteFrame(for: pet, on: true, currentRaw: 196995, channel: 6, accountID: "a"))
    #expect(frame.body.contains(#""ai_detect_type":\#(196995 | 8)"#))
    // E30 notifications: 800 + a bit per type; all on is 831, turning people off clears bit 2.
    let person = setting("notificationPerson")
    let off = try #require(CameraSettingsCatalog.packedWriteFrame(for: person, on: false, currentRaw: 831, channel: 6, accountID: "a"))
    #expect(off.body.contains(#""onoff":829"#))
    #expect(CameraSettingsCatalog.value(of: person, in: [6027: "831"]) == .bool(true))
    #expect(CameraSettingsCatalog.value(of: person, in: [6027: "829"]) == .bool(false))
}

@Test func cameraOnOffDecodesInverted() {
    // 1035 / 6250: "0" means the camera is on.
    let enabled = setting("enabled", deviceType: 26)
    #expect(CameraSettingsCatalog.value(of: enabled, in: [1035: "0"], deviceType: 26) == .bool(true))
}

@Test func statusValuesAreNotControls() {
    #expect(CameraSettingsCatalog.isStatus(setting("wifiRssi"), deviceType: 105))
    #expect(CameraSettingsCatalog.isStatus(setting("powerSource", deviceType: 48), deviceType: 48))
    #expect(!CameraSettingsCatalog.isStatus(setting("powerSource", deviceType: 26), deviceType: 26))
    #expect(CameraSettingsCatalog.isEditable(setting("motionDetectionTypeHuman", deviceType: 26), deviceType: 26))
}
