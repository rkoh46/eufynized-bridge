// Apple platforms only (decoding / presentation). The Home Assistant add-on passes streams through instead.
#if canImport(CoreMedia)
import Foundation
import AVFoundation
import CoreMedia
import AudioToolbox

/// Plays a camera's audio: the stream sends AAC-LC (16 kHz mono) in ADTS frames. Each frame is decoded to PCM
/// here, scaled by `gain` (so quiet cameras can be turned up past what the system volume allows), and handed
/// to an AVSampleBufferAudioRenderer. Start muted; call `setMuted(false)` for sound.
public final class EufyAudioPlayer: @unchecked Sendable {
    private let renderer = AVSampleBufferAudioRenderer()
    private let synchronizer = AVSampleBufferRenderSynchronizer()
    private var decoder: Decoder?
    private var started = false
    private var nextPTS: Int64 = 0
    private let lock = NSLock()
    private var fed = 0, parsed = 0, enqueued = 0, reanchored = 0, firstBytes = ""

    /// Counters + renderer state, for diagnosing audio on real hardware.
    public var diagnostics: String {
        let err = renderer.error.map { "\($0)" } ?? "none"
        return "fed=\(fed) parsed=\(parsed) enqueued=\(enqueued) reanchored=\(reanchored) gain=\(gain) status=\(renderer.status.rawValue) error=\(err) first=\(firstBytes)"
    }

    public init() {
        synchronizer.addRenderer(renderer)
        renderer.volume = 0   // start muted
    }

    public func setMuted(_ muted: Bool) { renderer.volume = muted ? 0 : 1 }

    /// Playback gain, 1 = as recorded. Above 1 the samples are amplified (and clipped at full scale), which is
    /// what a camera in a quiet room needs; below 1 they're attenuated. Takes effect on the next frame.
    public var gain: Float {
        get { lock.withLock { _gain } }
        set { lock.withLock { _gain = max(0, min(8, newValue)) } }
    }
    private var _gain: Float = 1

    /// How far behind live audio plays — kept equal to the video's buffer so sound stays in sync with it.
    private var delay = 0.0
    public func setDelay(_ seconds: Double) {
        lock.withLock {
            let change = seconds - delay
            delay = seconds
            guard started, change != 0 else { return }
            let now = synchronizer.currentTime()
            synchronizer.setRate(1, time: CMTimeSubtract(now, CMTime(seconds: change, preferredTimescale: 1000)))
        }
    }

    /// Feeds one `CMD_AUDIO_FRAME` body (the 16-byte audio header is stripped here); decodes the ADTS AAC.
    public func feed(audioFrameBody body: Data) {
        fed += 1
        if firstBytes.isEmpty { firstBytes = body.prefix(24).map { String(format: "%02x", $0) }.joined() }
        guard body.count > 16 else { return }
        guard let (raw, info) = Self.parseADTS(Data(body.dropFirst(16))) else { return }
        parsed += 1
        if decoder == nil { decoder = Decoder(sampleRate: info.sampleRate, channels: info.channels) }
        guard let decoder, let pcm = decoder.decode(raw) else { return }
        let gain = self.gain
        if gain != 1, let ch = pcm.floatChannelData {
            for c in 0..<Int(pcm.format.channelCount) {
                let p = ch[c]
                for i in 0..<Int(pcm.frameLength) { p[i] = max(-1, min(1, p[i] * gain)) }
            }
        }
        let pts = CMTime(value: nextPTS, timescale: CMTimeScale(info.sampleRate))
        nextPTS += Int64(pcm.frameLength)
        guard let sample = Self.makeSample(pcm, pts: pts, format: decoder.pcmDescription) else { return }
        lock.withLock {
            if !started {
                started = true
                // The first frame (pts 0) plays once the clock reaches it, `delay` from now.
                synchronizer.setRate(1, time: CMTime(seconds: -delay, preferredTimescale: 1000))
            } else {
                // Frames that fall behind the clock (a stall, a buffer change) would be dropped one after another and
                // the sound would just stop: start the clock over from this frame instead, `delay` behind it.
                let late = synchronizer.currentTime().seconds - pts.seconds
                if late > 0.3 {
                    renderer.flush()
                    synchronizer.setRate(1, time: CMTimeSubtract(pts, CMTime(seconds: delay, preferredTimescale: 1000)))
                    reanchored += 1
                }
            }
        }
        // Always enqueue: the renderer queues what it's given (isReadyForMoreMediaData is a hint for pull-style
        // feeding). Skipping frames when it said "not ready" dropped two thirds of the audio and sounded choppy.
        renderer.enqueue(sample)
        enqueued += 1
    }

    public func stop() {
        synchronizer.setRate(0, time: .zero)
        renderer.flush()
    }

    // MARK: ADTS

    public struct FrameInfo { public let sampleRate: Double; public let channels: UInt32 }
    private static let rates: [Double] = [96000, 88200, 64000, 48000, 44100, 32000, 24000, 22050, 16000, 12000, 11025, 8000, 7350]

    /// Splits an ADTS frame into its raw AAC payload and what the header says about it.
    public static func parseADTS(_ input: Data) -> (raw: Data, info: FrameInfo)? {
        let data = input.startIndex == 0 ? input : Data(input)   // a slice keeps its parent's indices; work from 0
        let b = [UInt8](data.prefix(7))
        guard b.count >= 7, b[0] == 0xFF, (b[1] & 0xF0) == 0xF0 else { return nil }
        let headerLen = (b[1] & 0x01) != 0 ? 7 : 9
        let frameLen = (Int(b[3] & 0x03) << 11) | (Int(b[4]) << 3) | (Int(b[5] & 0xE0) >> 5)
        guard frameLen > headerLen, data.count >= frameLen else { return nil }
        let freqIndex = Int((b[2] & 0x3C) >> 2)
        let channels = UInt32(((b[2] & 0x01) << 2) | ((b[3] & 0xC0) >> 6))
        let rate = freqIndex < rates.count ? rates[freqIndex] : 16_000
        return (data.subdata(in: headerLen ..< frameLen), FrameInfo(sampleRate: rate, channels: max(1, channels)))
    }

    // MARK: AAC → PCM

    /// One AAC-LC packet in, one buffer of Float32 PCM out (AVAudioConverter around Apple's decoder).
    public final class Decoder {
        public let pcmFormat: AVAudioFormat
        let pcmDescription: CMAudioFormatDescription
        private let aacFormat: AVAudioFormat
        private let converter: AVAudioConverter

        public init?(sampleRate: Double, channels: UInt32) {
            var asbd = AudioStreamBasicDescription(
                mSampleRate: sampleRate, mFormatID: kAudioFormatMPEG4AAC, mFormatFlags: 0,
                mBytesPerPacket: 0, mFramesPerPacket: 1024, mBytesPerFrame: 0,
                mChannelsPerFrame: channels, mBitsPerChannel: 0, mReserved: 0)
            guard let aac = AVAudioFormat(streamDescription: &asbd),
                  let pcm = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: channels, interleaved: true),
                  let converter = AVAudioConverter(from: aac, to: pcm) else { return nil }
            var desc: CMAudioFormatDescription?
            var pcmASBD = pcm.streamDescription.pointee
            guard CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault, asbd: &pcmASBD, layoutSize: 0, layout: nil,
                                                 magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &desc) == noErr,
                  let desc else { return nil }
            aacFormat = aac; pcmFormat = pcm; self.converter = converter; pcmDescription = desc
        }

        public func decode(_ raw: Data) -> AVAudioPCMBuffer? {
            let packet = AVAudioCompressedBuffer(format: aacFormat, packetCapacity: 1, maximumPacketSize: raw.count)
            packet.packetCount = 1
            packet.byteLength = UInt32(raw.count)
            raw.withUnsafeBytes { src in packet.data.copyMemory(from: src.baseAddress!, byteCount: raw.count) }
            packet.packetDescriptions?.pointee = AudioStreamPacketDescription(mStartOffset: 0, mVariableFramesInPacket: 0, mDataByteSize: UInt32(raw.count))
            guard let out = AVAudioPCMBuffer(pcmFormat: pcmFormat, frameCapacity: 2048) else { return nil }
            var fed = false
            var error: NSError?
            let status = converter.convert(to: out, error: &error) { _, outStatus in
                if fed { outStatus.pointee = .noDataNow; return nil }
                fed = true
                outStatus.pointee = .haveData
                return packet
            }
            guard status != .error, out.frameLength > 0 else { return nil }
            return out
        }
    }

    /// Wraps decoded PCM as a sample buffer at `pts` (one timing entry covers every sample).
    private static func makeSample(_ pcm: AVAudioPCMBuffer, pts: CMTime, format: CMAudioFormatDescription) -> CMSampleBuffer? {
        let frames = Int(pcm.frameLength)
        let bytesPerFrame = Int(pcm.format.streamDescription.pointee.mBytesPerFrame)
        let byteCount = frames * bytesPerFrame
        guard frames > 0, let base = pcm.floatChannelData?[0] else { return nil }
        guard let block = CMBlockBuffer.copying(Data(bytes: UnsafeRawPointer(base), count: byteCount)) else { return nil }
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: pts.timescale), presentationTimeStamp: pts, decodeTimeStamp: .invalid)
        var size = bytesPerFrame
        var sample: CMSampleBuffer?
        let s = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: format,
            sampleCount: frames, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
            sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &sample)
        guard s == noErr else { return nil }
        return sample
    }
}
#endif
