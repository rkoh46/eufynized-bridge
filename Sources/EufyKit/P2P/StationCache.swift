import Foundation

/// The small amount of station info the P2P layer needs: cached locally so repeated connections don't
/// have to call Eufy's cloud each time (which risks rate-limiting). This holds no credentials.
public struct StationInfo: Codable, Sendable, Equatable {
    public var serial: String
    public var name: String
    public var model: String
    public var p2pDID: String
    public var localIP: String?

    public init(serial: String, name: String, model: String, p2pDID: String, localIP: String?) {
        self.serial = serial
        self.name = name
        self.model = model
        self.p2pDID = p2pDID
        self.localIP = localIP
    }
}

/// A camera the app can show directly: its channel on the HomeBase and a friendly name.
public struct CameraInfo: Codable, Sendable, Equatable, Identifiable {
    public var id: String { serial }
    public var serial: String
    public var name: String
    public var model: String
    public var channel: Int
    public var stationSerial: String
    /// True for pan-tilt models (e.g. SoloCam S340 / T8170) that take PTZ commands.
    public var isPanTilt: Bool
    /// Pan-tilt, also re-checking the serial so a catalog cached before a model was recognised still works.
    public var supportsPTZ: Bool { isPanTilt || EufyModels.isPanTilt(serial) }
    /// A privacy zone is set. The camera then ignores pan/tilt (moving would uncover what the zone hides).
    /// Optional so catalogs cached before this existed still decode.
    public var hasPrivacyZone: Bool?
    /// Cloud `device_type` (picks the settings catalog). Optional so older cached catalogs still decode.
    public var deviceType: Int?

    public init(serial: String, name: String, model: String, channel: Int, stationSerial: String, isPanTilt: Bool,
                hasPrivacyZone: Bool? = nil, deviceType: Int? = nil) {
        self.serial = serial
        self.name = name
        self.model = model
        self.channel = channel
        self.stationSerial = stationSerial
        self.isPanTilt = isPanTilt
        self.hasPrivacyZone = hasPrivacyZone
        self.deviceType = deviceType
    }
}

/// Caches each station's ECC private key (from a one-time get_ciphers call) so per-camera selection
/// never needs the cloud again. Stored with the app's other secrets (`SecretStore`).
public struct CipherKeyCache: Sendable {
    public init() {}

    public func eccPrivateKey(stationSerial: String) -> String? {
        SecretStore.read(account(stationSerial))
    }

    /// Whether the key is in the secrets file (checked without touching the Keychain).
    public func hasStoredKey(stationSerial: String) -> Bool {
        SecretStore.isStoredInFile(account(stationSerial))
    }

    public func save(eccPrivateKey: String, stationSerial: String) {
        SecretStore.write(eccPrivateKey, account: account(stationSerial))
    }

    private func account(_ stationSerial: String) -> String { "eufy-ecc:\(stationSerial.uppercased())" }
}

/// Caches the account's camera catalog (names + channels) so the app shows named cameras offline and
/// picks up new cameras after a refresh.
public struct CameraCatalogCache: Sendable {
    let directory: URL

    public init(directory: URL? = nil) {
        self.directory = directory ?? CameraCatalogCache.defaultDirectory()
    }

    public func load(email: String) -> [CameraInfo]? {
        guard let data = try? Data(contentsOf: file(email)) else { return nil }
        return try? JSONDecoder().decode([CameraInfo].self, from: data)
    }

    public func save(_ cameras: [CameraInfo], email: String) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(cameras) else { return }
        try? data.write(to: file(email))
    }

    private func file(_ email: String) -> URL { directory.appending(path: "cameras-\(email.lowercased()).json") }

    static func defaultDirectory() -> URL {
        (try? FileManager.default.url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appending(path: "Eufynized", directoryHint: .isDirectory))
            ?? URL(fileURLWithPath: NSTemporaryDirectory()).appending(path: "Eufynized")
    }
}

/// Caches the account's stations in the app's caches directory, keyed by account email.
public struct StationCache: Sendable {
    let directory: URL

    public init(directory: URL? = nil) {
        self.directory = directory
            ?? (try? FileManager.default.url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
                .appending(path: "Eufynized", directoryHint: .isDirectory))
            ?? URL(fileURLWithPath: NSTemporaryDirectory()).appending(path: "Eufynized")
    }

    public func load(email: String) -> [StationInfo]? {
        guard let data = try? Data(contentsOf: file(email)) else { return nil }
        return try? JSONDecoder().decode([StationInfo].self, from: data)
    }

    public func save(_ stations: [StationInfo], email: String) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(stations) else { return }
        try? data.write(to: file(email))
    }

    private func file(_ email: String) -> URL {
        directory.appending(path: "stations-\(email.lowercased()).json")
    }
}
