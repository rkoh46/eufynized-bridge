import Foundation
#if canImport(Darwin)
import Darwin
private let datagram = SOCK_DGRAM
private func closeSocket(_ fd: Int32) { Darwin.close(fd) }
#else
import Glibc
private let datagram = Int32(SOCK_DGRAM.rawValue)
private func closeSocket(_ fd: Int32) { Glibc.close(fd) }
#endif

/// A small IPv4 UDP socket that supports broadcast, built on BSD sockets so it behaves the same on
/// macOS, iOS and Linux. Used to talk to a HomeBase on the local network.
final class UDPSocket: @unchecked Sendable {
    struct Endpoint: Hashable, Sendable, CustomStringConvertible {
        var host: String
        var port: UInt16
        var description: String { "\(host):\(port)" }
    }

    private let fd: Int32
    private let queue = DispatchQueue(label: "Eufynized.UDPSocket")
    private var source: DispatchSourceRead?

    init() throws {
        fd = socket(AF_INET, datagram, Int32(IPPROTO_UDP))
        guard fd >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_BROADCAST, &on, socklen_t(MemoryLayout<Int32>.size))
        // A full-resolution keyframe arrives as a burst of hundreds of datagrams; give it room (as eufy-sdk does).
        var receiveBuffer: Int32 = 4 * 1024 * 1024
        setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &receiveBuffer, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0            // let the OS pick a source port
        addr.sin_addr.s_addr = INADDR_ANY
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else {
            closeSocket(fd)
            throw POSIXError(.init(rawValue: errno) ?? .EADDRINUSE)
        }
    }

    /// The local port the OS bound us to.
    var localPort: UInt16 {
        var addr = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) }
        }
        return UInt16(bigEndian: addr.sin_port)
    }

    /// Delivers each received datagram on a private queue until `close()`.
    func startReceiving(_ handler: @escaping @Sendable (Data, Endpoint) -> Void) {
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        let fd = self.fd
        source.setEventHandler {
            var buffer = [UInt8](repeating: 0, count: 65_535)
            var from = sockaddr_in()
            var length = socklen_t(MemoryLayout<sockaddr_in>.size)
            let count = withUnsafeMutablePointer(to: &from) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    recvfrom(fd, &buffer, buffer.count, 0, $0, &length)
                }
            }
            guard count > 0 else { return }
            let host = String(cString: inet_ntoa(from.sin_addr))
            handler(Data(buffer[0..<count]), Endpoint(host: host, port: UInt16(bigEndian: from.sin_port)))
        }
        self.source = source
        source.resume()
    }

    func send(_ data: Data, to endpoint: Endpoint) {
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = endpoint.port.bigEndian
        guard inet_pton(AF_INET, endpoint.host, &addr.sin_addr) == 1 else { return }
        _ = data.withUnsafeBytes { bytes in
            withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    sendto(fd, bytes.baseAddress, data.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
    }

    func close() {
        source?.cancel()
        source = nil
        closeSocket(fd)
    }
}
