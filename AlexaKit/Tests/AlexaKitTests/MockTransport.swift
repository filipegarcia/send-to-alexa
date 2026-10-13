import Foundation
@testable import AlexaKit

/// Records requests and answers them from a routing closure. No network access.
final class MockTransport: HTTPTransport, @unchecked Sendable {
    struct Reply {
        var status: Int = 200
        var headers: [String: String] = ["Content-Type": "application/json"]
        var body: Data = Data()

        static func json(_ object: Any, status: Int = 200, headers: [String: String] = [:]) -> Reply {
            var h = ["Content-Type": "application/json"]
            h.merge(headers) { _, new in new }
            return Reply(status: status, headers: h, body: try! JSONSerialization.data(withJSONObject: object))
        }

        static func text(_ string: String, status: Int = 200, contentType: String = "text/plain", headers: [String: String] = [:]) -> Reply {
            var h = ["Content-Type": contentType]
            h.merge(headers) { _, new in new }
            return Reply(status: status, headers: h, body: Data(string.utf8))
        }
    }

    private let lock = NSLock()
    private var _requests: [URLRequest] = []
    private let route: @Sendable (URLRequest) -> Reply

    init(route: @escaping @Sendable (URLRequest) -> Reply) {
        self.route = route
    }

    var requests: [URLRequest] { lock.withLock { _requests } }

    /// The canned reply for `request`, without recording it.
    func reply(for request: URLRequest) -> Reply { route(request) }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        lock.withLock { _requests.append(request) }
        let reply = route(request)
        let response = HTTPURLResponse(url: request.url!, statusCode: reply.status, httpVersion: "HTTP/1.1", headerFields: reply.headers)!
        return (reply.body, response)
    }
}

extension URLRequest {
    var jsonBody: [String: Any]? {
        httpBody.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
    }

    var formBody: [String: String] {
        guard let body = httpBody, let string = String(data: body, encoding: .utf8) else { return [:] }
        var result: [String: String] = [:]
        for pair in string.split(separator: "&") {
            let parts = pair.split(separator: "=", maxSplits: 1).map { String($0).removingPercentEncoding ?? String($0) }
            if parts.count == 2 { result[parts[0]] = parts[1] }
        }
        return result
    }
}

extension AlexaCredentials {
    static func fixture(fresh: Bool = true) -> AlexaCredentials {
        AlexaCredentials(
            loginDomain: "amazon.com",
            marketplaceDomain: "amazon.co.uk",
            locale: "en-GB",
            deviceSerial: "ABCDEF0123456789ABCDEF0123456789",
            refreshToken: "Atnr|test-refresh-token",
            customerName: "Test",
            cookies: fresh ? ["session-id": "123", "csrf": "999"] : nil,
            csrf: fresh ? "999" : nil,
            cookiesFetchedAt: fresh ? Date() : nil
        )
    }
}

extension EchoDevice {
    static let kitchen = EchoDevice(
        accountName: "Kitchen",
        serialNumber: "G0911W0000000001",
        deviceType: "A3S5BH2HU6VAYF",
        deviceFamily: "ECHO",
        deviceOwnerCustomerId: "A1CUSTOMER",
        online: true,
        capabilities: ["AUDIO_PLAYER", "VOLUME_SETTING"]
    )
}
