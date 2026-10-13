import Foundation
import CryptoKit

/// One sign-in attempt: the URL to show the user plus the PKCE secret needed to finish it.
///
/// Flow (same as the official Alexa app, and the open-source projects that mimic it):
/// 1. Show `url` in a web view / browser. The user signs in on Amazon's own page (password + 2FA never touch us).
/// 2. Amazon redirects to `https://www.<domain>/ap/maplanding?...openid.oa2.authorization_code=...`.
///    Catch that URL (`isRedirect`) and pull the code out (`authorizationCode(from:)`).
/// 3. Hand the code to `AmazonAuth.register(...)`, which registers a virtual device and returns `AlexaCredentials`.
///
/// It's `Codable` so a CLI can persist it between "print URL" and "paste redirect URL".
public struct AmazonLoginRequest: Codable, Sendable, Equatable {
    /// Where the user signs in (`www.<domain>/ap/signin`) and the device gets registered (`api.<domain>`).
    public let region: AmazonRegion
    /// The Alexa marketplace the user expects (e.g. `amazon.de`). Used if Amazon doesn't tell us itself.
    public let marketplace: AmazonRegion?
    /// 32 upper-case hex chars. Becomes the serial of our virtual device.
    public let deviceSerial: String
    /// PKCE code verifier (base64url, 32 random bytes).
    public let codeVerifier: String
    /// Random "fraud reduction" cookie the Alexa app sends during sign-in.
    public let frc: String
    /// Base64 metadata cookie the Alexa app sends during sign-in.
    public let mapMd: String

    /// Signs in through `region` directly. Prefer `forMarketplace(_:)` unless you know you need this.
    public init(region: AmazonRegion, marketplace: AmazonRegion? = nil) {
        self.region = region
        self.marketplace = marketplace
        self.deviceSerial = Random.bytes(16).map { String(format: "%02X", $0) }.joined()
        self.codeVerifier = Random.bytes(32).base64URLEncoded
        self.frc = Data(Random.bytes(313)).base64EncodedString()
        let mapMdJSON = #"{"device_user_dictionary":[],"device_registration_data":{"software_version":"1"},"app_identifier":{"app_version":"\#(AlexaAppIdentity.appVersion)","bundle_id":"com.amazon.echo"}}"#
        self.mapMd = Data(mapMdJSON.utf8).base64EncodedString()
    }

    /// Sign-in for an account whose Alexa devices live in `marketplace`.
    ///
    /// Like the official app (and alexa-cookie2), everyone signs in through amazon.com — except Japan,
    /// which has its own identity domain. The real marketplace is then detected from the account.
    public static func forMarketplace(_ marketplace: AmazonRegion) -> AmazonLoginRequest {
        let signIn: AmazonRegion = marketplace == .japan ? .japan : .unitedStates
        return AmazonLoginRequest(region: signIn, marketplace: marketplace)
    }

    /// OAuth client id: hex(serial) + hex("#" + Alexa-app device type).
    public var clientId: String {
        Data((deviceSerial + "#" + AlexaAppIdentity.deviceType).utf8).hexString
    }

    public var codeChallenge: String {
        Data(SHA256.hash(data: Data(codeVerifier.utf8))).base64URLEncoded
    }

    /// Cookies to pre-seed in the sign-in web view (domain: `.<region.domain>`).
    public var signInCookies: [String: String] {
        ["frc": frc, "map-md": mapMd]
    }

    /// The Amazon sign-in page to open.
    public var url: URL {
        let domain = region.domain
        let handle = "amzn_dp_project_dee_ios\(region.assocHandleSuffix)"
        let params: KeyValuePairs<String, String> = [
            "openid.return_to": "https://www.\(domain)/ap/maplanding",
            "openid.assoc_handle": handle,
            "openid.identity": "http://specs.openid.net/auth/2.0/identifier_select",
            "pageId": handle,
            "accountStatusPolicy": "P1",
            "openid.claimed_id": "http://specs.openid.net/auth/2.0/identifier_select",
            "openid.mode": "checkid_setup",
            "openid.ns.oa2": "http://www.\(domain)/ap/ext/oauth/2",
            "openid.oa2.client_id": "device:\(clientId)",
            "openid.ns.pape": "http://specs.openid.net/extensions/pape/1.0",
            "openid.oa2.response_type": "code",
            "openid.ns": "http://specs.openid.net/auth/2.0",
            "openid.pape.max_auth_age": "0",
            "openid.oa2.scope": "device_auth_access",
            "openid.oa2.code_challenge_method": "S256",
            "openid.oa2.code_challenge": codeChallenge,
            "language": region.signInLanguage,
        ]
        var components = URLComponents()
        components.scheme = "https"
        components.host = region.wwwHost
        components.path = "/ap/signin"
        components.percentEncodedQuery = params.map { "\(HTTP.escape($0.key))=\(HTTP.escape($0.value))" }
            .joined(separator: "&")
        return components.url!
    }

    /// True when `url` is the post-sign-in redirect that carries the authorization code.
    public static func isRedirect(_ url: URL) -> Bool {
        url.path.hasSuffix("/ap/maplanding") && authorizationCode(from: url) != nil
    }

    /// Extracts `openid.oa2.authorization_code` from the redirect URL (or from a pasted string containing it).
    public static func authorizationCode(from url: URL) -> String? {
        URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?
            .first { $0.name == "openid.oa2.authorization_code" }?
            .value
            .flatMap { $0.isEmpty ? nil : $0 }
    }
}

/// Talks to Amazon's identity endpoints: device registration, refresh-token -> cookies, sign-out.
public struct AmazonAuth: Sendable {
    /// Shown in the user's Amazon account under "Your devices" as "<First name>'s <appName>".
    public var appName: String
    let transport: HTTPTransport

    public init(appName: String = "Send to Alexa", transport: HTTPTransport = URLSessionTransport()) {
        self.appName = appName
        self.transport = transport
    }

    // MARK: Register

    /// Completes sign-in: registers a virtual device, figures out the account's marketplace,
    /// and fetches a first Alexa web session.
    ///
    /// - Parameters:
    ///   - websiteCookies: cookies collected by the sign-in web view (optional, improves success rate).
    public func register(
        _ login: AmazonLoginRequest,
        authorizationCode: String,
        websiteCookies: [String: String] = [:]
    ) async throws -> AlexaCredentials {
        let region = login.region
        var cookies = websiteCookies
        cookies["frc"] = cookies["frc"] ?? login.frc
        cookies["map-md"] = cookies["map-md"] ?? login.mapMd

        let body: [String: Any] = [
            "requested_extensions": ["device_info", "customer_info"],
            "cookies": [
                "website_cookies": cookies.map { ["Name": $0.key, "Value": $0.value] },
                "domain": ".\(region.domain)",
            ],
            "registration_data": [
                "domain": "Device",
                "app_version": AlexaAppIdentity.appVersion,
                "device_type": AlexaAppIdentity.deviceType,
                "device_name": "%FIRST_NAME%\u{0027}s%DUPE_STRATEGY_1ST%\(appName)",
                "os_version": AlexaAppIdentity.osVersion,
                "device_serial": login.deviceSerial,
                "device_model": "iPhone",
                "app_name": appName,
                "software_version": "1",
            ],
            "auth_data": [
                "client_id": login.clientId,
                "authorization_code": authorizationCode,
                "code_verifier": login.codeVerifier,
                "code_algorithm": "SHA-256",
                "client_domain": "DeviceLegacy",
            ],
            "user_context_map": ["frc": cookies["frc"] ?? login.frc],
            "requested_token_type": ["bearer", "mac_dms", "website_cookies"],
        ]

        var request = URLRequest(url: URL(string: "https://\(region.apiHost)/auth/register")!)
        request.httpMethod = "POST"
        request.httpBody = try HTTP.jsonBody(body)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(AlexaAppIdentity.authUserAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(region.locale, forHTTPHeaderField: "Accept-Language")
        request.setValue(region.apiHost, forHTTPHeaderField: "x-amzn-identity-auth-domain")
        request.setValue(HTTP.cookieHeader(cookies), forHTTPHeaderField: "Cookie")

        let (data, response) = try await transport.send(request)
        let json = HTTP.jsonObject(data)
        let success = (json?["response"] as? [String: Any])?["success"] as? [String: Any]
        guard
            (200..<300).contains(response.statusCode),
            let tokens = success?["tokens"] as? [String: Any],
            let bearer = tokens["bearer"] as? [String: Any],
            let refreshToken = bearer["refresh_token"] as? String
        else {
            let error = (json?["response"] as? [String: Any])?["error"] as? [String: Any]
            var message = (error?["message"] as? String) ?? (error?["code"] as? String)
                ?? "HTTP \(response.statusCode) \(String(decoding: data.prefix(300), as: UTF8.self))"
            if error?["code"] as? String == "InvalidValue" {
                // Most common cause: the authorization code is single-use and expires after ~5 minutes.
                message += " (the sign-in code may have expired — codes are valid for a few minutes; sign in again)"
            }
            throw AlexaError.signInFailed(message)
        }
        let extensions = success?["extensions"] as? [String: Any]
        let customer = extensions?["customer_info"] as? [String: Any]
        let firstName = (customer?["given_name"] as? String) ?? (customer?["name"] as? String)

        // Work out the account's Alexa marketplace (a German account signs in via amazon.com, etc.).
        // Amazon's own answer wins; the caller's hint is the fallback.
        let hint = login.marketplace ?? region
        var marketplace = hint.domain
        var locale = hint.locale
        let loginCookies = try? await exchangeRefreshTokenForCookies(
            refreshToken: refreshToken, domain: region.domain, loginRegion: region
        )
        if let loginCookies, let me = try? await userProfile(host: region.alexaHost, cookies: loginCookies) {
            if let detected = me.marketplaceDomain {
                marketplace = detected
                locale = me.locale ?? AmazonRegion.forDomain(detected).locale
            } else if let detectedLocale = me.locale {
                locale = detectedLocale
            }
        }

        var credentials = AlexaCredentials(
            loginDomain: region.domain,
            marketplaceDomain: marketplace,
            locale: locale,
            deviceSerial: login.deviceSerial,
            refreshToken: refreshToken,
            customerName: firstName
        )
        if marketplace == region.domain, var cookies = loginCookies {
            // Same domain: reuse the cookies we already have.
            credentials.csrf = try await fetchCSRF(marketplace: region, cookies: &cookies)
            credentials.cookies = cookies
            credentials.cookiesFetchedAt = Date()
        } else {
            try await refreshWebSession(&credentials)
        }
        return credentials
    }

    // MARK: Web session (cookies + csrf)

    /// Swaps the refresh token for fresh `alexa.<marketplace>` cookies and a CSRF token, in place.
    public func refreshWebSession(_ credentials: inout AlexaCredentials, now: Date = Date()) async throws {
        let marketplace = credentials.marketplace
        var cookies = try await exchangeRefreshTokenForCookies(
            refreshToken: credentials.refreshToken,
            domain: marketplace.domain,
            loginRegion: credentials.loginRegion
        )
        let csrf = try await fetchCSRF(marketplace: marketplace, cookies: &cookies)
        credentials.cookies = cookies
        credentials.csrf = csrf
        credentials.cookiesFetchedAt = now
    }

    func exchangeRefreshTokenForCookies(
        refreshToken: String,
        domain: String,
        loginRegion: AmazonRegion
    ) async throws -> [String: String] {
        var request = URLRequest(url: URL(string: "https://www.\(domain)/ap/exchangetoken/cookies")!)
        request.httpMethod = "POST"
        request.httpBody = HTTP.formBody([
            "di.os.name": "iOS",
            "app_version": AlexaAppIdentity.appVersion,
            "domain": ".\(domain)",
            "source_token": refreshToken,
            "requested_token_type": "auth_cookies",
            "source_token_type": "refresh_token",
            "di.hw.version": "iPhone",
            "di.sdk.version": AlexaAppIdentity.sdkVersion,
            "app_name": appName,
            "di.os.version": AlexaAppIdentity.osVersion,
        ])
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("*/*", forHTTPHeaderField: "Accept")
        request.setValue(AlexaAppIdentity.authUserAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(loginRegion.locale, forHTTPHeaderField: "Accept-Language")
        request.setValue("api.\(domain)", forHTTPHeaderField: "x-amzn-identity-auth-domain")

        let (data, response) = try await transport.send(request)
        if response.statusCode == 400 || response.statusCode == 401 || response.statusCode == 403 {
            // Typically "InvalidToken": the device was deregistered or the token revoked.
            throw AlexaError.sessionExpired
        }
        try HTTP.ensureSuccess(data, response)

        guard
            let json = HTTP.jsonObject(data),
            let tokens = (json["response"] as? [String: Any])?["tokens"] as? [String: Any],
            let byDomain = tokens["cookies"] as? [String: Any]
        else {
            throw AlexaError.unexpectedResponse("no cookies in token exchange response")
        }
        let list = (byDomain[".\(domain)"] ?? byDomain.first { $0.key.hasSuffix(domain) }?.value) as? [[String: Any]]
        guard let list, !list.isEmpty else {
            throw AlexaError.unexpectedResponse("no cookies for .\(domain) in token exchange response")
        }
        var cookies = HTTP.setCookies(from: response)
        for cookie in list {
            if let name = cookie["Name"] as? String, let value = cookie["Value"] as? String {
                cookies[name] = value.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            }
        }
        return cookies
    }

    /// The Alexa web API wants a `csrf` header that matches a `csrf` cookie it hands out on certain pages.
    func fetchCSRF(marketplace: AmazonRegion, cookies: inout [String: String]) async throws -> String {
        if let csrf = cookies["csrf"] { return csrf }
        let paths = [
            "/api/language",
            "/spa/index.html",
            "/api/devices-v2/device?cached=false",
            "/templates/oobe/d-device-pick.handlebars",
            "/api/strings",
        ]
        for path in paths {
            var request = URLRequest(url: URL(string: "https://\(marketplace.alexaHost)\(path)")!)
            request.setValue(HTTP.cookieHeader(cookies), forHTTPHeaderField: "Cookie")
            request.setValue(AlexaAppIdentity.apiUserAgent, forHTTPHeaderField: "User-Agent")
            request.setValue("https://\(marketplace.alexaHost)/spa/index.html", forHTTPHeaderField: "Referer")
            request.setValue("https://\(marketplace.alexaHost)", forHTTPHeaderField: "Origin")
            request.setValue("*/*", forHTTPHeaderField: "Accept")
            guard let (_, response) = try? await transport.send(request) else { continue }
            cookies.merge(HTTP.setCookies(from: response)) { _, new in new }
            if let csrf = cookies["csrf"] { return csrf }
        }
        throw AlexaError.unexpectedResponse("Alexa did not hand out a CSRF token for \(marketplace.alexaHost)")
    }

    // MARK: Profile

    struct UserProfile {
        var marketplaceDomain: String?
        var locale: String?
    }

    func userProfile(host: String, cookies: [String: String]) async throws -> UserProfile {
        var request = URLRequest(url: URL(string: "https://\(host)/api/users/me?platform=ios&version=\(AlexaAppIdentity.appVersion)")!)
        request.setValue(HTTP.cookieHeader(cookies), forHTTPHeaderField: "Cookie")
        request.setValue(AlexaAppIdentity.apiUserAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await transport.send(request)
        try HTTP.ensureSuccess(data, response)
        guard let json = HTTP.jsonObject(data) else {
            throw AlexaError.unexpectedResponse("users/me did not return JSON")
        }
        // e.g. "marketPlaceDomainName": "www.amazon.de", "marketPlaceLocale": "de-DE"
        let marketplace = (json["marketPlaceDomainName"] as? String).map { AmazonRegion.forDomain($0).domain }
        return UserProfile(marketplaceDomain: marketplace, locale: json["marketPlaceLocale"] as? String)
    }

    // MARK: Sign out

    /// Best-effort removal of our virtual device from the user's Amazon account.
    /// Only *this* registration is removed (`deregister_all_existing_accounts: false`).
    public func deregister(_ credentials: AlexaCredentials) async throws {
        let api = credentials.loginRegion.apiHost
        let accessToken = try await accessToken(for: credentials)
        var request = URLRequest(url: URL(string: "https://\(api)/auth/deregister")!)
        request.httpMethod = "POST"
        request.httpBody = try HTTP.jsonBody(["deregister_all_existing_accounts": false])
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue(AlexaAppIdentity.authUserAgent, forHTTPHeaderField: "User-Agent")
        let (data, response) = try await transport.send(request)
        try HTTP.ensureSuccess(data, response)
    }

    func accessToken(for credentials: AlexaCredentials) async throws -> String {
        let api = credentials.loginRegion.apiHost
        var request = URLRequest(url: URL(string: "https://\(api)/auth/token")!)
        request.httpMethod = "POST"
        request.httpBody = HTTP.formBody([
            "app_name": appName,
            "app_version": AlexaAppIdentity.appVersion,
            "di.sdk.version": AlexaAppIdentity.sdkVersion,
            "source_token": credentials.refreshToken,
            "package_name": "com.amazon.echo",
            "di.hw.version": "iPhone",
            "platform": "iOS",
            "requested_token_type": "access_token",
            "source_token_type": "refresh_token",
            "di.os.name": "iOS",
            "di.os.version": AlexaAppIdentity.osVersion,
            "current_version": AlexaAppIdentity.sdkVersion,
        ])
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(AlexaAppIdentity.authUserAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(api, forHTTPHeaderField: "x-amzn-identity-auth-domain")
        let (data, response) = try await transport.send(request)
        try HTTP.ensureSuccess(data, response)
        guard let token = HTTP.jsonObject(data)?["access_token"] as? String else {
            throw AlexaError.unexpectedResponse("no access_token in token response")
        }
        return token
    }
}

// MARK: - Utilities

enum Random {
    static func bytes(_ count: Int) -> [UInt8] {
        var generator = SystemRandomNumberGenerator()
        return (0..<count).map { _ in UInt8.random(in: .min ... .max, using: &generator) }
    }
}

extension Data {
    var hexString: String { map { String(format: "%02x", $0) }.joined() }

    var base64URLEncoded: String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

extension Array where Element == UInt8 {
    var base64URLEncoded: String { Data(self).base64URLEncoded }
}
