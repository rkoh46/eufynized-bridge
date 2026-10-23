import Testing
import Foundation
@testable import EufyKit

/// A minimal stand-in for a HomeBase on loopback: answers LOCAL_LOOKUP with a lookup response, CHECK_CAM
/// with CAM_ID, and PING with PONG — enough to drive the real connect handshake end to end.
private final class FakeHomeBase: @unchecked Sendable {
    let socket: UDPSocket
    var port: UInt16 { socket.localPort }

    init() throws {
        socket = try UDPSocket()
        socket.startReceiving { [socket] datagram, from in
            switch PPPPMessage.type(of: datagram) {
            case PPPPMessage.Request.localLookup:
                socket.send(PPPPMessage.frame(PPPPMessage.Response.localLookupResponse), to: from)
            case PPPPMessage.Request.checkCam:
                socket.send(PPPPMessage.frame(PPPPMessage.Response.camID), to: from)
            case PPPPMessage.Request.ping:
                socket.send(PPPPMessage.frame(PPPPMessage.Response.pong), to: from)
            default:
                break
            }
        }
    }

    func close() { socket.close() }
}

@Test func completesHandshakeAgainstAFakeHomeBase() async throws {
    let fake = try FakeHomeBase()
    defer { fake.close() }

    let connection = try HomeBaseConnection(config: .init(
        stationSerial: "test", p2pDID: "EUPRCAM-000001-ABCDE",
        knownAddress: "127.0.0.1", connectTimeout: 5, lookupPort: fake.port))
    defer { connection.close() }

    let peer = try await connection.connect()
    #expect(peer.host == "127.0.0.1")
    #expect(peer.port == fake.port)
    #expect(connection.isConnected)
}

@Test func timesOutWhenNoHomeBaseAnswers() async throws {
    // Point at a loopback port with nothing listening; no broadcast reply either.
    let connection = try HomeBaseConnection(config: .init(
        stationSerial: "test", p2pDID: "EUPRCAM-000001-ABCDE",
        knownAddress: "127.0.0.1", connectTimeout: 1, lookupPort: 1))
    defer { connection.close() }

    await #expect(throws: HomeBaseConnection.ConnectionError.self) {
        _ = try await connection.connect()
    }
}

@Test func rejectsInvalidP2PDIDAtConstruction() {
    #expect(throws: PPPPMessage.EncodingError.self) {
        _ = try HomeBaseConnection(config: .init(
            stationSerial: "test", p2pDID: "not-a-did", knownAddress: nil))
    }
}
