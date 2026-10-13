import CryptoKit
import Foundation
import Testing
@testable import AlexaKit

@Suite("Amazon sign-in request")
struct LoginTests {
    @Test func clientIdIsHexOfSerialAndAlexaDeviceType() {
        let login = AmazonLoginRequest(region: .unitedStates)
        #expect(login.deviceSerial.count == 32)
        #expect(login.deviceSerial == login.deviceSerial.uppercased())
        // hex("#A2IVLV5VM2W81")
        #expect(login.clientId.hasSuffix("23413249564c5635564d32573831"))
        #expect(login.clientId.count == (32 + 14) * 2)
    }

    @Test func codeChallengeIsS256OfVerifier() {
        let login = AmazonLoginRequest(region: .unitedStates)
        let expected = Data(SHA256.hash(data: Data(login.codeVerifier.utf8))).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        #expect(login.codeChallenge == expected)
        #expect(!login.codeVerifier.contains("="))
    }

    @Test func randomValuesDifferPerAttempt() {
        let a = AmazonLoginRequest(region: .unitedStates)
        let b = AmazonLoginRequest(region: .unitedStates)
        #expect(a.deviceSerial != b.deviceSerial)
        #expect(a.codeVerifier != b.codeVerifier)
        #expect(a.frc != b.frc)
    }

    @Test(arguments: [
        (AmazonRegion.unitedStates, "amzn_dp_project_dee_ios", "www.amazon.com", "en_US"),
        (AmazonRegion.unitedKingdom, "amzn_dp_project_dee_ios_uk", "www.amazon.co.uk", "en_GB"),
        (AmazonRegion.germany, "amzn_dp_project_dee_ios_de", "www.amazon.de", "de_DE"),
        (AmazonRegion.japan, "amzn_dp_project_dee_ios_jp", "www.amazon.co.jp", "ja_JP"),
    ])
    func signInURL(region: AmazonRegion, handle: String, host: String, language: String) throws {
        let login = AmazonLoginRequest(region: region)
        let components = try #require(URLComponents(url: login.url, resolvingAgainstBaseURL: false))
        let query = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        #expect(components.host == host)
        #expect(components.path == "/ap/signin")
        #expect(query["openid.assoc_handle"] == handle)
        #expect(query["pageId"] == handle)
        #expect(query["openid.return_to"] == "https://\(host)/ap/maplanding")
        #expect(query["openid.oa2.client_id"] == "device:\(login.clientId)")
        #expect(query["openid.oa2.code_challenge"] == login.codeChallenge)
        #expect(query["openid.oa2.code_challenge_method"] == "S256")
        #expect(query["openid.oa2.scope"] == "device_auth_access")
        #expect(query["language"] == language)
        // Everything reserved is percent-encoded, like the official app does.
        #expect(login.url.absoluteString.contains("openid.return_to=https%3A%2F%2F"))
    }

    @Test func extractsAuthorizationCodeFromRedirect() throws {
        let url = try #require(URL(string: "https://www.amazon.com/ap/maplanding?openid.assoc_handle=x&openid.oa2.authorization_code=ANcode123&openid.mode=id_res"))
        #expect(AmazonLoginRequest.isRedirect(url))
        #expect(AmazonLoginRequest.authorizationCode(from: url) == "ANcode123")
    }

    @Test func ignoresOtherPages() throws {
        let signin = try #require(URL(string: "https://www.amazon.com/ap/signin?openid.mode=checkid_setup"))
        let landingWithoutCode = try #require(URL(string: "https://www.amazon.com/ap/maplanding?openid.mode=cancel"))
        #expect(!AmazonLoginRequest.isRedirect(signin))
        #expect(!AmazonLoginRequest.isRedirect(landingWithoutCode))
    }

    @Test func roundTripsThroughCodable() throws {
        let login = AmazonLoginRequest(region: .unitedKingdom)
        let decoded = try JSONDecoder().decode(AmazonLoginRequest.self, from: JSONEncoder().encode(login))
        #expect(decoded == login)
        #expect(decoded.url == login.url)
    }

    @Test func marketplaceSignInGoesThroughAmazonComExceptJapan() {
        #expect(AmazonLoginRequest.forMarketplace(.germany).region == .unitedStates)
        #expect(AmazonLoginRequest.forMarketplace(.germany).marketplace == .germany)
        #expect(AmazonLoginRequest.forMarketplace(.unitedKingdom).region == .unitedStates)
        #expect(AmazonLoginRequest.forMarketplace(.japan).region == .japan)
    }

    @Test func regionLookupNormalisesInput() {
        #expect(AmazonRegion.forDomain("https://www.amazon.co.uk/") == .unitedKingdom)
        #expect(AmazonRegion.forDomain("alexa.amazon.de") == .germany)
        #expect(AmazonRegion.forDomain("AMAZON.COM") == .unitedStates)
        #expect(AmazonRegion.forDomain("amazon.nl").locale == "en-US")
    }
}
