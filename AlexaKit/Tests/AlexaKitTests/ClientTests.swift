import Foundation
import Testing
@testable import AlexaKit

@Suite("Alexa client")
struct ClientTests {
    static var devicesJSON: [String: Any] { ["devices": [
        ["accountName": "Kitchen", "serialNumber": "S1", "deviceType": "T1", "deviceFamily": "ECHO",
         "deviceOwnerCustomerId": "C1", "online": true, "capabilities": ["AUDIO_PLAYER"], "extra": 1],
        ["accountName": "Bedroom", "serialNumber": "S2", "deviceType": "T2", "deviceFamily": "KNIGHT",
         "deviceOwnerCustomerId": "C1", "online": false, "capabilities": ["AUDIO_PLAYER"]],
        ["accountName": "Everywhere", "serialNumber": "S3", "deviceType": "T3", "deviceFamily": "WHA",
         "deviceOwnerCustomerId": "C1", "online": true, "capabilities": []],
        ["accountName": "Ada's Alexa app", "serialNumber": "S4", "deviceType": "A2IVLV5VM2W81", "deviceFamily": "VOX",
         "deviceOwnerCustomerId": "C1", "online": true, "capabilities": ["AUDIO_PLAYER"]],
        ["accountName": "Smart Plug", "serialNumber": "S5", "deviceType": "T5", "deviceFamily": "SMARTHOME",
         "deviceOwnerCustomerId": "C1", "online": true],
    ]] }

    @Test func listsMusicCapableDevicesOnlineFirst() async throws {
        let transport = MockTransport { _ in .json(Self.devicesJSON) }
        let client = AlexaClient(credentials: .fixture(), transport: transport)
        let devices = try await client.musicDevices()
        #expect(devices.map(\.accountName) == ["Everywhere", "Kitchen", "Bedroom"])
        #expect(devices.first?.isSpeakerGroup == true)

        let request = try #require(transport.requests.first)
        #expect(request.url?.host == "alexa.amazon.co.uk")
        #expect(request.value(forHTTPHeaderField: "csrf") == "999")
        #expect(request.value(forHTTPHeaderField: "Cookie")?.contains("session-id=123") == true)
    }

    @Test func playValidatesThenRunsPreviewSequence() async throws {
        let transport = MockTransport { request in
            switch request.url!.path {
            case "/api/behaviors/operation/validate":
                return .json(["result": "VALID", "operationPayload": [
                    "deviceType": "A3S5BH2HU6VAYF", "deviceSerialNumber": "G0911W0000000001",
                    "customerId": "A1CUSTOMER", "locale": "en-GB", "musicProviderId": "APPLE_MUSIC",
                    "searchPhrase": "Better Together by Jack Johnson",
                    "sanitizedSearchPhrase": "better together by jack johnson",
                ]])
            case "/api/behaviors/preview":
                return .text("", contentType: "application/json")
            default:
                return .text("", status: 404)
            }
        }
        let client = AlexaClient(credentials: .fixture(), transport: transport)
        let sanitized = try await client.play("Better Together by Jack Johnson", provider: .appleMusic, on: .kitchen)
        #expect(sanitized == "better together by jack johnson")

        let validate = try #require(transport.requests.first)
        let validateBody = try #require(validate.jsonBody)
        #expect(validateBody["type"] as? String == "Alexa.Music.PlaySearchPhrase")
        let validatePayload = try #require(AlexaClient.payloadDictionary(validateBody["operationPayload"]))
        #expect(validatePayload["musicProviderId"] as? String == "APPLE_MUSIC")
        #expect(validatePayload["deviceSerialNumber"] as? String == "G0911W0000000001")

        let preview = try #require(transport.requests.last)
        #expect(preview.url?.path == "/api/behaviors/preview")
        let body = try #require(preview.jsonBody)
        #expect(body["behaviorId"] as? String == "PREVIEW")
        #expect(body["status"] as? String == "ENABLED")
        let sequence = try #require(AlexaClient.payloadDictionary(body["sequenceJson"]))
        #expect(sequence["@type"] as? String == "com.amazon.alexa.behaviors.model.Sequence")
        let node = try #require(sequence["startNode"] as? [String: Any])
        #expect(node["@type"] as? String == "com.amazon.alexa.behaviors.model.OpaquePayloadOperationNode")
        #expect(node["type"] as? String == "Alexa.Music.PlaySearchPhrase")
        let payload = try #require(node["operationPayload"] as? [String: Any])
        #expect(payload["sanitizedSearchPhrase"] as? String == "better together by jack johnson")
        #expect(payload["customerId"] as? String == "A1CUSTOMER")
        #expect(payload["deviceType"] as? String == "A3S5BH2HU6VAYF")
    }

    @Test func playAcceptsStringEncodedValidatedPayload() async throws {
        let transport = MockTransport { request in
            if request.url!.path.hasSuffix("validate") {
                return .json(["result": "VALID", "operationPayload": #"{"searchPhrase":"x","sanitizedSearchPhrase":"x"}"#])
            }
            return .text("", contentType: "application/json")
        }
        let client = AlexaClient(credentials: .fixture(), transport: transport)
        try await client.play("x", on: .kitchen)
        let body = try #require(transport.requests.last?.jsonBody)
        let node = try #require(AlexaClient.payloadDictionary(body["sequenceJson"])?["startNode"] as? [String: Any])
        let payload = try #require(node["operationPayload"] as? [String: Any])
        // Device fields we sent are merged back in when Alexa omits them.
        #expect(payload["deviceSerialNumber"] as? String == EchoDevice.kitchen.serialNumber)
        #expect(payload["sanitizedSearchPhrase"] as? String == "x")
    }

    @Test func checkPlayValidatesWithoutPlaying() async throws {
        let transport = MockTransport { _ in
            .json(["result": "VALID", "operationPayload": ["sanitizedSearchPhrase": "rumours by fleetwood mac"]])
        }
        let client = AlexaClient(credentials: .fixture(), transport: transport)
        let sanitized = try await client.checkPlay("Rumours by Fleetwood Mac", on: .kitchen)
        #expect(sanitized == "rumours by fleetwood mac")
        #expect(transport.requests.map { $0.url!.path } == ["/api/behaviors/operation/validate"])
    }

    @Test func defaultPrefersAnOnlineEchoOverGroupsAndTVs() throws {
        let devices = EchoDevice.musicTargets(try JSONDecoder().decode(
            [String: [EchoDevice]].self,
            from: JSONSerialization.data(withJSONObject: Self.devicesJSON)
        )["devices"]!)
        #expect(devices.first?.accountName == "Everywhere", "groups sort first alphabetically…")
        #expect(SendToAlexa.suggestedDefault(in: devices)?.accountName == "Kitchen", "…but aren't the default")
        let onlyGroupAndTV = [
            EchoDevice(accountName: "Everywhere", serialNumber: "G", deviceType: "T", deviceFamily: "WHA", deviceOwnerCustomerId: "C"),
            EchoDevice(accountName: "TV", serialNumber: "F", deviceType: "T", deviceFamily: "FIRE_TV", deviceOwnerCustomerId: "C"),
        ]
        #expect(SendToAlexa.suggestedDefault(in: onlyGroupAndTV)?.accountName == "TV")
        #expect(SendToAlexa.suggestedDefault(in: []) == nil)
    }

    @Test func invalidSearchIsReported() async {
        let transport = MockTransport { _ in .json(["result": "INVALID", "message": "Provider not linked"]) }
        let client = AlexaClient(credentials: .fixture(), transport: transport)
        await #expect(throws: AlexaError.invalidSearch("Provider not linked")) {
            try await client.play("anything", on: .kitchen)
        }
        #expect(transport.requests.count == 1, "nothing is played when validation fails")
    }

    @Test func emptyPhraseIsRejectedLocally() async {
        let transport = MockTransport { _ in .text("", status: 500) }
        let client = AlexaClient(credentials: .fixture(), transport: transport)
        await #expect(throws: AlexaError.self) { try await client.play("   ", on: .kitchen) }
        #expect(transport.requests.isEmpty)
    }

    @Test func refreshesCookiesOnceWhenSessionExpires() async throws {
        let state = Counter()
        let transport = MockTransport { request in
            let path = request.url!.path
            if path == "/ap/exchangetoken/cookies" {
                return .json(["response": ["tokens": ["cookies": [".amazon.co.uk": [["Name": "session-id", "Value": "new"]]]]]])
            }
            if path == "/api/language" {
                return .text("", headers: ["Set-Cookie": "csrf=fresh; Path=/"])
            }
            if path.hasPrefix("/api/devices-v2") {
                // First call: expired; after refresh: OK.
                return state.next() == 0 ? .text("<html>sign in</html>", contentType: "text/html") : .json(Self.devicesJSON)
            }
            return .text("", status: 404)
        }
        let saved = Box()
        let client = AlexaClient(credentials: .fixture(), transport: transport) { saved.value = $0 }
        let devices = try await client.devices()
        #expect(devices.count == 5)
        #expect(saved.value?.csrf == "fresh")
        #expect(saved.value?.cookies?["session-id"] == "new")
        let retried = try #require(transport.requests.last)
        #expect(retried.value(forHTTPHeaderField: "csrf") == "fresh")
    }

    @Test func derivesSessionUpFrontWhenMissing() async throws {
        let transport = MockTransport { request in
            switch request.url!.path {
            case "/ap/exchangetoken/cookies":
                return .json(["response": ["tokens": ["cookies": [".amazon.co.uk": [["Name": "csrf", "Value": "from-exchange"]]]]]])
            default:
                return .json(Self.devicesJSON)
            }
        }
        let client = AlexaClient(credentials: .fixture(fresh: false), transport: transport)
        _ = try await client.devices()
        #expect(transport.requests.first?.url?.host == "www.amazon.co.uk")
        #expect(transport.requests.last?.value(forHTTPHeaderField: "csrf") == "from-exchange")
    }

    @Test func findsDevicesByNameOrSerial() {
        let devices = [EchoDevice.kitchen]
        #expect(EchoDevice.find("kitchen", in: devices) == .kitchen)
        #expect(EchoDevice.find("G0911W0000000001", in: devices) == .kitchen)
        #expect(EchoDevice.find("kitch", in: devices) == .kitchen)
        #expect(EchoDevice.find("garage", in: devices) == nil)
    }

    @Test func sanitizesLikeAlexa() {
        #expect(AlexaClient.sanitize("Don't Stop Me Now — Queen!") == "don t stop me now queen")
    }
}

final class Counter: @unchecked Sendable {
    private var value = 0
    private let lock = NSLock()
    func next() -> Int { lock.withLock { defer { value += 1 }; return value } }
    func peek() -> Int { lock.withLock { value } }
}

final class Box: @unchecked Sendable {
    private var _value: AlexaCredentials?
    private let lock = NSLock()
    var value: AlexaCredentials? {
        get { lock.withLock { _value } }
        set { lock.withLock { _value = newValue } }
    }
}
