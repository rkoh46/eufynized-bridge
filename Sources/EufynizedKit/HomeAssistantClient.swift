import Foundation

/// Minimal Home Assistant REST client, authenticated with a long-lived access token.
public struct HomeAssistantClient: Sendable {
    public struct EntityState: Decodable, Sendable, Equatable {
        public struct Attributes: Decodable, Sendable, Equatable {
            public var friendly_name: String?
        }
        public var entity_id: String
        public var state: String
        public var attributes: Attributes

        public init(entity_id: String, state: String, friendlyName: String? = nil) {
            self.entity_id = entity_id
            self.state = state
            self.attributes = Attributes(friendly_name: friendlyName)
        }
    }

    public let baseURL: URL
    let token: String
    let session: URLSession

    public init(baseURL: URL, token: String, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.token = token
        self.session = session
    }

    public func states() async throws -> [EntityState] {
        let (data, response) = try await session.data(for: request(path: "api/states"))
        try HTTPError.check(response)
        return try JSONDecoder().decode([EntityState].self, from: data)
    }

    public func pressButton(_ entityID: String) async throws {
        var req = request(path: "api/services/button/press")
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONEncoder().encode(["entity_id": entityID])
        let (_, response) = try await session.data(for: req)
        try HTTPError.check(response)
    }

    /// Latest still image Home Assistant has for a camera. For Eufy battery cameras this is the
    /// last event image, so fetching it does not wake the camera.
    public func snapshot(_ cameraEntity: String) async throws -> Data {
        let (data, response) = try await session.data(for: request(path: "api/camera_proxy/\(cameraEntity)"))
        try HTTPError.check(response)
        return data
    }

    func request(path: String) -> URLRequest {
        var req = URLRequest(url: baseURL.appending(path: path))
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.timeoutInterval = 15
        return req
    }
}
