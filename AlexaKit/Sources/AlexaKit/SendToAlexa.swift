import Foundation

/// High-level facade used by the apps, the share extensions and the CLI.
/// It wires `AlexaStore` (persistence) + `AlexaClient` (Alexa API) + `MusicResolver` (link -> phrase).
public struct SendToAlexa: Sendable {
    public let store: AlexaStore
    public let appName: String
    let transport: HTTPTransport

    public init(store: AlexaStore, appName: String = "Send to Alexa", transport: HTTPTransport = URLSessionTransport()) {
        self.store = store
        self.appName = appName
        self.transport = transport
    }

    public var isSignedIn: Bool { store.loadCredentials() != nil }

    public var auth: AmazonAuth { AmazonAuth(appName: appName, transport: transport) }

    public var resolver: MusicResolver { MusicResolver(transport: transport) }

    /// Client bound to the stored credentials; refreshed cookies are written back automatically.
    public func client() throws -> AlexaClient {
        guard let credentials = store.loadCredentials() else { throw AlexaError.notSignedIn }
        let store = self.store
        return AlexaClient(credentials: credentials, appName: appName, transport: transport) { updated in
            try? store.saveCredentials(updated)
        }
    }

    // MARK: Sign in / out

    /// Finishes sign-in and stores the credentials. Returns the music-capable devices.
    @discardableResult
    public func completeSignIn(
        _ login: AmazonLoginRequest,
        redirectURL: URL,
        websiteCookies: [String: String] = [:]
    ) async throws -> [EchoDevice] {
        guard let code = AmazonLoginRequest.authorizationCode(from: redirectURL) else {
            throw AlexaError.signInFailed("the redirect URL has no authorization code")
        }
        let credentials = try await auth.register(login, authorizationCode: code, websiteCookies: websiteCookies)
        try store.saveCredentials(credentials)
        return try await refreshDevices()
    }

    /// Removes our virtual device from the Amazon account (best effort) and wipes local data.
    public func signOut() async {
        if let credentials = store.loadCredentials() {
            try? await auth.deregister(credentials)
        }
        try? store.reset()
    }

    // MARK: Devices

    /// Fetches music-capable devices, caches them, and picks a default if none is set.
    @discardableResult
    public func refreshDevices() async throws -> [EchoDevice] {
        let devices = try await client().musicDevices()
        try store.updatePreferences { prefs in
            prefs.cachedDevices = devices
            Self.repairDefault(&prefs)
        }
        return devices
    }

    /// Hides (or shows again) an Echo everywhere it would be offered, keeping the default valid.
    public func setHidden(_ hidden: Bool, device serial: String) throws {
        try store.updatePreferences { prefs in
            prefs.hiddenDeviceSerials.removeAll { $0 == serial }
            if hidden { prefs.hiddenDeviceSerials.append(serial) }
            Self.repairDefault(&prefs)
        }
    }

    /// Makes sure the default Echo exists and isn't hidden.
    static func repairDefault(_ prefs: inout Preferences) {
        let visible = prefs.visibleDevices
        if prefs.defaultDeviceSerial == nil || !visible.contains(where: { $0.serialNumber == prefs.defaultDeviceSerial }) {
            prefs.defaultDeviceSerial = suggestedDefault(in: visible)?.serialNumber
        }
    }

    /// A sensible default: an online Echo speaker, then any online single device, then anything.
    /// Speaker groups come last because Amazon doesn't always accept them for this action.
    static func suggestedDefault(in devices: [EchoDevice]) -> EchoDevice? {
        let online = devices.filter { $0.online ?? true }
        return online.first { $0.deviceFamily == "ECHO" }
            ?? online.first { !$0.isSpeakerGroup && $0.deviceFamily != "FIRE_TV" }
            ?? online.first { !$0.isSpeakerGroup }
            ?? online.first
            ?? devices.first
    }

    // MARK: Play

    /// Plays `searchPhrase` on `device` using the user's preferred provider (or `provider` if given),
    /// and remembers `device` as the default for next time.
    @discardableResult
    public func play(_ searchPhrase: String, on device: EchoDevice, provider: MusicProvider? = nil) async throws -> String {
        let prefs = store.loadPreferences()
        let result = try await client().play(searchPhrase, provider: provider ?? prefs.provider, on: device)
        try? store.updatePreferences { $0.defaultDeviceSerial = device.serialNumber }
        return result
    }
}
