import Foundation
#if canImport(Security)
import Security
#endif

/// Stores the app's two secrets (the Eufy session and each station's ECC key) in a file only the user can
/// read: `~/Library/Application Support/Eufynized/secrets.json`, mode 0600 in a 0700 folder.
///
/// Why not the Keychain: macOS tags each item with the creating app's partition. Without a paid Apple
/// Developer team ID, that partition is the exact build hash, so every new build of Eufynized (and every
/// diagnostic tool) triggered a password prompt per secret. The trade-off: other programs running as this
/// user could read the file. Values saved by earlier versions in the Keychain are moved here once.
public enum SecretStore {
    public static func read(_ account: String) -> String? {
        if let value = lock.withLock({ load()[account] }) { return value.isEmpty ? nil : value }
        #if canImport(Security)
        guard let migrated = LegacyKeychain.read(account) else { return nil }
        write(migrated, account: account)
        return migrated
        #else
        return nil
        #endif
    }

    /// True when `account` has a value in the secrets file. Never looks in the legacy Keychain, so tools
    /// that run unattended can check first and skip, instead of risking a password prompt.
    public static func isStoredInFile(_ account: String) -> Bool {
        lock.withLock { !(load()[account] ?? "").isEmpty }
    }

    public static func write(_ value: String?, account: String) {
        lock.withLock {
            var all = load()
            all[account] = value?.isEmpty == false ? value : ""   // blank = cleared; stops a re-migration
            save(all)
        }
    }

    // MARK: File

    private static let lock = NSLock()

    /// `EUFYNIZED_DATA_DIR` overrides the folder (the Home Assistant add-on keeps it in its `/data` volume).
    static var directory: URL {
        if let dir = ProcessInfo.processInfo.environment["EUFYNIZED_DATA_DIR"], !dir.isEmpty {
            return URL(fileURLWithPath: dir, isDirectory: true)
        }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Eufynized", isDirectory: true)
    }
    static var file: URL { directory.appendingPathComponent("secrets.json") }

    private static func load() -> [String: String] {
        guard let data = try? Data(contentsOf: file),
              let all = try? JSONDecoder().decode([String: String].self, from: data) else { return [:] }
        return all
    }

    private static func save(_ all: [String: String]) {
        let fm = FileManager.default
        try? fm.createDirectory(at: directory, withIntermediateDirectories: true,
                                attributes: [.posixPermissions: 0o700])
        guard let data = try? JSONEncoder().encode(all) else { return }
        // Write to a private temp file, then swap it in, so the secrets are never briefly world-readable.
        let temp = directory.appendingPathComponent(".secrets-\(UUID().uuidString)")
        guard fm.createFile(atPath: temp.path, contents: data, attributes: [.posixPermissions: 0o600]) else { return }
        if (try? fm.replaceItemAt(file, withItemAt: temp)) == nil {
            try? fm.removeItem(at: temp)
        }
        try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
}

#if canImport(Security)
/// Read-only access to where earlier versions kept the secrets, for the one-time move into `SecretStore`.
enum LegacyKeychain {
    static func read(_ account: String) -> String? {
        for service in ["io.github.rkoh46.Eufynized", "Eufynized"] {
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: account,
                kSecReturnData as String: true,
            ]
            var item: CFTypeRef?
            if SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
               let data = item as? Data, !data.isEmpty, let value = String(data: data, encoding: .utf8) {
                return value
            }
        }
        return nil
    }
}
#endif
