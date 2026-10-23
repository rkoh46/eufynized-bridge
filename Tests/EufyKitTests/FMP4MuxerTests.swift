import Testing
import Foundation
@testable import EufyKit

/// A tiny H.264 access unit: SPS (High, level 4.1), PPS, then one slice of the given NAL type.
private func h264Frame(slice: UInt8) -> Data {
    let start = Data([0, 0, 0, 1])
    return start + Data([0x67, 0x64, 0x00, 0x29, 0xAC]) + start + Data([0x68, 0xEE, 0x3C, 0x80])
        + start + Data([slice, 0x88, 0x84, 0x00])
}

private func kinds(_ out: [FMP4Muxer.Output]) -> [String] {
    out.map {
        switch $0 {
        case .mimeType: "mime"
        case .initSegment: "init"
        case .fragment: "frag"
        }
    }
}

@Test func firstKeyframeStartsTheStreamWithAnInitSegment() {
    let muxer = FMP4Muxer(audio: false)
    #expect(muxer.video(h264Frame(slice: 0x41), captureMs: 0, keyframe: false, size: "1280x720").isEmpty)
    let first = muxer.video(h264Frame(slice: 0x65), captureMs: 100, keyframe: true, size: "1280x720")
    #expect(kinds(first) == ["mime", "init"])
    #expect(first.first == .mimeType("video/mp4; codecs=\"avc1.640029\""))
    // Each frame is held until the next one, which gives its exact duration.
    #expect(kinds(muxer.video(h264Frame(slice: 0x41), captureMs: 266, keyframe: false, size: "1280x720")) == ["frag"])
}

@Test func aResolutionChangeGetsANewInitSegmentAfterTheLastOldFrame() {
    let muxer = FMP4Muxer(audio: false)
    _ = muxer.video(h264Frame(slice: 0x65), captureMs: 0, keyframe: true, size: "1280x720")
    _ = muxer.video(h264Frame(slice: 0x41), captureMs: 66, keyframe: false, size: "1280x720")
    let change = muxer.video(h264Frame(slice: 0x65), captureMs: 133, keyframe: true, size: "1920x1080")
    #expect(kinds(change) == ["frag", "mime", "init"])
    // Same size again: no new init.
    let same = muxer.video(h264Frame(slice: 0x65), captureMs: 200, keyframe: true, size: "1920x1080")
    #expect(kinds(same) == ["frag"])
}

@Test func heldFrameDurationMatchesTheGapToTheNextFrame() throws {
    let muxer = FMP4Muxer(audio: false)
    _ = muxer.video(h264Frame(slice: 0x65), captureMs: 1000, keyframe: true, size: "1280x720")
    // A camera that fell to ~6 fps: the next frame comes 166 ms later.
    let out = muxer.video(h264Frame(slice: 0x41), captureMs: 1166, keyframe: false, size: "1280x720")
    guard case .fragment(let fragment) = try #require(out.first) else { Issue.record("no fragment"); return }
    let bytes = [UInt8](fragment)
    let trun = try #require(bytes.indices.first { i in i + 4 <= bytes.count && bytes[i..<i + 4] == [0x74, 0x72, 0x75, 0x6E] })
    // trun: type(4) version+flags(4) count(4) dataOffset(4) duration(4)
    let d = trun + 16
    let duration = UInt32(bytes[d]) << 24 | UInt32(bytes[d + 1]) << 16 | UInt32(bytes[d + 2]) << 8 | UInt32(bytes[d + 3])
    #expect(duration == 166 * 90)
}
