import Foundation
#if canImport(Security)
import Security
#endif

/// User choices shared between the app and its share extension.
public struct Preferences: Codable, Equatable, Sendable {
    /// Serial number of the Echo to preselect in the share sheet.
    public var defaultDeviceSerial: String?
    /// Music service Alexa should search.
    public var provider: MusicProvider
    /// Last known device list, so the share sheet can show it instantly.
    public var cachedDevices: [EchoDevice]
    /// When true, the share sheet plays on the default device immediately instead of waiting for a tap.
    public var playImmediately: Bool

    public init(
        defaultDeviceSerial: String? = nil,
        provider: MusicProvider = .appleMusic,
        cachedDevices: [EchoDevice] = [],
        playImmediately: Bool = false
    ) {
        self.defaultDeviceSerial = defaultDeviceSerial
        self.provider = provider
        self.cachedDevices = cachedDevices
        self.playImmediately = playImmediately
    }

    public init(from decoder: Decoder) throws {
        // Tolerant decoding so adding fields never wipes a user's settings.
        let c = try decoder.container(keyedBy: CodingKeys.self)
        defaultDeviceSerial = try c.decodeIfPresent(String.self, forKey: .defaultDeviceSerial)
        provider = (try? c.decodeIfPresent(MusicProvider.self, forKey: .provider)) ?? .appleMusic
        cachedDevices = (try? c.decodeIfPresent([EchoDevice].self, forKey: .cachedDevices)) ?? []
        playImmediately = (try? c.decodeIfPresent(Bool.self, forKey: .playImmediately)) ?? false
    }

    public var defaultDevice: EchoDevice? {
        cachedDevices.first { $0.serialNumber == defaultDeviceSerial }
    }
}

/// Key/value storage for small blobs. Implementations: `KeychainStore` (apps), `FileStore` (CLI), in-memory (tests).
public protocol BlobStore: Sendable {
    func read(_ key: String) throws -> Data?
    func write(_ data: Data?, for key: String) throws
}

/// Typed access to what Send to Alexa persists: credentials (secret) and preferences.
public struct AlexaStore: Sendable {
    public let backing: BlobStore

    public init(_ backing: BlobStore) {
        self.backing = backing
    }

    enum Key {
        static let credentials = "credentials"
        static let preferences = "preferences"
    }

    public func loadCredentials() -> AlexaCredentials? {
        guard let data = try? backing.read(Key.credentials) else { return nil }
        return try? Self.decoder.decode(AlexaCredentials.self, from: data)
    }

    public func saveCredentials(_ credentials: AlexaCredentials?) throws {
        try backing.write(credentials.map { try Self.encoder.encode($0) }, for: Key.credentials)
    }

    public func loadPreferences() -> Preferences {
        guard let data = try? backing.read(Key.preferences),
              let prefs = try? Self.decoder.decode(Preferences.self, from: data)
        else { return Preferences() }
        return prefs
    }

    public func savePreferences(_ preferences: Preferences) throws {
        try backing.write(try Self.encoder.encode(preferences), for: Key.preferences)
    }

    public func updatePreferences(_ change: (inout Preferences) -> Void) throws {
        var prefs = loadPreferences()
        change(&prefs)
        try savePreferences(prefs)
    }

    /// Forgets everything (sign out).
    public func reset() throws {
        try backing.write(nil, for: Key.credentials)
        try backing.write(nil, for: Key.preferences)
    }

    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }()

    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}

// MARK: - Keychain

#if canImport(Security)
/// Stores blobs as generic-password Keychain items.
///
/// To share between an app and its extension, give both targets the same Keychain Sharing group and pass
/// the full group id (`<TeamID>.<group>`) as `accessGroup`. The apps read it from Info.plist (`KeychainAccessGroup`).
public struct KeychainStore: BlobStore {
    public let service: String
    public let accessGroup: String?

    public init(service: String = "SendToAlexa", accessGroup: String? = nil) {
        self.service = service
        self.accessGroup = (accessGroup?.isEmpty ?? true) ? nil : accessGroup
    }

    private func baseQuery(_ key: String) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
        if let accessGroup { query[kSecAttrAccessGroup as String] = accessGroup }
        #if os(macOS)
        // Access groups on macOS only work with the iOS-style "data protection" keychain.
        if accessGroup != nil { query[kSecUseDataProtectionKeychain as String] = true }
        #endif
        return query
    }

    /// Same store without the shared access group. Used when the build isn't signed with the entitlement
    /// (e.g. some simulator builds) so the app still works, just without sharing with the extension.
    private var withoutAccessGroup: KeychainStore? {
        accessGroup == nil ? nil : KeychainStore(service: service, accessGroup: nil)
    }

    public func read(_ key: String) throws -> Data? {
        var query = baseQuery(key)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess: return result as? Data
        case errSecItemNotFound: return nil
        case errSecMissingEntitlement where withoutAccessGroup != nil: return try withoutAccessGroup?.read(key)
        default: throw KeychainError(status: status)
        }
    }

    public func write(_ data: Data?, for key: String) throws {
        do {
            try writeItem(data, for: key)
        } catch let error as KeychainError where error.status == errSecMissingEntitlement && withoutAccessGroup != nil {
            try withoutAccessGroup?.write(data, for: key)
        }
    }

    private func writeItem(_ data: Data?, for key: String) throws {
        let query = baseQuery(key)
        guard let data else {
            let status = SecItemDelete(query as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainError(status: status) }
            return
        }
        let attributes: [String: Any] = [kSecValueData as String: data]
        var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var add = query
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            status = SecItemAdd(add as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw KeychainError(status: status) }
    }
}

public struct KeychainError: LocalizedError {
    public let status: OSStatus
    public var errorDescription: String? {
        let message = SecCopyErrorMessageString(status, nil) as String? ?? "unknown error"
        return "Keychain error \(status): \(message)"
    }
}
#endif

// MARK: - Files

/// Stores each blob as `<directory>/<key>.json` with 0600 permissions. Used by the CLI.
public struct FileStore: BlobStore {
    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    /// `~/.config/send-to-alexa` (or `$SEND_TO_ALEXA_HOME`).
    public static func defaultDirectory() -> URL {
        if let custom = ProcessInfo.processInfo.environment["SEND_TO_ALEXA_HOME"], !custom.isEmpty {
            return URL(fileURLWithPath: custom, isDirectory: true)
        }
        #if os(macOS)
        let home = FileManager.default.homeDirectoryForCurrentUser
        #else
        let home = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
        #endif
        return home
            .appendingPathComponent(".config", isDirectory: true)
            .appendingPathComponent("send-to-alexa", isDirectory: true)
    }

    private func url(_ key: String) -> URL { directory.appendingPathComponent("\(key).json") }

    public func read(_ key: String) throws -> Data? {
        let file = url(key)
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        return try Data(contentsOf: file)
    }

    public func write(_ data: Data?, for key: String) throws {
        let file = url(key)
        guard let data else {
            try? FileManager.default.removeItem(at: file)
            return
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try data.write(to: file, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
}

/// Non-persistent store for tests and previews.
public final class MemoryStore: BlobStore, @unchecked Sendable {
    private var items: [String: Data] = [:]
    private let lock = NSLock()

    public init() {}

    public func read(_ key: String) throws -> Data? {
        lock.withLock { items[key] }
    }

    public func write(_ data: Data?, for key: String) throws {
        lock.withLock { items[key] = data }
    }
}
