import Foundation
#if canImport(Darwin)
import Darwin
private let streamSocket = SOCK_STREAM
#else
import Glibc
private let streamSocket = Int32(SOCK_STREAM.rawValue)
#endif

/// A request as the server read it. Paths are percent-decoded; header names are lowercased.
struct HTTPRequest {
    var method: String
    var path: String
    var query: [String: String]
    var headers: [String: String]
    var body: Data
    /// The request head exactly as received (for proxying), and any bytes read past the body.
    var rawHead: Data
    var extra: Data
    var peer: String

    func json() -> [String: Any]? { (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] }
}

/// One client connection. Responses always close the connection afterwards (the ingress proxy and go2rtc
/// both cope), which keeps the server simple: one thread per request.
final class HTTPConnection {
    let fd: Int32
    private(set) var isOpen = true

    init(fd: Int32) { self.fd = fd }

    @discardableResult
    func write(_ data: Data) -> Bool {
        guard isOpen else { return false }
        var sent = 0
        while sent < data.count {
            let n = data.withUnsafeBytes { raw -> Int in
                #if canImport(Darwin)
                Darwin.send(fd, raw.baseAddress! + sent, data.count - sent, 0)
                #else
                Glibc.send(fd, raw.baseAddress! + sent, data.count - sent, Int32(MSG_NOSIGNAL))
                #endif
            }
            if n <= 0 { if errno == EINTR { continue }; isOpen = false; return false }
            sent += n
        }
        return true
    }

    func respond(_ status: Int, _ body: Data = Data(), type: String = "text/plain; charset=utf-8", headers: [String: String] = [:]) {
        var head = "HTTP/1.1 \(status) \(Self.reason(status))\r\nContent-Type: \(type)\r\nContent-Length: \(body.count)\r\n"
        head += "Connection: close\r\nCache-Control: no-store\r\n"
        for (k, v) in headers { head += "\(k): \(v)\r\n" }
        write(Data((head + "\r\n").utf8) + body)
    }

    func respondJSON(_ value: Any, status: Int = 200) {
        let data = (try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])) ?? Data("{}".utf8)
        respond(status, data, type: "application/json")
    }

    func respondError(_ status: Int, _ message: String) { respondJSON(["error": message], status: status) }

    /// Starts an open-ended response (a live stream or server-sent events): the body follows via `write`.
    func beginStream(type: String, headers: [String: String] = [:]) -> Bool {
        var head = "HTTP/1.1 200 OK\r\nContent-Type: \(type)\r\nConnection: close\r\nCache-Control: no-store\r\n"
        for (k, v) in headers { head += "\(k): \(v)\r\n" }
        return write(Data((head + "\r\n").utf8))
    }

    private var closed = false
    private let closeLock = NSLock()

    func close() {
        guard closeLock.withLock({ () -> Bool in defer { closed = true }; return !closed }) else { return }
        isOpen = false
        shutdown(fd, Int32(SHUT_RDWR))
        #if canImport(Darwin)
        Darwin.close(fd)
        #else
        Glibc.close(fd)
        #endif
    }

    /// Reads whatever is available (blocking); empty at end of stream.
    func read(max: Int = 65536) -> Data {
        var buffer = [UInt8](repeating: 0, count: max)
        while true {
            let n = recv(fd, &buffer, max, 0)
            if n < 0 && errno == EINTR { continue }
            return n > 0 ? Data(buffer[0..<n]) : Data()
        }
    }

    static func reason(_ status: Int) -> String {
        switch status {
        case 200: "OK"
        case 204: "No Content"
        case 206: "Partial Content"
        case 400: "Bad Request"
        case 403: "Forbidden"
        case 404: "Not Found"
        case 416: "Range Not Satisfiable"
        case 502: "Bad Gateway"
        case 503: "Service Unavailable"
        default: "Error"
        }
    }
}

/// A minimal HTTP/1.1 server on POSIX sockets: one thread per connection, enough for a handful of viewers.
final class HTTPServer {
    private let port: UInt16
    private let allowedPeers: Set<String>?
    private let allowedPrefixes: [String]
    private let handler: (HTTPRequest, HTTPConnection) -> Void

    /// `allowedPeers`: client addresses that may connect (nil = anyone); `allowedPrefixes`: address prefixes that
    /// may too (e.g. "192.168.1." for the home network).
    init(port: UInt16, allowedPeers: Set<String>?, allowedPrefixes: [String] = [],
         handler: @escaping (HTTPRequest, HTTPConnection) -> Void) {
        self.port = port
        self.allowedPeers = allowedPeers
        self.allowedPrefixes = allowedPrefixes
        self.handler = handler
    }

    func run() throws -> Never {
        signal(SIGPIPE, SIG_IGN)
        let listener = socket(AF_INET, streamSocket, 0)
        guard listener >= 0 else { throw POSIXError(.EIO) }
        var on: Int32 = 1
        setsockopt(listener, SOL_SOCKET, SO_REUSEADDR, &on, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = INADDR_ANY
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(listener, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bound == 0, listen(listener, 64) == 0 else { throw POSIXError(.EADDRINUSE) }
        while true {
            var peer = sockaddr_in()
            var length = socklen_t(MemoryLayout<sockaddr_in>.size)
            let fd = withUnsafeMutablePointer(to: &peer) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { accept(listener, $0, &length) }
            }
            guard fd >= 0 else { continue }
            var ip = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            inet_ntop(AF_INET, &peer.sin_addr, &ip, socklen_t(INET_ADDRSTRLEN))
            let peerIP = String(cString: ip)
            let connection = HTTPConnection(fd: fd)
            if let allowedPeers, !allowedPeers.contains(peerIP), !allowedPrefixes.contains(where: { peerIP.hasPrefix($0) }) {
                connection.respond(403, Data("Forbidden".utf8))
                connection.close()
                continue
            }
            Thread.detachNewThread { [handler] in
                defer { connection.close() }
                guard let request = Self.readRequest(connection, peer: peerIP) else { return }
                handler(request, connection)
            }
        }
    }

    private static func readRequest(_ connection: HTTPConnection, peer: String) -> HTTPRequest? {
        var buffer = Data()
        let separator = Data("\r\n\r\n".utf8)
        var headEnd: Range<Data.Index>?
        while headEnd == nil {
            let chunk = connection.read()
            if chunk.isEmpty || buffer.count > 64 * 1024 { return nil }
            buffer += chunk
            headEnd = buffer.range(of: separator)
        }
        guard let headEnd else { return nil }
        let head = buffer[..<headEnd.lowerBound]
        var lines = String(decoding: head, as: UTF8.self).components(separatedBy: "\r\n")
        let parts = lines.removeFirst().split(separator: " ")
        guard parts.count >= 2 else { return nil }
        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        var rest = Data(buffer[headEnd.upperBound...])
        let length = Int(headers["content-length"] ?? "") ?? 0
        while rest.count < length {
            let chunk = connection.read()
            if chunk.isEmpty { return nil }
            rest += chunk
        }
        let target = String(parts[1])
        let components = URLComponents(string: target)
        var query: [String: String] = [:]
        for item in components?.queryItems ?? [] { query[item.name] = item.value ?? "" }
        return HTTPRequest(method: String(parts[0]), path: components?.percentEncodedPath.removingPercentEncoding ?? target,
                           query: query, headers: headers, body: rest.prefix(length),
                           rawHead: Data(buffer[..<headEnd.upperBound]), extra: rest.dropFirst(length), peer: peer)
    }

    /// Relays a request to another local HTTP server (go2rtc), byte for byte in both directions, so
    /// WebSocket upgrades pass through too. `path` replaces the request's path.
    static func proxy(_ request: HTTPRequest, path: String, to port: UInt16, over connection: HTTPConnection) {
        let upstream = socket(AF_INET, streamSocket, 0)
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let ok = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(upstream, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        let target = HTTPConnection(fd: upstream)
        guard upstream >= 0, ok == 0 else { target.close(); connection.respondError(502, "go2rtc isn't running"); return }
        // Rewrite the request line's path; keep every header (Upgrade, Sec-WebSocket-*, …).
        var head = String(decoding: request.rawHead, as: UTF8.self)
        if let lineEnd = head.range(of: "\r\n") {
            let query = URLComponents(string: String(head[..<lineEnd.lowerBound].split(separator: " ")[1]))?.percentEncodedQuery
            head.replaceSubrange(head.startIndex..<lineEnd.lowerBound,
                                 with: "\(request.method) \(path)\(query.map { "?\($0)" } ?? "") HTTP/1.1")
        }
        // Plain requests must end with their response: otherwise the browser reuses this (piped) connection
        // and its next API call lands on go2rtc instead of the bridge. WebSocket upgrades stay open.
        if request.headers["upgrade"] == nil {
            var lines = head.components(separatedBy: "\r\n").filter { !$0.lowercased().hasPrefix("connection:") && !$0.lowercased().hasPrefix("keep-alive:") }
            lines.insert("Connection: close", at: 1)
            head = lines.joined(separator: "\r\n")
        }
        target.write(Data(head.utf8) + request.body + request.extra)
        let done = DispatchSemaphore(value: 0)
        Thread.detachNewThread {
            while true {
                let chunk = connection.read()
                if chunk.isEmpty || !target.write(chunk) { break }
            }
            shutdown(upstream, Int32(SHUT_RDWR))
            done.signal()
        }
        while true {
            let chunk = target.read()
            if chunk.isEmpty || !connection.write(chunk) { break }
        }
        shutdown(connection.fd, Int32(SHUT_RDWR))
        done.wait()
        target.close()
    }
}

// MARK: - WebSocket (server → browser binary frames)

/// Enough of RFC 6455 to push binary messages to a browser: the handshake, unmasked server frames, and noticing
/// when the browser closes. (Browsers cap plain HTTP/1.1 at six streaming connections per server; WebSockets
/// don't count against that, so every Multi-View tile can stream at once.)
enum WebSocket {
    static func isUpgrade(_ request: HTTPRequest) -> Bool {
        request.headers["upgrade"]?.lowercased() == "websocket" && request.headers["sec-websocket-key"] != nil
    }

    /// Answers the handshake; returns false if the connection is gone.
    static func accept(_ request: HTTPRequest, _ c: HTTPConnection) -> Bool {
        guard let key = request.headers["sec-websocket-key"] else { return false }
        let accept = Data(SHA1.hash(Data((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").utf8))).base64EncodedString()
        let head = "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: \(accept)\r\n\r\n"
        return c.write(Data(head.utf8))
    }

    static func binaryFrame(_ payload: Data) -> Data {
        var out = Data([0x82])
        switch payload.count {
        case ..<126: out.append(UInt8(payload.count))
        case ..<65536: out.append(126); out.append(UInt8(payload.count >> 8)); out.append(UInt8(payload.count & 0xFF))
        default:
            out.append(127)
            for shift in stride(from: 56, through: 0, by: -8) { out.append(UInt8((UInt64(payload.count) >> UInt64(shift)) & 0xFF)) }
        }
        return out + payload
    }

    /// Reads (and ignores) what the browser sends until it closes or sends a close frame, then calls `onClose`.
    static func watchForClose(_ c: HTTPConnection, onClose: @escaping () -> Void) {
        Thread.detachNewThread {
            while true {
                let data = c.read(max: 4096)
                if data.isEmpty { break }
                // A close frame's first byte is 0x88 (FIN + opcode 8); masked client frames still start with it.
                if data.first.map({ $0 & 0x0F == 0x8 }) == true { break }
            }
            onClose()
        }
    }
}

/// SHA-1, only for the WebSocket handshake's accept key.
enum SHA1 {
    static func hash(_ message: Data) -> [UInt8] {
        var h: [UInt32] = [0x67452301, 0xEFCDAB89, 0x98BADCFE, 0x10325476, 0xC3D2E1F0]
        var bytes = [UInt8](message)
        let bitLength = UInt64(bytes.count) * 8
        bytes.append(0x80)
        while bytes.count % 64 != 56 { bytes.append(0) }
        for shift in stride(from: 56, through: 0, by: -8) { bytes.append(UInt8((bitLength >> UInt64(shift)) & 0xFF)) }
        func rotl(_ x: UInt32, _ n: UInt32) -> UInt32 { (x << n) | (x >> (32 - n)) }
        for chunk in stride(from: 0, to: bytes.count, by: 64) {
            var w = [UInt32](repeating: 0, count: 80)
            for i in 0..<16 {
                w[i] = UInt32(bytes[chunk + 4 * i]) << 24 | UInt32(bytes[chunk + 4 * i + 1]) << 16
                    | UInt32(bytes[chunk + 4 * i + 2]) << 8 | UInt32(bytes[chunk + 4 * i + 3])
            }
            for i in 16..<80 { w[i] = rotl(w[i - 3] ^ w[i - 8] ^ w[i - 14] ^ w[i - 16], 1) }
            var (a, b, c, d, e) = (h[0], h[1], h[2], h[3], h[4])
            for i in 0..<80 {
                let (f, k): (UInt32, UInt32) = switch i {
                case 0..<20: ((b & c) | (~b & d), 0x5A827999)
                case 20..<40: (b ^ c ^ d, 0x6ED9EBA1)
                case 40..<60: ((b & c) | (b & d) | (c & d), 0x8F1BBCDC)
                default: (b ^ c ^ d, 0xCA62C1D6)
                }
                let t = rotl(a, 5) &+ f &+ e &+ k &+ w[i]
                (e, d, c, b, a) = (d, c, rotl(b, 30), a, t)
            }
            h[0] &+= a; h[1] &+= b; h[2] &+= c; h[3] &+= d; h[4] &+= e
        }
        return h.flatMap { [UInt8($0 >> 24), UInt8($0 >> 16 & 0xFF), UInt8($0 >> 8 & 0xFF), UInt8($0 & 0xFF)] }
    }
}
