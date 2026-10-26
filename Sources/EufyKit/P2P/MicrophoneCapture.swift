// Apple platforms only (decoding / presentation). The Home Assistant add-on passes streams through instead.
#if canImport(CoreMedia)
import Foundation
import AVFoundation
import AudioToolbox

/// Captures the microphone and encodes it to AAC-LC (16 kHz mono) ADTS frames — the format Eufy cameras
/// accept for talkback. Each encoded frame is handed to the callback to send to the camera.
public final class MicrophoneCapture: @unchecked Sendable {
    private let engine = AVAudioEngine()
    private var converter: AVAudioConverter?
    private var handler: (@Sendable (Data) -> Void)?
    private let aacFormat: AVAudioFormat?
    /// Microphone gain, 1 = as captured: the Mac's mic comes through loud at the camera's speaker, so this
    /// is usually set below 1. Samples are scaled before encoding; above 1 they're clipped at full scale.
    public var gain: Float {
        get { lock.withLock { _gain } }
        set { lock.withLock { _gain = max(0, min(4, newValue)) } }
    }
    private var _gain: Float = 1
    private let lock = NSLock()

    public init() {
        var asbd = AudioStreamBasicDescription(
            mSampleRate: 16_000, mFormatID: kAudioFormatMPEG4AAC, mFormatFlags: 0,
            mBytesPerPacket: 0, mFramesPerPacket: 1024, mBytesPerFrame: 0,
            mChannelsPerFrame: 1, mBitsPerChannel: 0, mReserved: 0)
        aacFormat = AVAudioFormat(streamDescription: &asbd)
    }

    public func start(_ handler: @escaping @Sendable (Data) -> Void) {
        guard let aacFormat else { return }
        self.handler = handler
        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        converter = AVAudioConverter(from: inputFormat, to: aacFormat)

        input.installTap(onBus: 0, bufferSize: 2048, format: inputFormat) { [weak self] buffer, _ in
            self?.encode(buffer)
        }
        engine.prepare()
        try? engine.start()
    }

    public func stop() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        handler = nil
    }

    private func encode(_ pcm: AVAudioPCMBuffer) {
        guard let converter, let aacFormat else { return }
        let gain = self.gain
        if gain != 1, let ch = pcm.floatChannelData {
            for c in 0..<Int(pcm.format.channelCount) {
                let p = ch[c]
                for i in 0..<Int(pcm.frameLength) { p[i] = max(-1, min(1, p[i] * gain)) }
            }
        }
        let out = AVAudioCompressedBuffer(format: aacFormat, packetCapacity: 8, maximumPacketSize: converter.maximumOutputPacketSize)
        var fed = false
        var error: NSError?
        let status = converter.convert(to: out, error: &error) { _, outStatus in
            if fed { outStatus.pointee = .noDataNow; return nil }
            fed = true
            outStatus.pointee = .haveData
            return pcm
        }
        guard status != .error, out.packetCount > 0,
              let pd = out.packetDescriptions else { return }
        let base = out.data.assumingMemoryBound(to: UInt8.self)
        for i in 0..<Int(out.packetCount) {
            let desc = pd[i]
            let length = Int(desc.mDataByteSize)
            let raw = Data(bytes: base + Int(desc.mStartOffset), count: length)
            handler?(Self.adts(wrapping: raw))
        }
    }

    /// Prepends a 7-byte ADTS header (AAC-LC, 16 kHz, mono) to a raw AAC frame.
    static func adts(wrapping raw: Data) -> Data {
        let frameLen = raw.count + 7
        let freqIndex = 8   // 16 kHz
        let channels = 1
        var header = [UInt8](repeating: 0, count: 7)
        header[0] = 0xFF
        header[1] = 0xF1                                     // MPEG-4, no CRC
        header[2] = UInt8((1 << 6) | (freqIndex << 2) | (channels >> 2))   // profile AAC-LC (01)
        header[3] = UInt8(((channels & 3) << 6) | (frameLen >> 11))
        header[4] = UInt8((frameLen >> 3) & 0xFF)
        header[5] = UInt8(((frameLen & 7) << 5) | 0x1F)
        header[6] = 0xFC
        return Data(header) + raw
    }
}
#endif
