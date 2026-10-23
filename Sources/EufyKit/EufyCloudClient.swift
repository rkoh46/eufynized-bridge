import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Talks to Eufy's cloud the way the official app does: region discovery, `algo_ecdh` key exchange,
/// login (with captcha and two-factor steps), and the device list.
///
/// The cloud is only needed to sign in and to learn which devices exist and how to reach them.
/// Video goes directly to the HomeBase (later phases).
public actor EufyCloudClient {
    public struct Configuration: Sendable {
        public var email: String
        /// Two-letter account country, e.g. "US". Picks the region.
        public var countryCode: String
        public var appName = "eufy_mega"
        public var appVersion = "6.0.41_26142"
        public var osVersion = "36"

        public init(email: String, countryCode: String = "US") {
            self.email = email
            self.countryCode = countryCode.uppercased()
        }
    }

    /// Everything needed to make authenticated calls without signing in again. Stored in the Keychain.
    public struct Session: Codable, Sendable, Equatable {
        public var userId: String
        public var accountUserId: String
        public var authToken: String
        public var region: String
        public var shareKey: String
        public var keyIdent: String
        public var openudid: String
        public var phoneModel: String
        public var tokenExpiresAt: TimeInterval
    }

    public enum LoginResult: Sendable, Equatable {
        case signedIn
        /// Solve the captcha image and call `solveCaptcha`. `retry` means the last answer was wrong.
        case captcha(image: Data?, retry: Bool)
        /// A code was sent to the account's email or phone; pass it to `submitVerificationCode`.
        case verificationCodeSent
    }

    public enum CloudError: LocalizedError, Equatable {
        case api(status: Int, code: Int?, message: String)
        case invalidResponse(String)
        case notSignedIn
        case noPendingCaptcha

        public var errorDescription: String? {
            switch self {
            case let .api(status, code, message): "Eufy cloud error \(code.map(String.init) ?? "-") (HTTP \(status)): \(message)"
            case let .invalidResponse(detail): "Unexpected reply from the Eufy cloud: \(detail)"
            case .notSignedIn: "Not signed in to Eufy."
            case .noPendingCaptcha: "There is no captcha to answer. Sign in again."
            }
        }
    }

    /// Error codes the gateway returns in its `code` field.
    enum ErrorCode {
        static let signatureInvalid = 4416
        static let identityKeyStale = 4404
        static let probeRetry = 10000
        static let sessionKicked = 26084
        static let captchaRequired = 100032
        static let captchaWrong = 100033
    }

    private let config: Configuration
    private let urlSession: URLSession
    private let store: EufySessionStore?
    private var region: String
    private let openudid: String
    private let phoneModel: String
    private var shareKey: String?
    private var keyIdent: String?
    private var auth: (userId: String, accountUserId: String, authToken: String, expiresAt: TimeInterval)?
    private var pendingCaptchaID: String?
    private var password: String?
    private var contentTypeByHost: [String: String] = [:]

    /// - Parameter store: where to keep the session; pass nil to keep it in memory only.
    public init(configuration: Configuration, store: EufySessionStore? = EufySessionStore(), urlSession: URLSession = .shared) {
        config = configuration
        self.urlSession = urlSession
        self.store = store
        // Compute everything first: an actor's init can't read its own properties back.
        let saved = store?.load(email: configuration.email)
        let udid = saved?.openudid ?? EufyIdentity.openudid(email: configuration.email)
        region = saved?.region ?? "us-pr"
        openudid = udid
        phoneModel = saved?.phoneModel ?? EufyIdentity.phoneModel(seed: udid)
        shareKey = saved?.shareKey
        keyIdent = saved?.keyIdent
        auth = saved.map { ($0.userId, $0.accountUserId, $0.authToken, $0.tokenExpiresAt) }
    }

    /// The account user id, used as `account_id` in media commands. Available from a saved session.
    public var accountUserID: String? { auth?.accountUserId }
    /// The individual user id from the login reply.
    public var userID: String? { auth?.userId }

    public var isSignedIn: Bool {
        guard let auth, shareKey != nil else { return false }
        return auth.expiresAt == 0 || auth.expiresAt > Date().timeIntervalSince1970
    }

    // MARK: Sign in

    /// Starts sign-in. The password is held in memory only, for the captcha/two-factor steps.
    public func signIn(password: String) async throws -> LoginResult {
        self.password = password
        auth = nil
        shareKey = nil
        keyIdent = nil
        try await estimateDomain()
        return try await attemptLogin(extra: ["answer": "", "captcha_id": "", "verify_code": "", "login_id": ""])
    }

    public func solveCaptcha(_ answer: String) async throws -> LoginResult {
        guard let id = pendingCaptchaID else { throw CloudError.noPendingCaptcha }
        return try await attemptLogin(extra: ["answer": answer, "captcha_id": id, "verify_code": "", "login_id": ""])
    }

    public func submitVerificationCode(_ code: String) async throws -> LoginResult {
        try await attemptLogin(extra: ["verify_code": code, "login_id": ""])
    }

    public func signOut() {
        auth = nil
        shareKey = nil
        keyIdent = nil
        password = nil
        store?.clear(email: config.email)
    }

    private func attemptLogin(extra: [String: Any]) async throws -> LoginResult {
        guard let password else { throw CloudError.notSignedIn }
        let (clientPublicKey, encryptedPassword) = try EufyCrypto.encryptLoginPassword(password)
        var body: [String: Any] = [
            "email": config.email,
            "password": encryptedPassword,
            "ab": config.countryCode,
            "client_secret_info": ["public_key": clientPublicKey],
        ]
        body.merge(extra) { _, new in new }
        let isVerification = (extra["verify_code"] as? String)?.isEmpty == false

        let reply: [String: Any]
        do {
            reply = try await postSigned(host: "app-passport-\(region).eufy.com", path: "/passport/login",
                                         body: body, authed: auth != nil)
        } catch let CloudError.api(_, code?, _) where code == ErrorCode.captchaRequired || code == ErrorCode.captchaWrong {
            let captcha = try await postSigned(host: "app-passport-\(region).eufy.com", path: "/passport/generate/captcha",
                                               body: [:], authed: false)
            pendingCaptchaID = captcha["captcha_id"] as? String
            return .captcha(image: Self.decodeImage(captcha["item"] as? String), retry: code == ErrorCode.captchaWrong)
        }

        let userId = (reply["ap_cloud_user_id"] ?? reply["user_id"] ?? reply["userId"]) as? String
        let token = (reply["auth_token"] ?? reply["token"]) as? String
        guard let userId, let token else { throw CloudError.invalidResponse("login returned no session") }
        let accountUserId = (reply["user_id"] ?? reply["userId"]) as? String ?? userId
        let expiresAt = (reply["token_expires_at"] as? NSNumber)?.doubleValue ?? 0
        auth = (userId, accountUserId, token, expiresAt)
        pendingCaptchaID = nil

        let twoFactorPending = ((reply["fa_info"] as? [String: Any])?["info"] as? String)?.isEmpty == false
        if twoFactorPending && !isVerification {
            _ = try await postSigned(host: "app-push-\(region).eufy.com", path: "/app/sendmsg/verify_code",
                                     body: ["biz_type": 1004, "message_type": 2,
                                            "transaction": String(Int(Date().timeIntervalSince1970 * 1000))],
                                     authed: true)
            return .verificationCodeSent
        }

        // The gateway binds the user to a key exchanged after login.
        shareKey = nil
        try await ensureSessionKey()
        self.password = nil
        persist()
        return .signedIn
    }

    /// Finds the account's region shard ("us-pr" or "eu-pr").
    private func estimateDomain() async throws {
        var req = URLRequest(url: URL(string: "https://mega-\(region).eufy.com/passport/estimate_domain")!)
        req.httpMethod = "POST"
        baseHeaders().forEach { req.setValue($1, forHTTPHeaderField: $0) }
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        req.httpBody = try JSONSerialization.data(withJSONObject: ["ab": config.countryCode.lowercased(), "mode": 1])
        let (data, _) = try await urlSession.data(for: req)
        let blob = String(decoding: data, as: UTF8.self)
        if blob.contains("-eu-") { region = "eu-pr" } else if blob.contains("-us-") { region = "us-pr" }
    }

    // MARK: Devices

    /// All devices on the account, HomeBases included. Queries every house, as the app does.
    public func devices() async throws -> [EufyDevice] {
        guard isSignedIn else { throw CloudError.notSignedIn }
        var bodies: [[String: Any]] = [[:]]
        if let houses = try? await post(service: "house", path: "/app/house/get_house_list"),
           let infos = houses["house_infos"] as? [[String: Any]] {
            bodies += infos.compactMap { ($0["house_id"]).map { ["house_id": $0] } }
        }
        var bySerial: [String: EufyDevice] = [:]
        for body in bodies {
            let reply = try await post(service: "house", path: "/app/house/get_devs_list", body: body)
            for raw in reply["devices"] as? [[String: Any]] ?? [] {
                if let device = EufyDevice(json: raw) { bySerial[device.serial] = device }
            }
        }
        return bySerial.values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// The account's cameras as a catalog (channel + name + model), skipping HomeBases. Used for the grid.
    public func cameras() async throws -> [CameraInfo] {
        try await devices().compactMap { device in
            guard !device.isStation else { return nil }
            return CameraInfo(serial: device.serial, name: device.name,
                              model: device.productName ?? device.model,
                              channel: device.channel ?? 0, stationSerial: device.stationSerial,
                              isPanTilt: EufyModels.isPanTilt(device.model, deviceType: device.deviceType),
                              hasPrivacyZone: device.hasPrivacyZone, deviceType: device.deviceType)
        }.sorted { $0.channel < $1.channel }
    }

    /// Authenticated call to `app-{service}-{region}.eufy.com`.
    public func post(service: String, path: String, body: [String: Any] = [:]) async throws -> [String: Any] {
        try await postSigned(host: "app-\(service)-\(region).eufy.com", path: path, body: body, authed: true)
    }

    /// The security-app (eufylife) data host for this account's region (US has no suffix).
    func securityAppHost() -> String {
        let shard = region.split(separator: "-").first.map(String.init) ?? "us"
        return shard == "us" ? "security-app.eufylife.com" : "security-app-\(shard).eufylife.com"
    }

    /// Fetches the station's ECC private key(s) for the given cipher ids. One-time; cache the result.
    /// Runs on the eufylife host, which has its own key exchange — often not throttled with the mega hosts.
    public func getCiphers(cipherIDs: [Int], stationSerial: String) async throws -> [(cipherID: Int, eccPrivateKey: String?)] {
        guard let userId = auth?.accountUserId else { throw CloudError.notSignedIn }
        let reply = try await postSigned(host: securityAppHost(), path: "/v3/app/cipher/get_ciphers",
                                         body: ["cipher_ids": cipherIDs, "user_id": userId, "station_sn": stationSerial],
                                         authed: true)
        if ProcessInfo.processInfo.environment["EUFY_DEBUG"] != nil {
            FileHandle.standardError.write(Data("[get_ciphers] reply keys: \(reply.keys.sorted()) — \(String(describing: reply).prefix(400))\n".utf8))
        }
        let list = (reply["ciphers"] as? [[String: Any]]) ?? (reply["data"] as? [[String: Any]])
            ?? (reply["list"] as? [[String: Any]]) ?? (reply["cipher_infos"] as? [[String: Any]]) ?? []
        return list.compactMap { entry in
            guard let id = (entry["cipher_id"] as? NSNumber)?.intValue else { return nil }
            return (id, entry["ecc_private_key"] as? String ?? entry["private_key"] as? String)
        }
    }

    // MARK: Transport

    /// Per-host session keys for data hosts (e.g. eufylife) that run their own key exchange.
    private var hostSessionKeys: [String: (shareKey: String, keyIdent: String)] = [:]

    /// Resolves the (shareKey, keyIdent) to sign a call to `host`, exchanging a key if needed.
    private func sessionKey(for host: String) async throws -> (shareKey: String, keyIdent: String) {
        if host.contains(".eufylife.com") {
            if let cached = hostSessionKeys[host] { return cached }
            let key = try await exchangeKey(host: host, path: "/v3/openapi/oauth/key/exchange",
                                            localKeyHex: EufyCrypto.eufylifeLocalKeyHex)
            hostSessionKeys[host] = key
            return key
        }
        try await ensureSessionKey()
        guard let shareKey, let keyIdent else { throw CloudError.notSignedIn }
        return (shareKey, keyIdent)
    }

    /// One ECDH key exchange against `host` with the given bootstrap key.
    private func exchangeKey(host: String, path: String, localKeyHex: String) async throws -> (shareKey: String, keyIdent: String) {
        let request = try EufyCrypto.prepareKeyExchange(localKeyHex: localKeyHex)
        var req = URLRequest(url: URL(string: "https://\(host)\(path)")!)
        req.httpMethod = "POST"
        req.timeoutInterval = 20
        baseHeaders().forEach { req.setValue($1, forHTTPHeaderField: $0) }
        request.headers.forEach { req.setValue($1, forHTTPHeaderField: $0) }
        authHeaders().forEach { req.setValue($1, forHTTPHeaderField: $0) }
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        req.httpBody = try JSONSerialization.data(withJSONObject: ["client_public_key": request.encryptedClientPublicKey])
        let (data, response) = try await urlSession.data(for: req)
        let envelope = try Self.envelope(data)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200, envelope.code == 0,
              let serverKey = (envelope.data as? [String: Any])?["server_public_key"] as? String
                ?? (envelope.data as? [String: Any])?["public_key"] as? String
                ?? envelope.data as? String else {
            throw CloudError.api(status: status, code: envelope.code, message: "key exchange (\(host)): \(envelope.message)")
        }
        return (try EufyCrypto.finishKeyExchange(request, serverPublicKeyBase64: serverKey), request.keyIdent)
    }

    private func ensureSessionKey() async throws {
        if shareKey != nil { return }
        let request = try EufyCrypto.prepareKeyExchange()
        var req = URLRequest(url: URL(string: "https://app-openapi-\(region).eufy.com/openapi/oauth/key/exchange")!)
        req.httpMethod = "POST"
        baseHeaders().forEach { req.setValue($1, forHTTPHeaderField: $0) }
        request.headers.forEach { req.setValue($1, forHTTPHeaderField: $0) }
        authHeaders().forEach { req.setValue($1, forHTTPHeaderField: $0) }
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        req.httpBody = try JSONSerialization.data(withJSONObject: ["client_public_key": request.encryptedClientPublicKey])
        let (data, response) = try await urlSession.data(for: req)
        let envelope = try Self.envelope(data)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200, envelope.code == 0,
              let serverKey = (envelope.data as? [String: Any])?["server_public_key"] as? String
                ?? (envelope.data as? [String: Any])?["public_key"] as? String
                ?? envelope.data as? String else {
            throw CloudError.api(status: status, code: envelope.code, message: "key exchange: \(envelope.message)")
        }
        shareKey = try EufyCrypto.finishKeyExchange(request, serverPublicKeyBase64: serverKey)
        keyIdent = request.keyIdent
    }

    private func postSigned(host: String, path: String, body: [String: Any], authed: Bool,
                            retriedKey: Bool = false) async throws -> [String: Any] {
        let (shareKey, keyIdent) = try await sessionKey(for: host)
        let plaintext = try JSONSerialization.data(withJSONObject: body)
        let encrypted = try EufyCrypto.encryptBody(plaintext, shareKeyHex: shareKey)

        // The gateway insists on a particular content type per host and answers 4416 to the wrong one.
        let preferred = contentTypeByHost[host] ?? (path.contains("/passport/") ? "text/plain" : "application/json")
        var last = CloudError.invalidResponse("no response")
        for contentType in [preferred, preferred == "text/plain" ? "application/json" : "text/plain"] {
            var req = URLRequest(url: URL(string: "https://\(host)\(path)")!)
            req.httpMethod = "POST"
            req.timeoutInterval = 20
            baseHeaders().forEach { req.setValue($1, forHTTPHeaderField: $0) }
            let ts = EufyCrypto.unixTimestamp(), once = EufyCrypto.randomID()
            [
                "content-type": contentType,
                "x-encryption-info": "algo_ecdh",
                "x-key-ident": keyIdent,
                "x-request-ts": ts,
                "x-request-once": once,
                "x-signature": EufyCrypto.sign(shareKeyHex: shareKey, ts: ts, once: once, encryptedBody: encrypted),
                "x-replay-info": "replay",
            ].forEach { req.setValue($1, forHTTPHeaderField: $0) }
            if authed { authHeaders().forEach { req.setValue($1, forHTTPHeaderField: $0) } }
            req.httpBody = Data(encrypted.utf8)

            let (data, response) = try await urlSession.data(for: req)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            let envelope = try Self.envelope(data)
            if status == 200, envelope.code == 0 {
                contentTypeByHost[host] = contentType
                guard let encryptedReply = envelope.data as? String, !encryptedReply.isEmpty else {
                    return envelope.data as? [String: Any] ?? [:]
                }
                let decrypted = try EufyCrypto.decryptBody(encryptedReply, shareKeyHex: shareKey)
                let obj = try? JSONSerialization.jsonObject(with: decrypted)
                if let dict = obj as? [String: Any] { return dict }
                if let array = obj as? [Any] { return ["data": array] }   // some endpoints reply a bare array
                return [:]
            }

            last = .api(status: status, code: envelope.code, message: Self.redactingToken(envelope.message))
            if envelope.code == ErrorCode.identityKeyStale, !retriedKey {
                if host.contains(".eufylife.com") { hostSessionKeys[host] = nil } else { self.shareKey = nil }
                return try await postSigned(host: host, path: path, body: body, authed: authed, retriedKey: true)
            }
            let retryable = (status == 403 && envelope.code == ErrorCode.signatureInvalid)
                || envelope.code == ErrorCode.probeRetry || status == 400
            if !retryable { break }
        }
        if case let .api(status, code, _) = last, status == 401 || code == ErrorCode.sessionKicked {
            signOut()
        }
        throw last
    }

    /// Headers the app sends on every call (both dash and underscore spellings, as the app does).
    private func baseHeaders() -> [String: String] {
        [
            "app-name": config.appName,
            "app-version": config.appVersion, "app_version": config.appVersion,
            "os-type": "android", "os_type": "android",
            "os-version": config.osVersion, "os_version": config.osVersion,
            "phone-model": phoneModel, "phone_model": phoneModel,
            "model-type": "PHONE",
            "country": config.countryCode, "ab_code": config.countryCode,
            "openudid": openudid,
            "language": "en",
            "test-flag": "false",
            "user-agent": "ktor-client",
            "accept": "application/json",
            "accept-charset": "UTF-8",
        ]
    }

    private func authHeaders() -> [String: String] {
        guard let auth else { return [:] }
        return [
            "x-auth-token": auth.authToken,
            "authorization": auth.authToken,
            "gtoken": EufyCrypto.gtoken(userId: auth.accountUserId),
        ]
    }

    private func persist() {
        guard let auth, let shareKey, let keyIdent else { return }
        store?.save(Session(userId: auth.userId, accountUserId: auth.accountUserId, authToken: auth.authToken,
                            region: region, shareKey: shareKey, keyIdent: keyIdent, openudid: openudid,
                            phoneModel: phoneModel, tokenExpiresAt: auth.expiresAt),
                    email: config.email)
    }

    // MARK: Helpers

    struct Envelope {
        var code: Int?
        var message: String
        var data: Any?
    }

    static func envelope(_ data: Data) throws -> Envelope {
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw CloudError.invalidResponse(String(decoding: data.prefix(200), as: UTF8.self))
        }
        return Envelope(code: (json["code"] as? NSNumber)?.intValue, message: json["msg"] as? String ?? "", data: json["data"])
    }

    /// Some errors echo the auth token back; never surface it.
    static func redactingToken(_ message: String) -> String {
        message.replacingOccurrences(of: #"token\s*=\s*[A-Za-z0-9._-]{12,}"#, with: "token=…", options: .regularExpression)
    }

    /// Captcha images arrive as base64, sometimes as a data URL.
    static func decodeImage(_ string: String?) -> Data? {
        guard let string else { return nil }
        let base64 = string.range(of: "base64,").map { String(string[$0.upperBound...]) } ?? string
        return Data(base64Encoded: base64)
    }
}

/// The device identity the cloud binds the session to. Stable per account so signing in again
/// doesn't look like a new phone each time.
enum EufyIdentity {
    static func openudid(email: String) -> String {
        String(EufyCrypto.md5Hex("eufy-mega:\(email.lowercased())").prefix(16))
    }

    static let models = ["Pixel 7", "Pixel 8", "Pixel 8a", "SM-S911B", "SM-S918B", "SM-A546B", "SM-G991B", "CPH2451"]

    static func phoneModel(seed: String) -> String {
        let value = seed.unicodeScalars.reduce(UInt32(2166136261)) { ($0 ^ $1.value) &* 16777619 }
        return models[Int(value % UInt32(models.count))]
    }
}

/// Saves the signed-in session in the Keychain, one entry per account email.
public struct EufySessionStore: Sendable {
    public init() {}

    public func load(email: String) -> EufyCloudClient.Session? {
        SecretStore.read(account(email)).flatMap { try? JSONDecoder().decode(EufyCloudClient.Session.self, from: Data($0.utf8)) }
    }

    public func save(_ session: EufyCloudClient.Session, email: String) {
        guard let data = try? JSONEncoder().encode(session) else { return }
        SecretStore.write(String(decoding: data, as: UTF8.self), account: account(email))
    }

    public func clear(email: String) {
        SecretStore.write(nil, account: account(email))
    }

    /// Whether a session is in the secrets file (checked without touching the Keychain).
    public func hasStoredSession(email: String) -> Bool {
        SecretStore.isStoredInFile(account(email))
    }

    private func account(_ email: String) -> String { "eufy-session:\(email.lowercased())" }
}
