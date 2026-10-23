import Foundation

/// Talks to a go2rtc server (https://github.com/AlexxIT/go2rtc), which relays camera streams
/// as WebRTC, MSE, HLS and RTSP.
public struct Go2RTCClient: Sendable {
    public struct Stream: Decodable, Sendable, Equatable {
        public struct Producer: Decodable, Sendable, Equatable {
            public var url: String?
            public var bytes_recv: Int?

            public init(url: String? = nil, bytes_recv: Int? = nil) {
                self.url = url
                self.bytes_recv = bytes_recv
            }
        }
        public var producers: [Producer]?

        public init(producers: [Producer]? = nil) {
            self.producers = producers
        }

        /// The eufy_security integration registers P2P streams pointing at this unused port until
        /// a stream is started from Home Assistant.
        public static let eufyPlaceholderURL = "tcp://127.0.0.1:65535"

        /// True when this stream only has the placeholder source, so nothing can play yet.
        public var isWaitingForEufyP2P: Bool {
            guard let producers, !producers.isEmpty else { return false }
            return producers.allSatisfy { $0.url == Self.eufyPlaceholderURL && ($0.bytes_recv ?? 0) == 0 }
        }

        public var isReceiving: Bool {
            producers?.contains { ($0.bytes_recv ?? 0) > 0 } ?? false
        }
    }

    public let baseURL: URL
    let session: URLSession

    public init(baseURL: URL, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.session = session
    }

    public func streams() async throws -> [String: Stream] {
        let (data, response) = try await session.data(from: baseURL.appending(path: "api/streams"))
        try HTTPError.check(response)
        return try JSONDecoder().decode([String: Stream].self, from: data)
    }

    public func stream(_ name: String) async throws -> Stream {
        let url = baseURL.appending(path: "api/streams").appending(queryItems: [URLQueryItem(name: "src", value: name)])
        let (data, response) = try await session.data(from: url)
        try HTTPError.check(response)
        return try JSONDecoder().decode(Stream.self, from: data)
    }

    /// Polls until go2rtc is receiving video for `name`, or the timeout passes.
    public func waitUntilReceiving(_ name: String, timeout: Duration = .seconds(20)) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if (try? await stream(name))?.isReceiving == true { return true }
            try? await Task.sleep(for: .milliseconds(750))
        }
        return false
    }

    /// go2rtc's built-in player page; tries WebRTC first, then falls back to MSE and HLS.
    public func playerURL(for stream: String) -> URL {
        baseURL.appending(path: "stream.html").appending(queryItems: [
            URLQueryItem(name: "src", value: stream),
            URLQueryItem(name: "mode", value: "webrtc,mse,hls"),
        ])
    }

    /// RTSP restream address, for VLC, Frigate or anything else that reads RTSP.
    public func rtspURL(for stream: String, port: Int = 8554) -> URL? {
        guard let host = baseURL.host() else { return nil }
        return URL(string: "rtsp://\(host):\(port)/\(stream)")
    }
}

public struct HTTPError: LocalizedError {
    public let status: Int

    public var errorDescription: String? {
        switch status {
        case 401, 403: "Not authorized (HTTP \(status)). Check the access token."
        default: "Server returned HTTP \(status)."
        }
    }

    static func check(_ response: URLResponse) throws {
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw HTTPError(status: http.statusCode)
        }
    }
}
