// Apple platforms only (decoding / presentation). The Home Assistant add-on passes streams through instead.
#if canImport(CoreMedia)
import Foundation
import CoreMedia
import VideoToolbox
import CoreVideo

/// Decodes Eufy camera video (H.264 or H.265, Annex-B) into images using VideoToolbox. Eufy cameras mix
/// codecs — eufyCams use H.265, some indoor cams use H.264 — so this detects the codec from the stream.
public final class HEVCDecoder: @unchecked Sendable {
    public enum DecodeError: Error { case formatDescription(OSStatus), session(OSStatus) }

    enum Codec { case h264, h265 }

    private var formatDescription: CMVideoFormatDescription?
    private var session: VTDecompressionSession?
    private var codec: Codec?
    private var vps: Data?   // H.265 only
    private var sps: Data?
    private var pps: Data?

    public init() {}

    /// Decodes one Annex-B access unit to a CGImage, or nil when it produced no frame (parameter sets only).
    public func decode(annexB: Data) throws -> CGImage? {
        var vclNALs: [Data] = []
        for nal in Self.splitAnnexB(annexB) {
            guard let first = nal.first else { continue }
            let h264Type = first & 0x1F
            let h265Type = (first >> 1) & 0x3F
            if h265Type == 32 { codec = .h265; vps = nal; continue }       // H.265 VPS
            if codec == nil, h264Type == 7 { codec = .h264 }               // H.264 SPS → it's H.264

            switch codec {
            case .h265:
                switch h265Type {
                case 33: sps = nal
                case 34: pps = nal
                case 0...31: vclNALs.append(nal)
                default: break
                }
            case .h264, nil:
                switch h264Type {
                case 7: sps = nal
                case 8: pps = nal
                case 1, 5: vclNALs.append(nal)   // non-IDR / IDR slices
                default: break
                }
            }
        }
        try ensureFormatAndSession()
        guard let formatDescription, !vclNALs.isEmpty else { return nil }

        var avcc = Data()
        for nal in vclNALs {
            var len = UInt32(nal.count).bigEndian
            avcc.append(Data(bytes: &len, count: 4))
            avcc.append(nal)
        }
        return try decodeSample(makeSampleBuffer(avcc, formatDescription: formatDescription))
    }

    private func ensureFormatAndSession() throws {
        guard formatDescription == nil, let codec, let sps, let pps else { return }
        var desc: CMFormatDescription?
        let status: OSStatus
        switch codec {
        case .h265:
            guard let vps else { return }
            status = vps.withUnsafeBytes { v in sps.withUnsafeBytes { s in pps.withUnsafeBytes { p in
                let ptrs = [v.bindMemory(to: UInt8.self).baseAddress!, s.bindMemory(to: UInt8.self).baseAddress!,
                            p.bindMemory(to: UInt8.self).baseAddress!]
                let sizes = [vps.count, sps.count, pps.count]
                return CMVideoFormatDescriptionCreateFromHEVCParameterSets(
                    allocator: kCFAllocatorDefault, parameterSetCount: 3, parameterSetPointers: ptrs,
                    parameterSetSizes: sizes, nalUnitHeaderLength: 4, extensions: nil, formatDescriptionOut: &desc)
            }}}
        case .h264:
            status = sps.withUnsafeBytes { s in pps.withUnsafeBytes { p in
                let ptrs = [s.bindMemory(to: UInt8.self).baseAddress!, p.bindMemory(to: UInt8.self).baseAddress!]
                let sizes = [sps.count, pps.count]
                return CMVideoFormatDescriptionCreateFromH264ParameterSets(
                    allocator: kCFAllocatorDefault, parameterSetCount: 2, parameterSetPointers: ptrs,
                    parameterSetSizes: sizes, nalUnitHeaderLength: 4, formatDescriptionOut: &desc)
            }}
        }
        guard status == noErr, let desc else { throw DecodeError.formatDescription(status) }
        formatDescription = desc

        var sess: VTDecompressionSession?
        let attrs: [CFString: Any] = [kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA]
        let s = VTDecompressionSessionCreate(allocator: kCFAllocatorDefault, formatDescription: desc,
                                             decoderSpecification: nil, imageBufferAttributes: attrs as CFDictionary,
                                             outputCallback: nil, decompressionSessionOut: &sess)
        guard s == noErr, let sess else { throw DecodeError.session(s) }
        session = sess
    }

    private func makeSampleBuffer(_ data: Data, formatDescription: CMFormatDescription) throws -> CMSampleBuffer {
        var block: CMBlockBuffer?
        var bytes = data
        let created = bytes.withUnsafeMutableBytes { ptr -> OSStatus in
            CMBlockBufferCreateWithMemoryBlock(
                allocator: kCFAllocatorDefault, memoryBlock: ptr.baseAddress, blockLength: data.count,
                blockAllocator: kCFAllocatorNull, customBlockSource: nil, offsetToData: 0, dataLength: data.count,
                flags: 0, blockBufferOut: &block)
        }
        guard created == noErr, let block else { throw DecodeError.session(created) }
        var sample: CMSampleBuffer?
        var sizes = [data.count]
        let s = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: formatDescription,
            sampleCount: 1, sampleTimingEntryCount: 0, sampleTimingArray: nil,
            sampleSizeEntryCount: 1, sampleSizeArray: &sizes, sampleBufferOut: &sample)
        guard s == noErr, let sample else { throw DecodeError.session(s) }
        return sample
    }

    private func decodeSample(_ sample: CMSampleBuffer) throws -> CGImage? {
        guard let session else { throw DecodeError.session(-1) }
        let resultBox = ImageBox()
        var infoFlags = VTDecodeInfoFlags()
        let status = VTDecompressionSessionDecodeFrame(
            session, sampleBuffer: sample, flags: ._EnableTemporalProcessing, infoFlagsOut: &infoFlags
        ) { _, _, imageBuffer, _, _ in
            if let imageBuffer {
                var cg: CGImage?
                VTCreateCGImageFromCVPixelBuffer(imageBuffer, options: nil, imageOut: &cg)
                resultBox.set(cg)
            }
        }
        guard status == noErr else { throw DecodeError.session(status) }
        VTDecompressionSessionWaitForAsynchronousFrames(session)
        return resultBox.value
    }

    /// Splits Annex-B bytes into NAL units (without start codes).
    public static func splitAnnexB(_ data: Data) -> [Data] {
        let bytes = [UInt8](data)
        var starts: [Int] = []
        var i = 0
        while i + 3 <= bytes.count {
            if bytes[i] == 0, bytes[i + 1] == 0, bytes[i + 2] == 1 { starts.append(i + 3); i += 3 } else { i += 1 }
        }
        var nals: [Data] = []
        for (idx, start) in starts.enumerated() {
            var end = idx + 1 < starts.count ? starts[idx + 1] - 3 : bytes.count
            while end > start, bytes[end - 1] == 0 { end -= 1 }
            if end > start { nals.append(Data(bytes[start..<end])) }
        }
        return nals
    }

    final class ImageBox: @unchecked Sendable {
        private let lock = NSLock()
        private var image: CGImage?
        var value: CGImage? { lock.withLock { image } }
        func set(_ img: CGImage?) { lock.withLock { image = img } }
    }
}
#endif
