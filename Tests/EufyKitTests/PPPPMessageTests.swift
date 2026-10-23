import Testing
import Foundation
@testable import EufyKit

@Test func framesMessageWithBigEndianLength() {
    let framed = PPPPMessage.frame(PPPPMessage.Request.localLookup, payload: Data([0x00, 0x00]))
    #expect(Array(framed) == [0xF1, 0x30, 0x00, 0x02, 0x00, 0x00])
}

@Test func framesEmptyPayload() {
    let framed = PPPPMessage.frame(PPPPMessage.Request.ping)
    #expect(Array(framed) == [0xF1, 0xE0, 0x00, 0x00])
}

@Test func readsMessageType() {
    #expect(PPPPMessage.type(of: Data([0xF1, 0x42, 0x00, 0x00])) == 0x42)
    #expect(PPPPMessage.type(of: Data([0x00, 0x42])) == nil)   // wrong magic
    #expect(PPPPMessage.type(of: Data([0xF1])) == nil)          // too short
}

@Test func encodesP2PDIDTo20Bytes() throws {
    // "EUPRCAM-000001-ABCDE": 8-byte prefix, UInt32 BE number, 8-byte suffix.
    let encoded = try PPPPMessage.encode(p2pDID: "EUPRCAM-000001-ABCDE")
    #expect(encoded.count == 20)
    #expect(Array(encoded.prefix(8)) == Array("EUPRCAM".utf8) + [0x00])
    #expect(Array(encoded[8..<12]) == [0x00, 0x00, 0x00, 0x01])
    #expect(Array(encoded[12..<17]) == Array("ABCDE".utf8))
    #expect(Array(encoded[17..<20]) == [0x00, 0x00, 0x00])
}

@Test func rejectsMalformedP2PDID() {
    #expect(throws: PPPPMessage.EncodingError.invalidP2PDID) { try PPPPMessage.encode(p2pDID: "nope") }
    #expect(throws: PPPPMessage.EncodingError.invalidP2PDID) { try PPPPMessage.encode(p2pDID: "A-notanumber-B") }
}

@Test func buildsCheckCamPayload() throws {
    let message = try PPPPMessage.checkCam(p2pDID: "EUPRCAM-000001-ABCDE")
    #expect(Array(message.prefix(4)) == [0xF1, 0x41, 0x00, 0x17])  // 23-byte payload (20 + 3)
    #expect(message.count == 4 + 23)
}

@Test func parsesVideoFrameHeaderResolution() {
    // payloadLength=1000, flags=keyframe, seq=5, width=1920, height=1080, ts=0
    var data = Data([0xE8, 0x03, 0x00, 0x00, 0x01, 0x00, 0x05, 0x00, 0x00, 0x00,
                     0x80, 0x07, 0x38, 0x04, 0x00, 0x00, 0x00, 0x00])
    let header = VideoFrameHeader(data)
    #expect(header?.width == 1920)
    #expect(header?.height == 1080)
    #expect(header?.keyframe == true)
    #expect(header?.resolution == "1920x1080")
    data.removeLast(10)
    #expect(VideoFrameHeader(data) == nil)   // too short
}

@Test func buildsCommandFraming() {
    let header = PPPPMessage.commandHeader(seq: 0x0102, commandType: 1100)
    // d1 00 | seq BE 01 02 | XZYH | cmd LE (1100 = 0x044c → 4c 04)
    #expect(Array(header) == [0xD1, 0x00, 0x01, 0x02] + Array("XZYH".utf8) + [0x4C, 0x04])
    #expect(Array(PPPPMessage.ackPayload(kind: .video, seq: 7)) == [0xD1, 0x01, 0x00, 0x01, 0x00, 0x07])
}

@Test func derivesLevel1CommandKey() {
    // last 7 of serial + 9 chars of DID from its first dash
    let key = PPPPMessage.commandKey(stationSerial: "T8030TXAMPLE1234", p2pDID: "EUFYCAM-000001-ABCDE")
    #expect(key == Data("PLE1234-000001-A".utf8))  // suffix(7) + 9 DID chars from the first "-"
    #expect(key?.count == 16)
}

@Test func splitsAnnexBNALs() {
    // two NALs: start code 00 00 01, then bytes
    let data = Data([0,0,1, 0x40,0x01,0xAA, 0,0,1, 0x42,0x01,0xBB,0xCC])
    let nals = HEVCDecoder.splitAnnexB(data)
    #expect(nals.count == 2)
    #expect(Array(nals[0]) == [0x40,0x01,0xAA])
    #expect(Array(nals[1]) == [0x42,0x01,0xBB,0xCC])
    // NAL types from HEVC header: (byte0 >> 1) & 0x3f
    #expect((nals[0][0] >> 1) & 0x3F == 32)  // VPS
    #expect((nals[1][0] >> 1) & 0x3F == 33)  // SPS
}

@Test func eufyKDFIsDeterministicAndRightLength() {
    let shared = Data(repeating: 0xAB, count: 32)
    let a = EufyMediaDecryptor.eufyKDF(shared: shared, length: 48)
    let b = EufyMediaDecryptor.eufyKDF(shared: shared, length: 48)
    #expect(a.count == 48)
    #expect(a == b)
    // different input → different output
    #expect(EufyMediaDecryptor.eufyKDF(shared: Data(repeating: 0x01, count: 32), length: 48) != a)
}
