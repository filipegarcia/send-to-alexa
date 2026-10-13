import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// The minimal networking surface AlexaKit needs. Swap it out in tests (see `MockTransport` in the test target).
public protocol HTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

/// Default transport backed by an ephemeral `URLSession` that **does not** manage cookies on its own:
/// AlexaKit keeps the Amazon cookie jar itself so it can persist it next to the refresh token.
public struct URLSessionTransport: HTTPTransport {
    public let session: URLSession

    public init(session: URLSession = URLSessionTransport.makeSession()) {
        self.session = session
    }

    public static func makeSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.httpCookieAcceptPolicy = .never
        config.timeoutIntervalForRequest = 20
        config.urlCache = nil
        return URLSession(configuration: config)
    }

    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw AlexaError.unexpectedResponse("Not an HTTP response from \(request.url?.host ?? "?")")
        }
        return (data, http)
    }
}

/// Errors surfaced by AlexaKit. Messages are meant to be shown to users as-is.
public enum AlexaError: LocalizedError, Equatable, Sendable {
    case notSignedIn
    case signInFailed(String)
    case sessionExpired
    case http(status: Int, host: String, body: String)
    case unexpectedResponse(String)
    case deviceNotFound(String)
    case invalidSearch(String)
    case unsupportedLink(String)

    public var errorDescription: String? {
        switch self {
        case .notSignedIn:
            return "Not signed in to Amazon. Open the app and sign in first."
        case .signInFailed(let reason):
            return "Amazon sign-in failed: \(reason)"
        case .sessionExpired:
            return "Your Amazon session expired. Please sign in again."
        case .http(let status, let host, let body):
            let snippet = body.prefix(300)
            return "Amazon returned HTTP \(status) from \(host)\(snippet.isEmpty ? "" : ": \(snippet)")"
        case .unexpectedResponse(let detail):
            return "Unexpected response from Amazon: \(detail)"
        case .deviceNotFound(let name):
            return "No Echo device named \"\(name)\" was found."
        case .invalidSearch(let detail):
            return "Alexa couldn't use that search: \(detail)"
        case .unsupportedLink(let link):
            return "Couldn't figure out what to play from \(link)"
        }
    }
}

// MARK: - Small helpers

enum HTTP {
    /// `application/x-www-form-urlencoded` body with strict RFC 3986 escaping.
    static func formBody(_ pairs: KeyValuePairs<String, String>) -> Data {
        pairs.map { "\(escape($0.key))=\(escape($0.value))" }
            .joined(separator: "&")
            .data(using: .utf8)!
    }

    /// Percent-escapes everything except RFC 3986 unreserved characters.
    static func escape(_ string: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return string.addingPercentEncoding(withAllowedCharacters: allowed) ?? string
    }

    static func jsonBody(_ object: Any) throws -> Data {
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    static func jsonObject(_ data: Data) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    /// Cookies set by a response (handles multiple `Set-Cookie` headers correctly).
    static func setCookies(from response: HTTPURLResponse) -> [String: String] {
        guard let url = response.url else { return [:] }
        var headers: [String: String] = [:]
        for (key, value) in response.allHeaderFields {
            if let key = key as? String, let value = value as? String { headers[key] = value }
        }
        var result: [String: String] = [:]
        for cookie in HTTPCookie.cookies(withResponseHeaderFields: headers, for: url) {
            result[cookie.name] = cookie.value
        }
        return result
    }

    static func cookieHeader(_ cookies: [String: String]) -> String {
        cookies.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: "; ")
    }

    static func ensureSuccess(_ data: Data, _ response: HTTPURLResponse) throws {
        guard (200..<300).contains(response.statusCode) else {
            if response.statusCode == 401 || response.statusCode == 403 {
                throw AlexaError.sessionExpired
            }
            throw AlexaError.http(
                status: response.statusCode,
                host: response.url?.host ?? "?",
                body: String(decoding: data, as: UTF8.self)
            )
        }
    }
}

/// Identifiers that make our requests look like the official Alexa iOS app.
/// These are the same values used by the long-running open-source projects
/// (alexa-remote-control, alexa-cookie2, alexa_media_player). Bump them here if Amazon starts rejecting them.
enum AlexaAppIdentity {
    static let appVersion = "2.2.651540.0"
    static let sdkVersion = "6.12.4"
    static let osVersion = "18.3.1"
    /// Device type of the Alexa iOS app. Our registered "device" pretends to be another phone running it.
    static let deviceType = "A2IVLV5VM2W81"
    static let authUserAgent = "AmazonWebView/Amazon Alexa/\(appVersion)/iOS/\(osVersion)/iPhone"
    static let apiUserAgent = "AppleWebKit PitanguiBridge/2.2.595606.0-[HARDWARE=iPhone14_7][SOFTWARE=17.4.1][DEVICE=iPhone]"
}
