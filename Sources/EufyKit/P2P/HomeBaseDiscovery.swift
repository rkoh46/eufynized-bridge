import Foundation

/// Finds a HomeBase on the local network and confirms which address it answers from.
///
/// The app sends a LOCAL_LOOKUP datagram — broadcast, and directly to the station's known LAN address
/// when the device list gave us one — to UDP 32108. A HomeBase on the same network answers, which both
/// proves it's reachable and tells us the address and port to use for the rest of the connection.
///
/// Ported from eufy-sdk (Apache-2.0, github.com/mega-yfue/eufy-sdk).
public enum HomeBaseDiscovery {
    public struct Result: Sendable, Equatable {
        /// Address the HomeBase answered from.
        public var host: String
        public var port: UInt16
        /// How long the reply took.
        public var elapsed: TimeInterval
        /// The P2P id the HomeBase announced in its reply, when present — lets us connect without the cloud.
        public var announcedDID: String?
    }

    public enum DiscoveryError: LocalizedError, Equatable {
        case notFound(sentBroadcast: Bool, knownAddress: String?)

        public var errorDescription: String? {
            switch self {
            case let .notFound(_, address):
                let where_ = address.map { " at \($0) or via broadcast" } ?? " via broadcast"
                return "No HomeBase answered\(where_). Check it's on the same network as this device."
            }
        }
    }

    /// Looks for the HomeBase and returns the first address it answers from.
    /// - Parameters:
    ///   - knownAddress: the station's LAN address from the device list, if any.
    ///   - timeout: how long to wait for a reply.
    public static func find(knownAddress: String?, timeout: TimeInterval = 3) async throws -> Result {
        let socket = try UDPSocket()
        defer { socket.close() }

        let start = Date()
        let box = ResultBox()
        socket.startReceiving { datagram, from in
            // A pre-connect reply on the lookup port means "HomeBase is here".
            guard let type = PPPPMessage.type(of: datagram),
                  type == PPPPMessage.Response.localLookupResponse
                    || type == PPPPMessage.Response.camID
                    || type == PPPPMessage.Response.camAddress else { return }
            box.set(Result(host: from.host, port: from.port, elapsed: Date().timeIntervalSince(start),
                           announcedDID: PPPPMessage.announcedDID(in: datagram)))
        }

        let lookup = PPPPMessage.localLookup()
        let sentBroadcast = true
        // Re-send a few times; UDP can drop the first datagram, and the HomeBase may be mid-wake.
        for _ in 0..<Int(max(1, timeout * 2)) {
            if let result = box.value { return result }
            socket.send(lookup, to: .init(host: "255.255.255.255", port: PPPPMessage.lookupPort))
            if let knownAddress {
                socket.send(lookup, to: .init(host: knownAddress, port: PPPPMessage.lookupPort))
            }
            try? await Task.sleep(for: .milliseconds(500))
        }
        if let result = box.value { return result }
        throw DiscoveryError.notFound(sentBroadcast: sentBroadcast, knownAddress: knownAddress)
    }

    /// Thread-safe holder for the first reply seen on the socket's receive queue.
    private final class ResultBox: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: Result?
        var value: Result? { lock.withLock { stored } }
        func set(_ result: Result) { lock.withLock { if stored == nil { stored = result } } }
    }
}
