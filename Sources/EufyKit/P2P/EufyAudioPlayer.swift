// Apple platforms only (decoding / presentation). The Home Assistant add-on passes streams through instead.
#if canImport(CoreMedia)
import Foundation
import AVFoundation
import CoreMedia
import AudioToolbox

/// Plays a camera's audio: the stream sends AAC-LC (16 kHz mono) in ADTS frames; this feeds them to an
/// AVSampleBufferAudioRenderer, which decodes and plays. Start muted; call `setMuted(false)` for sound.
public final class EufyAudioPlayer: @unchecked Sendable {
    private let renderer = AVSampleBufferAudioRenderer()
    private let synchronizer = AVSampleBufferRenderSynchronizer()
    private var formatDescription: CMAudioFormatDescription?
    private var started = false
    private var frameIndex: Int64 = 0
    private let sampleRate = 16_000.0
    private let samplesPerFrame: Int64 = 1024
    private let lock = NSLock()
    private var fed = 0, parsed = 0, enqueued = 0, firstBytes = ""

    /// Counters + renderer state, for diagnosing audio on real hardware.
    public var diagnostics: String {
        let err = renderer.error.map { "\($0)" } ?? "none"
        return "fed=\(fed) parsed=\(parsed) enqueued=\(enqueued) status=\(renderer.status.rawValue) error=\(err) first=\(firstBytes)"
    }

    public init() {
        synchronizer.addRenderer(renderer)
        renderer.volume = 0   // start muted
    }

    public func setMuted(_ muted: Bool) { renderer.volume = muted ? 0 : 1 }

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
        let adts = body.dropFirst(16)                 // strip the 16-byte audio frame header
        guard let (raw, format) = parseADTS(Data(adts)) else { return }
        parsed += 1
        guard let sample = makeSample(raw, format: format) else { return }
        if renderer.isReadyForMoreMediaData {
            renderer.enqueue(sample)
            enqueued += 1
        }
        lock.withLock {
            if !started {
                started = true
                // The first frame (pts 0) plays once the clock reaches it, `delay` from now.
                synchronizer.setRate(1, time: CMTime(seconds: -delay, preferredTimescale: 1000))
            }
        }
    }

    public func stop() {
        synchronizer.setRate(0, time: .zero)
        renderer.flush()
    }

    /// Parses an ADTS frame into its raw AAC payload and an AAC format description (built once).
    private func parseADTS(_ data: Data) -> (raw: Data, format: CMAudioFormatDescription)? {
        let b = [UInt8](data.prefix(7))
        guard b.count >= 7, b[0] == 0xFF, (b[1] & 0xF0) == 0xF0 else { return nil }
        let headerLen = (b[1] & 0x01) != 0 ? 7 : 9
        let frameLen = (Int(b[3] & 0x03) << 11) | (Int(b[4]) << 3) | (Int(b[5] & 0xE0) >> 5)
        guard frameLen > headerLen, data.count >= frameLen else { return nil }
        let raw = data.subdata(in: headerLen ..< frameLen)

        if let formatDescription { return (raw, formatDescription) }
        let profile = (b[2] & 0xC0) >> 6              // 1 = AAC-LC
        let freqIndex = (b[2] & 0x3C) >> 2
        let channels = ((b[2] & 0x01) << 2) | ((b[3] & 0xC0) >> 6)
        var asbd = AudioStreamBasicDescription(
            mSampleRate: sampleRate, mFormatID: kAudioFormatMPEG4AAC, mFormatFlags: 0,
            mBytesPerPacket: 0, mFramesPerPacket: UInt32(samplesPerFrame), mBytesPerFrame: 0,
            mChannelsPerFrame: UInt32(max(1, channels)), mBitsPerChannel: 0, mReserved: 0)
        // AudioSpecificConfig: audioObjectType(5) freqIndex(4) channelConfig(4) …
        let aot = UInt16(profile) + 1
        let asc = (aot << 11) | (UInt16(freqIndex) << 7) | (UInt16(channels) << 3)
        var cookie = [UInt8(asc >> 8), UInt8(truncatingIfNeeded: asc)]
        var desc: CMAudioFormatDescription?
        let status = CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault, asbd: &asbd, layoutSize: 0, layout: nil,
            magicCookieSize: cookie.count, magicCookie: &cookie, extensions: nil, formatDescriptionOut: &desc)
        guard status == noErr, let desc else { return nil }
        formatDescription = desc
        return (raw, desc)
    }

    private func makeSample(_ raw: Data, format: CMAudioFormatDescription) -> CMSampleBuffer? {
        guard !raw.isEmpty, let block = CMBlockBuffer.copying(raw) else { return nil }
        let pts = CMTime(value: frameIndex * samplesPerFrame, timescale: CMTimeScale(sampleRate))
        frameIndex += 1
        var timing = CMSampleTimingInfo(duration: CMTime(value: samplesPerFrame, timescale: CMTimeScale(sampleRate)),
                                        presentationTimeStamp: pts, decodeTimeStamp: .invalid)
        var size = raw.count
        var sample: CMSampleBuffer?
        let s = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: format,
            sampleCount: 1, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
            sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &sample)
        guard s == noErr else { return nil }
        return sample
    }
}
#endif
