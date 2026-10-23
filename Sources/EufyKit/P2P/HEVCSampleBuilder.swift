// Apple platforms only (decoding / presentation). The Home Assistant add-on passes streams through instead.
#if canImport(CoreMedia)
import Foundation
import CoreMedia

/// Turns H.265 Annex-B access units into `CMSampleBuffer`s ready for an `AVSampleBufferDisplayLayer`.
/// Parameter sets (VPS/SPS/PPS) are captured from the stream; VCL slices become timed samples.
public final class HEVCSampleBuilder: @unchecked Sendable {
    enum Codec { case h264, h265 }
    private var codec: Codec?
    private var vps: Data?
    private var sps: Data?
    private var pps: Data?
    private var formatDescription: CMVideoFormatDescription?
    private let frameRate: Int32
    /// Set after lost data: frames that predict from the damaged one would smear, so wait for a keyframe.
    private var waitingForKeyframe = false
    public private(set) var droppedWaitingForKeyframe = 0
    public private(set) var keyframes = 0
    /// How many times the stream switched parameter sets (e.g. a resolution/quality change mid-stream).
    public private(set) var formatChanges = 0
    /// Current picture size, from the latest format.
    public private(set) var dimensions: CMVideoDimensions?

    /// Call after a transport gap; output resumes at the next keyframe.
    public func resyncOnNextKeyframe() { waitingForKeyframe = true }

    public init(frameRate: Int32 = 15) { self.frameRate = frameRate }

    /// Presentation time of the previous frame and the camera timestamp it came from.
    private var lastPTS: CMTime?
    private var lastCameraTimestamp: UInt32?

    /// Feeds one Annex-B access unit (H.264 or H.265); returns a sample buffer for a displayable frame.
    /// `cameraTimestampMs` is the capture time from the frame header: pacing playback by it (rather than
    /// an assumed frame rate) keeps the player in step with the camera, including frames it skipped.
    public func sampleBuffer(fromAnnexB annexB: Data, cameraTimestampMs: UInt32? = nil) -> CMSampleBuffer? {
        var vcl: [Data] = []
        var isKeyframe = false
        for nal in HEVCDecoder.splitAnnexB(annexB) {
            guard let first = nal.first else { continue }
            let h264Type = first & 0x1F
            let h265Type = (first >> 1) & 0x3F
            if h265Type == 32 { codec = .h265; update(&vps, nal); continue }
            if codec == nil, h264Type == 7 { codec = .h264 }
            switch codec {
            case .h265:
                switch h265Type {
                case 33: update(&sps, nal)
                case 34: update(&pps, nal)
                case 16...21: vcl.append(nal); isKeyframe = true   // IRAP (IDR/CRA/BLA)
                case 0...31: vcl.append(nal)
                default: break
                }
            case .h264, nil:
                switch h264Type { case 7: update(&sps, nal); case 8: update(&pps, nal); case 5: vcl.append(nal); isKeyframe = true; case 1: vcl.append(nal); default: break }
            }
        }
        ensureFormat()
        guard let formatDescription, !vcl.isEmpty else { return nil }
        if isKeyframe { keyframes += 1; waitingForKeyframe = false }
        if waitingForKeyframe { droppedWaitingForKeyframe += 1; return nil }

        var avcc = Data()
        for nal in vcl {
            var len = UInt32(nal.count).bigEndian
            avcc.append(Data(bytes: &len, count: 4))
            avcc.append(nal)
        }
        return makeSample(avcc, formatDescription: formatDescription, pts: nextPTS(cameraTimestampMs))
    }

    /// Advances by the camera's timestamp delta when it's plausible (one frame up to a second), else by one
    /// frame interval — so a garbled or restarted timestamp can never throw playback off.
    private func nextPTS(_ timestamp: UInt32?) -> CMTime {
        let oneFrame = CMTime(value: 1, timescale: frameRate)
        defer { lastCameraTimestamp = timestamp }
        guard let last = lastPTS else { lastPTS = .zero; return .zero }
        var step = oneFrame
        if let timestamp, let previous = lastCameraTimestamp {
            let delta = timestamp &- previous
            if delta >= 20 && delta <= 1000 { step = CMTime(value: CMTimeValue(delta), timescale: 1000) }
        }
        let pts = CMTimeAdd(last, step)
        lastPTS = pts
        return pts
    }

    /// Stores a parameter set; a different one means the camera changed format, so the format description
    /// is rebuilt. Frames must carry the format they were encoded with or nothing after the change decodes.
    private func update(_ slot: inout Data?, _ nal: Data) {
        guard slot != nal else { return }
        if slot != nil, formatDescription != nil { formatChanges += 1 }
        slot = nal
        formatDescription = nil
    }

    /// Resets parameter sets — call when switching streams so a new SPS/PPS is picked up.
    public func reset() {
        vps = nil; sps = nil; pps = nil; formatDescription = nil
        lastPTS = nil; lastCameraTimestamp = nil
    }

    private func ensureFormat() {
        guard formatDescription == nil, let codec, let sps, let pps else { return }
        var desc: CMFormatDescription?
        switch codec {
        case .h265:
            guard let vps else { return }
            _ = vps.withUnsafeBytes { v in sps.withUnsafeBytes { s in pps.withUnsafeBytes { p in
                let ptrs = [v.bindMemory(to: UInt8.self).baseAddress!, s.bindMemory(to: UInt8.self).baseAddress!,
                            p.bindMemory(to: UInt8.self).baseAddress!]
                let sizes = [vps.count, sps.count, pps.count]
                return CMVideoFormatDescriptionCreateFromHEVCParameterSets(
                    allocator: kCFAllocatorDefault, parameterSetCount: 3, parameterSetPointers: ptrs,
                    parameterSetSizes: sizes, nalUnitHeaderLength: 4, extensions: nil, formatDescriptionOut: &desc)
            }}}
        case .h264:
            _ = sps.withUnsafeBytes { s in pps.withUnsafeBytes { p in
                let ptrs = [s.bindMemory(to: UInt8.self).baseAddress!, p.bindMemory(to: UInt8.self).baseAddress!]
                let sizes = [sps.count, pps.count]
                return CMVideoFormatDescriptionCreateFromH264ParameterSets(
                    allocator: kCFAllocatorDefault, parameterSetCount: 2, parameterSetPointers: ptrs,
                    parameterSetSizes: sizes, nalUnitHeaderLength: 4, formatDescriptionOut: &desc)
            }}
        }
        formatDescription = desc
        if let desc { dimensions = CMVideoFormatDescriptionGetDimensions(desc) }
    }

    private func makeSample(_ data: Data, formatDescription: CMFormatDescription, pts: CMTime) -> CMSampleBuffer? {
        guard let block = CMBlockBuffer.copying(data) else { return nil }

        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: frameRate),
            presentationTimeStamp: pts,
            decodeTimeStamp: .invalid)

        var sizes = [data.count]
        var sample: CMSampleBuffer?
        let s = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: formatDescription,
            sampleCount: 1, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
            sampleSizeEntryCount: 1, sampleSizeArray: &sizes, sampleBufferOut: &sample)
        guard s == noErr, let sample else { return nil }
        // No DisplayImmediately: the frames carry presentation timestamps, and the display layer's
        // timebase paces them evenly at the camera's rate, smoothing bursty network delivery.
        return sample
    }
}

extension CMBlockBuffer {
    /// A block buffer that owns a copy of `data`. Samples outlive the call that builds them (the display
    /// layer queues them for paced playback), so they must never point at a temporary Swift buffer.
    static func copying(_ data: Data) -> CMBlockBuffer? {
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: data.count,
            blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0, dataLength: data.count,
            flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &block) == noErr, let block else { return nil }
        let copied = data.withUnsafeBytes { ptr in
            CMBlockBufferReplaceDataBytes(with: ptr.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: data.count)
        }
        return copied == noErr ? block : nil
    }
}
#endif
