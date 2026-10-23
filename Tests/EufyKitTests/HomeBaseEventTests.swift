import Testing
import Foundation
@testable import EufyKit

/// The shape a HomeBase 3 announced for a Living Room event: the inner payload is a JSON *string*.
private func announcement(type: Int, channel: Int = 4) -> Data {
    let inner = #"{"msg_type":18,"event_type":\#(type),"device_sn":"T8417T0000000003","name":"Living Room","channel":\#(channel),"cipher":0,"create_time":1792634013432,"trigger_time":1792634013432,"file_path":"/zx/hdd_data0/Camera04/202610/20261021185333/20261021185333.zxvideo","pic_url":"","pic_filepath":"/zx/hdd_data0/Camera04/202610/20261021185333/20261021185333.jpg"}"#
    let outer: [String: Any] = ["cmd": 2037, "payload": inner]
    return try! JSONSerialization.data(withJSONObject: outer) + Data([0, 0])
}

@Test func parsesTheHomeBasesEventAnnouncement() throws {
    let event = try #require(HomeBaseLiveEvent.parse(announcement(type: 3111)))
    #expect(event.cameraName == "Living Room")
    #expect(event.channel == 4)
    #expect(event.deviceSerial == "T8417T0000000003")
    #expect(event.kind == .person)
    #expect(event.title == "Known person")
    #expect(event.triggerTime == Date(timeIntervalSince1970: 1792634013.432))
    #expect(event.snapshotPath?.hasSuffix(".jpg") == true)
    #expect(event.clipPath?.hasSuffix(".zxvideo") == true)
}

@Test func mapsEventTypesToKinds() throws {
    let kinds: [Int: HomeBaseLiveEvent.Kind] = [3101: .motion, 3102: .person, 3103: .doorbell, 3105: .sound,
                                                3106: .pet, 3107: .vehicle, 3112: .person, 3199: .motion]
    for (type, kind) in kinds {
        #expect(try #require(HomeBaseLiveEvent.parse(announcement(type: type))).kind == kind, "event_type \(type)")
    }
}

@Test func ignoresOtherNotifications() {
    let storage = Data(#"{"cmd":1307,"payload":{"cmd":11001,"version":0}}"#.utf8)
    #expect(HomeBaseLiveEvent.parse(storage) == nil)
    #expect(HomeBaseLiveEvent.parse(Data(#"{"cmd":6246,"payload":{"num":1}}"#.utf8)) == nil)
}
