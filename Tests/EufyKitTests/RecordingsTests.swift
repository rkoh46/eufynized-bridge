import Testing
import Foundation
import CryptoKit
@testable import EufyKit

// A `CMD_DATABASE` reply as a HomeBase 3 sends it (one row, trimmed to the fields the app reads), with the
// NUL terminator and the trailing padding bytes the level-1 decrypt leaves behind.
private let queryReply = Data("""
{"cmd":10006,"count":1000,"data":[{"device_sn":"T8417T0000000003","end_time":"2026-10-20 18:10:51","folder_size":2179472,\
"frame_num":167,"record_id":2026102001376,"start_time":"2026-10-20 18:10:40",\
"storage_path":"/zx/hdd_data1/Camera04/202610/20261020181042/20261020181042.zxvideo",\
"thumb_path":"/zx/hdd_data1/Camera04/202610/20261020181042/snapshort.jpg","time_zone":"-0700","trigger_type":4}],\
"mIntRet":0,"msg":"SUCCESSFUL","table":"history_record_info"}
""".utf8) + Data([0, 0x76, 0xfa])

@Test func parsesEventQueryReply() throws {
    let parsed = try #require(EufyEvent.parseQueryReply(queryReply))
    #expect(parsed.result == 0)
    let event = try #require(parsed.events.first)
    #expect(event.recordID == 2026102001376)
    #expect(event.deviceSerial == "T8417T0000000003")
    #expect(event.channel == 4)
    #expect(event.kind == .person)
    #expect(event.frameCount == 167)
    #expect(event.thumbnailPath == "/zx/hdd_data1/Camera04/202610/20261020181042/snapshort.jpg")
    // 18:10:40 at UTC-7 is 01:10:40 UTC the next day.
    #expect(event.startTime == Date(timeIntervalSince1970: 1_792_545_040))
    #expect(event.duration == 11)
}

@Test func incompleteQueryReplyIsNotParsed() {
    #expect(EufyEvent.parseQueryReply(queryReply.prefix(200)) == nil)
}

@Test func queryReplyCarriesStationError() throws {
    let parsed = try #require(EufyEvent.parseQueryReply(Data(#"{"mIntRet":-6006,"msg":"ERROR_NO_SUPPORT"}"#.utf8)))
    #expect(parsed.result == -6006)
    #expect(parsed.events.isEmpty)
}

@Test func triggerTypesMapToKinds() {
    func kind(_ t: Int) -> EufyEvent.Kind {
        EufyEvent(recordID: 1, deviceSerial: "x", channel: 0, startTime: .now, endTime: .now, triggerType: t,
                  storagePath: "/p", thumbnailPath: nil, frameCount: 0, byteSize: 0).kind
    }
    #expect(kind(4) == .person)
    #expect(kind(2) == .motion)
    #expect(kind(1) == .motion)
    #expect(kind(8) == .ring)
}

@Test func decodesBase64URLSnapshot() {
    // The HomeBase sends JPEGs base64url-encoded: "_9j_" is FF D8 FF.
    #expect(Data(base64URLEncoded: "_9j_4A") == Data([0xFF, 0xD8, 0xFF, 0xE0]))
}

@Test func readsFrameCaptureStamp() {
    // Video frame header: 48-bit LE milliseconds at 0x0e (here 0x01a15c02aa1b).
    var body = Data(count: 0x16)
    body.replaceSubrange(0x0e ..< 0x14, with: [0x1b, 0xaa, 0x02, 0x5c, 0xa1, 0x01])
    #expect(ClipCollector.stamp(body, at: 0x0e) == 0x01a1_5c02_aa1b)
}

@Test func parsesADTSFrame() throws {
    // AAC-LC, 16 kHz (index 8), mono, 7-byte header, 10-byte frame.
    let frame = Data([0xFF, 0xF1, 0x60, 0x40, 0x01, 0x5F, 0xFC, 0xAA, 0xBB, 0xCC])
    let adts = try #require(ADTSFrame(frame))
    #expect(adts.sampleRate == 16_000)
    #expect(adts.channels == 1)
    #expect(adts.raw == Data([0xAA, 0xBB, 0xCC]))
    #expect(adts.formatDescription() != nil)
}

@Test func opensLevel2StationFrame() throws {
    // Station → app level-2 frames (signCode 2) are tag(16) ‖ nonce(12) ‖ ciphertext.
    let key = Data(repeating: 7, count: 32)
    let nonce = try AES.GCM.Nonce(data: Data(repeating: 3, count: 12))
    let sealed = try AES.GCM.seal(Data("hello".utf8), using: SymmetricKey(data: key), nonce: nonce,
                                  authenticating: Data("eufy security".utf8))
    let frame = Data(sealed.tag) + Data(repeating: 3, count: 12) + sealed.ciphertext
    #expect(PPPPMessage.decryptLevel2(frame, key: key, signCode: 2) == Data("hello".utf8))
}
