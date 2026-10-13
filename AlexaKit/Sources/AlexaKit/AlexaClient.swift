import Foundation

/// Talks to the (unofficial) Alexa web API — the same one the Alexa app and alexa.amazon.com use.
///
/// ```swift
/// let client = AlexaClient(credentials: creds) { updated in try? store.saveCredentials(updated) }
/// let echo = try await client.devices().first { $0.accountName == "Kitchen" }!
/// try await client.play("Better Together by Jack Johnson", provider: .appleMusic, on: echo)
/// ```
///
/// Web cookies are derived from the refresh token on demand and re-derived automatically when they expire;
/// `onCredentialsChange` is called whenever that happens so you can persist the cache.
public actor AlexaClient {
    public private(set) var credentials: AlexaCredentials
    private let transport: HTTPTransport
    private let auth: AmazonAuth
    private let onCredentialsChange: (@Sendable (AlexaCredentials) -> Void)?

    public init(
        credentials: AlexaCredentials,
        appName: String = "Send to Alexa",
        transport: HTTPTransport = URLSessionTransport(),
        onCredentialsChange: (@Sendable (AlexaCredentials) -> Void)? = nil
    ) {
        self.credentials = credentials
        self.transport = transport
        self.auth = AmazonAuth(appName: appName, transport: transport)
        self.onCredentialsChange = onCredentialsChange
    }

    // MARK: - Devices

    /// All Alexa endpoints on the account (use `EchoDevice.musicTargets(_:)` to filter to speakers).
    public func devices() async throws -> [EchoDevice] {
        struct Response: Decodable { let devices: [EchoDevice] }
        let data = try await request("GET", "/api/devices-v2/device?cached=true")
        do {
            return try JSONDecoder().decode(Response.self, from: data).devices
        } catch {
            throw AlexaError.unexpectedResponse("couldn't read device list (\(error.localizedDescription))")
        }
    }

    /// Music-capable devices, online first.
    public func musicDevices() async throws -> [EchoDevice] {
        EchoDevice.musicTargets(try await devices())
    }

    // MARK: - Commands

    /// Asks `device` to play `searchPhrase` from `provider`, exactly like an Alexa routine's "Music" action.
    /// Returns the phrase after Alexa's sanitising (what it'll actually search for).
    @discardableResult
    public func play(_ searchPhrase: String, provider: MusicProvider = .appleMusic, on device: EchoDevice) async throws -> String {
        let operationPayload = try await validatedPlayPayload(searchPhrase, provider: provider, on: device)
        // Run a one-off routine ("PREVIEW") containing the music node.
        try await runSequence(node: [
            "@type": "com.amazon.alexa.behaviors.model.OpaquePayloadOperationNode",
            "type": "Alexa.Music.PlaySearchPhrase",
            "operationPayload": operationPayload,
        ])
        return (operationPayload["sanitizedSearchPhrase"] as? String) ?? searchPhrase
    }

    /// Asks Alexa to validate a play request **without playing anything**.
    /// Returns the sanitised phrase. Throws `AlexaError.invalidSearch` if Alexa rejects it.
    @discardableResult
    public func checkPlay(_ searchPhrase: String, provider: MusicProvider = .appleMusic, on device: EchoDevice) async throws -> String {
        let payload = try await validatedPlayPayload(searchPhrase, provider: provider, on: device)
        return (payload["sanitizedSearchPhrase"] as? String) ?? searchPhrase
    }

    /// Step 1 of playing: Alexa normalises the phrase and tells us if the provider/device combo is OK.
    private func validatedPlayPayload(_ searchPhrase: String, provider: MusicProvider, on device: EchoDevice) async throws -> [String: Any] {
        let phrase = searchPhrase.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !phrase.isEmpty else { throw AlexaError.invalidSearch("search phrase is empty") }

        let basePayload: [String: Any] = [
            "deviceType": device.deviceType,
            "deviceSerialNumber": device.serialNumber,
            "customerId": device.deviceOwnerCustomerId,
            "locale": credentials.locale,
            "musicProviderId": provider.rawValue,
            "searchPhrase": phrase,
        ]

        var operationPayload = basePayload
        let validateBody: [String: Any] = [
            "type": "Alexa.Music.PlaySearchPhrase",
            "operationPayload": try Self.jsonString(basePayload),
        ]
        do {
            let data = try await request("POST", "/api/behaviors/operation/validate", json: validateBody)
            let json = HTTP.jsonObject(data) ?? [:]
            let result = json["result"] as? String
            if let result, result != "VALID" {
                throw AlexaError.invalidSearch(Self.describeValidationFailure(json) ?? result)
            }
            if let validated = Self.payloadDictionary(json["operationPayload"]) {
                operationPayload = validated.merging(basePayload) { validatedValue, _ in validatedValue }
            }
        } catch let error as AlexaError {
            // Validation is a nice-to-have; if the endpoint itself misbehaves, still try to play.
            guard case .http = error else { throw error }
            operationPayload["sanitizedSearchPhrase"] = Self.sanitize(phrase)
        }
        return operationPayload
    }

    /// Makes `device` say `text`. Handy to check that a device is reachable.
    public func speak(_ text: String, on device: EchoDevice) async throws {
        try await runSequence(node: [
            "@type": "com.amazon.alexa.behaviors.model.OpaquePayloadOperationNode",
            "type": "Alexa.Speak",
            "operationPayload": [
                "deviceType": device.deviceType,
                "deviceSerialNumber": device.serialNumber,
                "customerId": device.deviceOwnerCustomerId,
                "locale": credentials.locale,
                "textToSpeak": text,
            ] as [String: Any],
        ])
    }

    /// Raw list of music providers Alexa knows about for this account (debugging aid).
    public func musicProvidersJSON() async throws -> Data {
        try await request("GET", "/api/behaviors/entities?skillId=amzn1.ask.1p.music", extraHeaders: ["Routines-Version": "3.0.264101"])
    }

    // MARK: - Plumbing

    private func runSequence(node: [String: Any]) async throws {
        let sequence: [String: Any] = [
            "@type": "com.amazon.alexa.behaviors.model.Sequence",
            "startNode": node,
        ]
        let body: [String: Any] = [
            "behaviorId": "PREVIEW",
            "sequenceJson": try Self.jsonString(sequence),
            "status": "ENABLED",
        ]
        _ = try await request("POST", "/api/behaviors/preview", json: body)
    }

    /// Makes sure we have a web session, sends the request, and retries once with fresh cookies on auth failure.
    private func request(
        _ method: String,
        _ path: String,
        json: Any? = nil,
        extraHeaders: [String: String] = [:]
    ) async throws -> Data {
        if !credentials.hasFreshWebSession() {
            try await refreshSession()
        }
        do {
            return try await send(method, path, json: json, extraHeaders: extraHeaders)
        } catch AlexaError.sessionExpired {
            try await refreshSession()
            return try await send(method, path, json: json, extraHeaders: extraHeaders)
        }
    }

    /// Re-derives cookies + csrf from the refresh token.
    public func refreshSession() async throws {
        var updated = credentials
        try await auth.refreshWebSession(&updated)
        credentials = updated
        onCredentialsChange?(updated)
    }

    private func send(_ method: String, _ path: String, json: Any?, extraHeaders: [String: String]) async throws -> Data {
        let host = credentials.marketplace.alexaHost
        guard let url = URL(string: "https://\(host)\(path)") else {
            throw AlexaError.unexpectedResponse("bad path \(path)")
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue(AlexaAppIdentity.apiUserAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Accept")
        request.setValue(credentials.locale, forHTTPHeaderField: "Accept-Language")
        request.setValue("https://\(host)/spa/index.html", forHTTPHeaderField: "Referer")
        request.setValue("https://\(host)", forHTTPHeaderField: "Origin")
        request.setValue(HTTP.cookieHeader(credentials.cookies ?? [:]), forHTTPHeaderField: "Cookie")
        if let csrf = credentials.csrf { request.setValue(csrf, forHTTPHeaderField: "csrf") }
        for (key, value) in extraHeaders { request.setValue(value, forHTTPHeaderField: key) }
        if let json {
            request.httpBody = try HTTP.jsonBody(json)
            request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        }

        let (data, response) = try await transport.send(request)
        try HTTP.ensureSuccess(data, response)
        // An expired session sometimes comes back as a 200 HTML sign-in page instead of a 401.
        let contentType = response.value(forHTTPHeaderField: "Content-Type") ?? ""
        if contentType.contains("text/html") {
            throw AlexaError.sessionExpired
        }
        return data
    }

    // MARK: - Helpers (internal for tests)

    static func jsonString(_ object: Any) throws -> String {
        String(decoding: try HTTP.jsonBody(object), as: UTF8.self)
    }

    /// `operationPayload` comes back either as an object or as a JSON-encoded string.
    static func payloadDictionary(_ value: Any?) -> [String: Any]? {
        if let dict = value as? [String: Any] { return dict }
        if let string = value as? String, let data = string.data(using: .utf8) {
            return HTTP.jsonObject(data)
        }
        return nil
    }

    static func describeValidationFailure(_ json: [String: Any]) -> String? {
        for key in ["message", "failureMessage", "failureReason", "reason"] {
            if let value = json[key] as? String, !value.isEmpty { return value }
        }
        return nil
    }

    /// Rough local equivalent of Alexa's own phrase sanitising (lower-case, no punctuation).
    static func sanitize(_ phrase: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(.whitespaces)
        let scalars = phrase.lowercased().unicodeScalars.map { allowed.contains($0) ? Character($0) : " " }
        return String(scalars).split(separator: " ").joined(separator: " ")
    }
}
