import Foundation

/// A downloaded HomeBase clip: decrypted video access units (Annex-B H.264/H.265) and ADTS AAC audio,
/// each with the camera's capture time. `writeMP4` remuxes it (no re-encoding) for AVPlayer.
public struct EufyClip: Sendable {
    public struct Frame: Sendable {
        public var timestampMs: Int64
        public var data: Data
        public var keyframe: Bool
    }

    public var video: [Frame]
    public var audio: [Frame]

    public var videoFrames: Int { video.count }
    public var keyframes: Int { video.filter(\.keyframe).count }
    public var duration: TimeInterval {
        guard let first = video.first?.timestampMs, let last = video.last?.timestampMs else { return 0 }
        return Double(last - first) / 1000
    }

    public enum WriteError: LocalizedError {
        case noVideoFormat, writer(String)
        public var errorDescription: String? {
            switch self {
            case .noVideoFormat: "The clip's video format wasn't recognised."
            case .writer(let m): "Couldn't save the clip: \(m)"
            }
        }
    }
}

// Apple platforms only (remuxing for AVPlayer). The Home Assistant add-on serves the raw frames instead.
#if canImport(CoreMedia)
import AVFoundation
import CoreMedia

extension EufyClip {
    /// Builds timed video samples: PTS from the capture clock relative to the first frame, kept increasing.
    func videoSamples() -> (format: CMFormatDescription, samples: [CMSampleBuffer])? {
        let builder = HEVCSampleBuilder()
        guard let origin = video.first?.timestampMs else { return nil }
        var out: [CMSampleBuffer] = []
        var lastMs: Int64 = -1
        var format: CMFormatDescription?
        for frame in video {
            let keyframesBefore = builder.keyframes
            guard let sample = builder.sampleBuffer(fromAnnexB: frame.data) else { continue }
            var ms = frame.timestampMs - origin
            if ms <= lastMs { ms = lastMs + 1 }
            lastMs = ms
            var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: CMTime(value: ms, timescale: 1000),
                                            decodeTimeStamp: .invalid)
            var retimed: CMSampleBuffer?
            CMSampleBufferCreateCopyWithNewTiming(allocator: nil, sampleBuffer: sample, sampleTimingEntryCount: 1,
                                                  sampleTimingArray: &timing, sampleBufferOut: &retimed)
            guard let retimed else { continue }
            if builder.keyframes == keyframesBefore, let attachments = CMSampleBufferGetSampleAttachmentsArray(retimed, createIfNecessary: true),
               CFArrayGetCount(attachments) > 0 {
                let dict = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
                CFDictionarySetValue(dict, Unmanaged.passUnretained(kCMSampleAttachmentKey_NotSync).toOpaque(),
                                     Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
            }
            format = CMSampleBufferGetFormatDescription(retimed)
            out.append(retimed)
        }
        guard let format, !out.isEmpty else { return nil }
        return (format, out)
    }

    /// Builds timed AAC samples from the ADTS frames, on the same clock as the video.
    func audioSamples() -> (format: CMAudioFormatDescription, samples: [CMSampleBuffer])? {
        guard let origin = video.first?.timestampMs else { return nil }
        var format: CMAudioFormatDescription?
        var sampleRate = 16_000
        var out: [CMSampleBuffer] = []
        var nextPTS: Int64 = -1   // in sample-rate units
        for frame in audio {
            guard let adts = ADTSFrame(frame.data) else { continue }
            if format == nil { format = adts.formatDescription(); sampleRate = adts.sampleRate }
            guard let format, let block = CMBlockBuffer.copying(adts.raw) else { continue }
            // Audio from before the first video frame is dropped; afterwards, frames sit back to back unless
            // the capture clock shows a real gap.
            let ms = frame.timestampMs - origin
            guard ms >= 0 else { continue }
            let byClock = ms * Int64(sampleRate) / 1000
            let pts = nextPTS < 0 || byClock > nextPTS + 1024 * 4 ? byClock : nextPTS
            nextPTS = pts + 1024
            var timing = CMSampleTimingInfo(duration: CMTime(value: 1024, timescale: CMTimeScale(sampleRate)),
                                            presentationTimeStamp: CMTime(value: pts, timescale: CMTimeScale(sampleRate)),
                                            decodeTimeStamp: .invalid)
            var size = adts.raw.count
            var sample: CMSampleBuffer?
            CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: format,
                                      sampleCount: 1, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
                                      sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &sample)
            if let sample { out.append(sample) }
        }
        guard let format, !out.isEmpty else { return nil }
        return (format, out)
    }

    /// Writes the clip as an MP4 (H.264/H.265 + AAC, passed through untouched).
    public func writeMP4(to url: URL) async throws {
        guard let (videoFormat, videoSamples) = videoSamples() else { throw WriteError.noVideoFormat }
        try? FileManager.default.removeItem(at: url)
        let writer: AVAssetWriter
        do { writer = try AVAssetWriter(outputURL: url, fileType: .mp4) } catch { throw WriteError.writer(error.localizedDescription) }
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: nil, sourceFormatHint: videoFormat)
        videoInput.expectsMediaDataInRealTime = false
        writer.add(videoInput)
        var tracks: [(AVAssetWriterInput, [CMSampleBuffer])] = [(videoInput, videoSamples)]
        if let (audioFormat, audioSamples) = audioSamples() {
            let audioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: nil, sourceFormatHint: audioFormat)
            audioInput.expectsMediaDataInRealTime = false
            if writer.canAdd(audioInput) { writer.add(audioInput); tracks.append((audioInput, audioSamples)) }
        }
        guard writer.startWriting() else { throw WriteError.writer(writer.error?.localizedDescription ?? "start failed") }
        writer.startSession(atSourceTime: .zero)

        // Interleave by time, waiting whenever the writer wants the other track first.
        var indices = Array(repeating: 0, count: tracks.count)
        while true {
            var progressed = false
            var remaining = false
            for t in tracks.indices where indices[t] < tracks[t].1.count {
                remaining = true
                let (input, samples) = tracks[t]
                while indices[t] < samples.count, input.isReadyForMoreMediaData {
                    guard input.append(samples[indices[t]]) else {
                        throw WriteError.writer(writer.error?.localizedDescription ?? "append failed")
                    }
                    indices[t] += 1
                    progressed = true
                }
                if indices[t] == samples.count { input.markAsFinished() }
            }
            if !remaining { break }
            if !progressed { try await Task.sleep(for: .milliseconds(5)) }
        }
        for (t, (input, samples)) in tracks.enumerated() where samples.isEmpty || indices[t] < samples.count { input.markAsFinished() }
        await writer.finishWriting()
        if writer.status != .completed { throw WriteError.writer(writer.error?.localizedDescription ?? "status \(writer.status.rawValue)") }
    }
}

/// One ADTS AAC frame: the raw AAC payload plus what's needed to describe its format.
struct ADTSFrame {
    var raw: Data
    var profile: UInt8, freqIndex: UInt8, channels: UInt8

    static let rates = [96000, 88200, 64000, 48000, 44100, 32000, 24000, 22050, 16000, 12000, 11025, 8000, 7350]
    var sampleRate: Int { Int(freqIndex) < Self.rates.count ? Self.rates[Int(freqIndex)] : 16_000 }

    init?(_ data: Data) {
        let b = [UInt8](data.prefix(7))
        guard b.count >= 7, b[0] == 0xFF, (b[1] & 0xF0) == 0xF0 else { return nil }
        let headerLen = (b[1] & 0x01) != 0 ? 7 : 9
        let frameLen = (Int(b[3] & 0x03) << 11) | (Int(b[4]) << 3) | (Int(b[5] & 0xE0) >> 5)
        guard frameLen > headerLen, data.count >= frameLen else { return nil }
        raw = data.subdata(in: data.startIndex + headerLen ..< data.startIndex + frameLen)
        profile = (b[2] & 0xC0) >> 6
        freqIndex = (b[2] & 0x3C) >> 2
        channels = ((b[2] & 0x01) << 2) | ((b[3] & 0xC0) >> 6)
    }

    func formatDescription() -> CMAudioFormatDescription? {
        var asbd = AudioStreamBasicDescription(
            mSampleRate: Double(sampleRate), mFormatID: kAudioFormatMPEG4AAC, mFormatFlags: 0, mBytesPerPacket: 0,
            mFramesPerPacket: 1024, mBytesPerFrame: 0, mChannelsPerFrame: UInt32(max(1, channels)),
            mBitsPerChannel: 0, mReserved: 0)
        let asc = (UInt16(profile + 1) << 11) | (UInt16(freqIndex) << 7) | (UInt16(channels) << 3)
        var cookie = [UInt8(asc >> 8), UInt8(truncatingIfNeeded: asc)]
        var desc: CMAudioFormatDescription?
        CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault, asbd: &asbd, layoutSize: 0, layout: nil,
                                       magicCookieSize: cookie.count, magicCookie: &cookie, extensions: nil,
                                       formatDescriptionOut: &desc)
        return desc
    }
}
#endif
