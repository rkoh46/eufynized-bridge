// Apple platforms only (decoding / presentation). The Home Assistant add-on passes streams through instead.
#if canImport(CoreMedia)
import Foundation
import CoreGraphics

/// One-shot: connect to the HomeBase, request a camera channel, decode the first keyframe to an image,
/// then close. Used for grid thumbnails. Cloud-free. With a `Level2Context` it selects the specific
/// camera on `channel`; without one it plays the HomeBase's active camera.
public enum EufySnapshot {
    public static func capture(homeBaseIP: String?, p2pDID: String? = nil, channel: UInt8,
                               level2: EufyLiveStream.Level2Context? = nil,
                               timeout: TimeInterval = 12) async -> CGImage? {
        guard let connection = try? HomeBaseConnection(config: .init(
            stationSerial: level2?.stationSerial ?? "snap", p2pDID: p2pDID, knownAddress: homeBaseIP)) else { return nil }
        let decoder = HEVCDecoder()
        let rsa = EufyRSA()
        let l2decoder = rsa.map { Level2VideoDecoder(rsa: $0) }
        let box = ImageContinuationBox()
        let gw = GatewayBox()

        connection.onFrame { _, cmd, signCode, body in
            if cmd == 1100 { gw.set(body); return }
            guard cmd == 1300 else { return }
            let annexB: Data?
            if let l2decoder, level2 != nil { annexB = l2decoder.decode(body, signCode: signCode) }
            else if VideoFrameHeader(body) != nil { annexB = Data(body.dropFirst(0x16)) }
            else { annexB = nil }
            if let annexB, let image = (try? decoder.decode(annexB: annexB)) ?? nil {
                box.resume(with: image, connection: connection)
            }
        }

        return await withTaskGroup(of: CGImage?.self) { group in
            group.addTask {
                await withCheckedContinuation { (cont: CheckedContinuation<CGImage?, Never>) in
                    box.install(cont)
                    Task {
                        do {
                            _ = try await connection.connect()
                            try await requestVideo(connection, channel: channel, level2: level2, rsa: rsa, gw: gw)
                        } catch {
                            box.resume(with: nil, connection: connection)
                        }
                    }
                }
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(timeout))
                box.resume(with: nil, connection: connection)
                return nil
            }
            let result = await group.next() ?? nil
            group.cancelAll()
            return result
        }
    }

    private static func requestVideo(_ connection: HomeBaseConnection, channel: UInt8,
                                     level2: EufyLiveStream.Level2Context?, rsa: EufyRSA?, gw: GatewayBox) async throws {
        guard let ctx = level2, let rsa, let did = connection.connectedDID,
              let level1Key = PPPPMessage.commandKey(stationSerial: ctx.stationSerial, p2pDID: did) else {
            connection.sendCommand(1003, channel: channel)
            return
        }
        connection.sendCommand(1100)
        for _ in 0..<12 where gw.value == nil { try await Task.sleep(for: .milliseconds(300)) }
        guard let raw = gw.value else { connection.sendCommand(1003, channel: channel); return }
        let decrypted = PPPPMessage.decryptGatewayInfo(raw, level1Key: level1Key)
        guard let envelope = PPPPMessage.gatewayInfoEnvelope(decrypted: decrypted),
              let level2Key = EufyMediaDecryptor.deriveLevel2Key(gatewayEnvelope: envelope, eccPrivateKeyHex: ctx.eccPrivateKeyHex) else {
            connection.sendCommand(1003, channel: channel); return
        }
        connection.startLiveLevel2(channel: channel, level2Key: level2Key, rsaModulusHex: rsa.modulusHex, accountID: ctx.accountID)
    }

    final class GatewayBox: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: Data?
        var value: Data? { lock.withLock { stored } }
        func set(_ data: Data) { lock.withLock { if stored == nil { stored = data } } }
    }

    final class ImageContinuationBox: @unchecked Sendable {
        private let lock = NSLock()
        private var cont: CheckedContinuation<CGImage?, Never>?
        private var done = false

        func install(_ c: CheckedContinuation<CGImage?, Never>) {
            lock.withLock { if done { c.resume(returning: nil) } else { cont = c } }
        }
        func resume(with image: CGImage?, connection: HomeBaseConnection) {
            let c: CheckedContinuation<CGImage?, Never>? = lock.withLock {
                if done { return nil }
                done = true
                defer { cont = nil }
                return cont
            }
            connection.close()
            c?.resume(returning: image)
        }
    }
}
#endif
