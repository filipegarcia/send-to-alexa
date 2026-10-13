import Foundation
import Testing
@testable import AlexaKit

@Suite("Amazon device registration & web session")
struct AuthTests {
    /// A fake Amazon that registers, exchanges cookies, hands out csrf and reports a UK marketplace.
    static func fakeAmazon(marketplace: String = "www.amazon.co.uk") -> MockTransport {
        MockTransport { request in
            let url = request.url!
            switch (url.host!, url.path) {
            case ("api.amazon.com", "/auth/register"):
                return .json(["response": ["success": [
                    "tokens": [
                        "bearer": ["access_token": "Atna|access", "refresh_token": "Atnr|refresh", "expires_in": "3600"],
                        "mac_dms": ["device_private_key": "x"],
                    ],
                    "extensions": ["customer_info": ["given_name": "Ada", "name": "Ada Lovelace"]],
                ]]])
            case (let host, "/ap/exchangetoken/cookies"):
                let domain = String(host.dropFirst("www.".count))
                return .json(["response": ["tokens": ["cookies": [
                    ".\(domain)": [
                        ["Name": "session-id", "Value": "sid-\(domain)"],
                        ["Name": "at-main", "Value": "\"Atza|quoted\""],
                    ],
                ]]]])
            case (_, "/api/language"):
                return .text("{}", headers: ["Set-Cookie": "csrf=csrf-\(url.host!); Path=/; Secure"])
            case (_, "/api/users/me"):
                return .json(["marketPlaceDomainName": marketplace, "marketPlaceLocale": "en-GB"])
            default:
                return .text("not found", status: 404)
            }
        }
    }

    @Test func registersDeviceAndMovesToAccountMarketplace() async throws {
        let transport = Self.fakeAmazon()
        let auth = AmazonAuth(appName: "Test App", transport: transport)
        let login = AmazonLoginRequest(region: .unitedStates)

        let creds = try await auth.register(login, authorizationCode: "CODE", websiteCookies: ["session-id": "s1"])

        #expect(creds.refreshToken == "Atnr|refresh")
        #expect(creds.loginDomain == "amazon.com")
        #expect(creds.marketplaceDomain == "amazon.co.uk")
        #expect(creds.locale == "en-GB")
        #expect(creds.customerName == "Ada")
        #expect(creds.deviceSerial == login.deviceSerial)
        #expect(creds.cookies?["session-id"] == "sid-amazon.co.uk")
        #expect(creds.cookies?["at-main"] == "Atza|quoted", "surrounding quotes are stripped")
        #expect(creds.csrf == "csrf-alexa.amazon.co.uk")
        #expect(creds.hasFreshWebSession())

        let register = try #require(transport.requests.first)
        let body = try #require(register.jsonBody)
        let authData = try #require(body["auth_data"] as? [String: Any])
        let registration = try #require(body["registration_data"] as? [String: Any])
        #expect(authData["authorization_code"] as? String == "CODE")
        #expect(authData["code_verifier"] as? String == login.codeVerifier)
        #expect(authData["client_id"] as? String == login.clientId)
        #expect(registration["device_serial"] as? String == login.deviceSerial)
        #expect(registration["device_type"] as? String == "A2IVLV5VM2W81")
        #expect(registration["app_name"] as? String == "Test App")
        #expect((body["user_context_map"] as? [String: String])?["frc"] == login.frc)
        #expect(register.value(forHTTPHeaderField: "x-amzn-identity-auth-domain") == "api.amazon.com")

        // Cookie exchange carries the refresh token, and happens for both domains.
        let exchanges = transport.requests.filter { $0.url?.path == "/ap/exchangetoken/cookies" }
        #expect(exchanges.map { $0.url!.host! } == ["www.amazon.com", "www.amazon.co.uk"])
        #expect(exchanges.first?.formBody["source_token"] == "Atnr|refresh")
        #expect(exchanges.first?.formBody["requested_token_type"] == "auth_cookies")
    }

    @Test func staysOnLoginMarketplaceWhenProfileMatches() async throws {
        let transport = Self.fakeAmazon(marketplace: "www.amazon.com")
        let creds = try await AmazonAuth(transport: transport)
            .register(AmazonLoginRequest(region: .unitedStates), authorizationCode: "CODE")
        #expect(creds.marketplaceDomain == "amazon.com")
        #expect(transport.requests.filter { $0.url?.path == "/ap/exchangetoken/cookies" }.count == 1)
    }

    @Test func fallsBackToMarketplaceHintWhenProfileUnavailable() async throws {
        let amazon = Self.fakeAmazon()
        let wrapped = MockTransport { request in
            if request.url?.path == "/api/users/me" { return .text("nope", status: 500) }
            return amazonReply(amazon, request)
        }
        let login = AmazonLoginRequest.forMarketplace(.germany)
        #expect(login.region == .unitedStates, "sign-in goes through amazon.com")
        let creds = try await AmazonAuth(transport: wrapped).register(login, authorizationCode: "CODE")
        #expect(creds.loginDomain == "amazon.com")
        #expect(creds.marketplaceDomain == "amazon.de")
        #expect(creds.locale == "de-DE")
        #expect(creds.csrf == "csrf-alexa.amazon.de")
    }

    @Test func surfacesRegistrationErrors() async {
        let transport = MockTransport { _ in
            .json(["response": ["error": ["code": "Unauthorized", "message": "Account is locked"]]], status: 400)
        }
        await #expect(throws: AlexaError.signInFailed("Account is locked")) {
            try await AmazonAuth(transport: transport).register(AmazonLoginRequest(region: .unitedStates), authorizationCode: "bad")
        }
    }

    @Test func explainsExpiredAuthorizationCodes() async throws {
        let transport = MockTransport { _ in
            .json(["response": ["error": ["code": "InvalidValue", "message": "One or more provided values are invalid."]]], status: 400)
        }
        let error = await #expect(throws: AlexaError.self) {
            try await AmazonAuth(transport: transport).register(AmazonLoginRequest(region: .unitedStates), authorizationCode: "old")
        }
        #expect(error?.localizedDescription.contains("expired") == true)
    }

    @Test func revokedRefreshTokenMeansSessionExpired() async {
        let transport = MockTransport { _ in .json(["response": ["error": ["code": "InvalidToken"]]], status: 400) }
        var creds = AlexaCredentials.fixture(fresh: false)
        await #expect(throws: AlexaError.sessionExpired) {
            try await AmazonAuth(transport: transport).refreshWebSession(&creds)
        }
    }

    @Test func deregisterOnlyRemovesThisDevice() async throws {
        let transport = MockTransport { request in
            switch request.url!.path {
            case "/auth/token": return .json(["access_token": "Atna|abc", "expires_in": 3600])
            case "/auth/deregister": return .json(["response": ["success": [:]]])
            default: return .text("", status: 404)
            }
        }
        try await AmazonAuth(transport: transport).deregister(.fixture())
        let deregister = try #require(transport.requests.last)
        #expect(deregister.url?.host == "api.amazon.com")
        #expect(deregister.value(forHTTPHeaderField: "Authorization") == "Bearer Atna|abc")
        #expect(deregister.jsonBody?["deregister_all_existing_accounts"] as? Bool == false)
    }
}

/// Forwards a request to another mock and returns its reply (helper for wrapping fakes).
private func amazonReply(_ mock: MockTransport, _ request: URLRequest) -> MockTransport.Reply {
    mock.reply(for: request)
}
