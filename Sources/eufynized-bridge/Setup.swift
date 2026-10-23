import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import EufyKit

/// First-run sign-in, done by the bridge itself (no Mac needed): the page posts the eufy email and password,
/// the bridge signs in once (captcha and 2FA included), reads the HomeBase's cipher id over P2P, fetches the
/// station's ECC key and the camera list from the cloud, writes `bridge.json`, and restarts itself. The
/// password and the cloud session are kept in memory only, for the minutes this takes.
///
/// Used in two places: the setup-only server that runs when there is no `bridge.json`, and the normal API
/// (`api/setup…`) for signing in again later (a new camera, a changed account).
final class SetupFlow: @unchecked Sendable {
    enum State: String { case idle, working, captcha, code, done, failed }

    private let lock = NSLock()
    private var state = State.idle
    private var message = ""
    private var captchaImage: Data?
    private var cameraCount = 0
    private var client: EufyCloudClient?
    private var homeBaseIP = ""
    private var stationFilter = ""
    private let configFile: URL
    let configured: Bool

    init(dataDir: URL, configured: Bool) {
        configFile = dataDir.appendingPathComponent("bridge.json")
        self.configured = configured
    }

    var status: [String: Any] {
        lock.withLock {
            ["configured": configured, "state": state.rawValue, "message": message, "cameras": cameraCount,
             "captcha": captchaImage.map { $0.base64EncodedString() } as Any]
        }
    }

    private func set(_ s: State, _ m: String = "") { lock.withLock { state = s; message = m } }

    // MARK: HTTP

    func handle(_ request: HTTPRequest, _ parts: [String], _ c: HTTPConnection) {
        let body = request.json() ?? [:]
        switch (request.method, parts.first ?? "") {
        case ("GET", ""):
            c.respondJSON(status)
        case ("POST", "login"):
            let email = (body["email"] as? String ?? "").trimmingCharacters(in: .whitespaces)
            let password = body["password"] as? String ?? ""
            let ip = (body["homeBaseIP"] as? String ?? "").trimmingCharacters(in: .whitespaces)
            let country = (body["country"] as? String ?? "US").trimmingCharacters(in: .whitespaces).uppercased()
            guard email.contains("@"), !password.isEmpty else { return c.respondError(400, "Enter your eufy email and password.") }
            guard !ip.isEmpty else { return c.respondError(400, "Enter the HomeBase's IP address.") }
            lock.withLock { homeBaseIP = ip; captchaImage = nil; cameraCount = 0 }
            let client = EufyCloudClient(configuration: .init(email: email, countryCode: country.isEmpty ? "US" : country), store: nil)
            lock.withLock { self.client = client }
            set(.working, "Signing in…")
            Task { await self.finish { try await client.signIn(password: password) } }
            c.respondJSON(status)
        case ("POST", "captcha"):
            guard let client = lock.withLock({ client }), let answer = body["answer"] as? String, !answer.isEmpty else { return c.respondError(400, "Enter the characters shown.") }
            set(.working, "Checking…")
            Task { await self.finish { try await client.solveCaptcha(answer) } }
            c.respondJSON(status)
        case ("POST", "code"):
            guard let client = lock.withLock({ client }), let code = body["code"] as? String, !code.isEmpty else { return c.respondError(400, "Enter the code eufy sent you.") }
            set(.working, "Checking the code…")
            Task { await self.finish { try await client.submitVerificationCode(code) } }
            c.respondJSON(status)
        case ("POST", "reset"):
            lock.withLock { state = .idle; message = ""; captchaImage = nil; client = nil }
            c.respondJSON(status)
        default:
            c.respondError(404, "Not found")
        }
    }

    // MARK: Flow

    private func finish(_ step: @escaping () async throws -> EufyCloudClient.LoginResult) async {
        do {
            switch try await step() {
            case .signedIn:
                try await discover()
            case let .captcha(image, retry):
                lock.withLock { captchaImage = image }
                set(.captcha, retry ? "That wasn't right; try again." : "Type the characters in the picture.")
            case .verificationCodeSent:
                set(.code, "eufy sent a verification code to your email or phone.")
            }
        } catch {
            set(.failed, error.localizedDescription)
        }
    }

    /// Cameras and the station key, then `bridge.json`, then a restart of the bridge.
    private func discover() async throws {
        guard let client = lock.withLock({ client }) else { return }
        set(.working, "Finding your cameras…")
        let devices = try await client.devices()
        let cameras = try await client.cameras()
        let stations = devices.filter(\.isStation)
        guard let station = stations.first else { throw SetupError("No HomeBase on this eufy account.") }
        set(.working, "Fetching the camera key for \(station.name)…")
        let ip = lock.withLock { homeBaseIP }
        guard let cipherID = await gatewayCipherID(stationSerial: station.serial, homeBaseIP: ip) else {
            throw SetupError("The HomeBase at \(ip) didn't answer. Check the address (your router's device list shows it as HomeBase or T8030) and that the bridge is on the same network.")
        }
        let ciphers = try await client.getCiphers(cipherIDs: [cipherID], stationSerial: station.serial)
        guard let ecc = ciphers.first(where: { $0.cipherID == cipherID })?.eccPrivateKey ?? ciphers.first?.eccPrivateKey else {
            throw SetupError("eufy didn't return the camera key.")
        }
        guard let accountID = await client.accountUserID else { throw SetupError("No account id after sign-in.") }
        let stationCameras = cameras.filter { $0.stationSerial == station.serial }
        let config = BridgeConfig(homeBaseIP: ip, stationSerial: station.serial, accountID: accountID,
                                  eccPrivateKeyHex: ecc, cameras: stationCameras.isEmpty ? cameras : stationCameras)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(config)
        try FileManager.default.createDirectory(at: configFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: configFile, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: configFile.path)
        lock.withLock { cameraCount = config.cameras.count; self.client = nil }
        set(.done, "Found \(config.cameras.count) camera\(config.cameras.count == 1 ? "" : "s"). Starting…")
        log("setup: signed in, \(config.cameras.count) cameras, key saved to \(configFile.path); restarting")
        await client.signOut()   // the cloud session isn't needed any more
        Thread.detachNewThread { Thread.sleep(forTimeInterval: 1.5); Self.restart() }
    }

    /// The HomeBase cipher_id, read locally from a gateway-info reply (no cloud).
    private func gatewayCipherID(stationSerial: String, homeBaseIP: String) async -> Int? {
        guard let connection = try? HomeBaseConnection(config: .init(
            stationSerial: stationSerial, p2pDID: nil, knownAddress: homeBaseIP.isEmpty ? nil : homeBaseIP)) else { return nil }
        final class Box: @unchecked Sendable { private let l = NSLock(); private var d: Data?; var value: Data? { l.withLock { d } }; func set(_ x: Data) { l.withLock { if d == nil { d = x } } } }
        let box = Box()
        connection.onFrame { _, cmd, _, body in if cmd == 1100 { box.set(body) } }
        guard (try? await connection.connect()) != nil, let did = connection.connectedDID,
              let level1Key = PPPPMessage.commandKey(stationSerial: stationSerial, p2pDID: did) else { connection.close(); return nil }
        connection.sendCommand(1100)
        for _ in 0..<12 where box.value == nil { try? await Task.sleep(for: .milliseconds(300)) }
        connection.close()
        guard let raw = box.value else { return nil }
        return PPPPMessage.gatewayInfoCipherID(decrypted: PPPPMessage.decryptGatewayInfo(raw, level1Key: level1Key))
    }

    /// Starts the bridge over in this same process (so the container keeps running whatever restart policy
    /// it has): on Linux by re-executing /proc/self/exe, else by exiting for the supervisor to restart.
    static func restart() -> Never {
        let args = CommandLine.arguments
        var cargs: [UnsafeMutablePointer<CChar>?] = args.map { strdup($0) }
        cargs.append(nil)
        #if os(Linux)
        execv("/proc/self/exe", &cargs)
        #else
        if let path = Bundle.main.executablePath { execv(path, &cargs) }
        #endif
        exit(0)
    }
}

struct SetupError: LocalizedError {
    let text: String
    init(_ text: String) { self.text = text }
    var errorDescription: String? { text }
}

/// The server that runs when there is no `bridge.json` yet: the page, and the setup API. Nothing else.
struct SetupRoutes {
    let wwwDir: URL
    let setup: SetupFlow

    func handle(_ request: HTTPRequest, _ c: HTTPConnection) {
        let parts = request.path.split(separator: "/").map(String.init)
        switch (request.method, parts.first) {
        case (_, "api") where parts.count >= 2 && parts[1] == "setup":
            setup.handle(request, Array(parts.dropFirst(2)), c)
        case ("GET", "api"):
            c.respondJSON(["setup": true, "version": Bridge.version], status: 503)
        case ("GET", _):
            let relative = request.path == "/" || request.path.isEmpty ? "index.html" : String(request.path.drop(while: { $0 == "/" }))
            guard !relative.contains(".."), let data = try? Data(contentsOf: wwwDir.appendingPathComponent(relative)) else { return c.respondError(404, "Not found") }
            let types = ["html": "text/html; charset=utf-8", "js": "text/javascript; charset=utf-8", "css": "text/css; charset=utf-8", "png": "image/png", "svg": "image/svg+xml"]
            c.respond(200, data, type: types[(relative as NSString).pathExtension] ?? "application/octet-stream", headers: ["Cache-Control": "no-cache"])
        default:
            c.respondError(404, "Not found")
        }
    }
}
