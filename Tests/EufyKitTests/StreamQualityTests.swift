import Testing
import Foundation
@testable import EufyKit

@Test func picksStreamQualityProfileByModelOrSerial() {
    let s340 = StreamQualityProfile.forModel("T8170P0000000000")
    #expect(s340?.wire == .setPayload2730)
    #expect(s340?.options == [.auto, .hd720, .fullHD, .max])
    #expect(s340?.value(for: .twoK) == nil)

    let e30 = StreamQualityProfile.forModel("T8417")
    #expect(e30?.options == [.auto, .hd720, .fullHD, .twoK, .max])
    #expect(e30?.value(for: .max) == 4)

    let s3Pro = StreamQualityProfile.forModel("t8162abc")
    #expect(s3Pro?.wire == .videoQuality1705)
    #expect(s3Pro?.value(for: .auto) == 5)
    #expect(s3Pro?.value(for: .max) == 10)

    #expect(StreamQualityProfile.forModel("T8113") == nil)   // eufyCam 2C: no streaming-quality setting
    #expect(StreamQualityProfile.forModel("T81") == nil)
}

@Test func buildsStreamQuality2730Envelope() throws {
    let json = PPPPMessage.streamQuality2730JSON(channel: 6, accountID: "acct", value: 2,
                                                 now: Date(timeIntervalSince1970: 1.5))
    let object = try #require(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
    #expect(object["cmd"] as? Int == 2730)
    #expect(object["mChannel"] as? Int == 6)
    #expect(object["mValue3"] as? Int == 0)
    #expect(object["account_id"] as? String == "acct")
    let payload = try #require(object["payload"] as? [String: Any])
    #expect(payload["quality"] as? Int == 2)
    #expect(payload["channel"] as? Int == 6)
    #expect(payload["transaction"] as? String == "1500")
}

@Test func buildsVideoQuality1705Struct() {
    let body = PPPPMessage.videoQuality1705Payload(channel: 2, accountID: "abc", value: 7)
    #expect(body.count == 136)
    #expect(Array(body.prefix(8)) == [2, 0, 0, 0, 7, 0, 0, 0])
    #expect(Array(body[8..<11]) == Array("abc".utf8))
    #expect(body[11...].allSatisfy { $0 == 0 })
}
