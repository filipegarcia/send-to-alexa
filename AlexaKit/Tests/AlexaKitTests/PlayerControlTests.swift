import Foundation
import Testing
@testable import AlexaKit

@Suite("Player controls")
struct PlayerControlTests {
    @Test(arguments: [
        (PlayerCommand.play, "PlayCommand"),
        (.pause, "PauseCommand"),
        (.next, "NextCommand"),
        (.previous, "PreviousCommand"),
        (.volume(40), "VolumeLevelCommand"),
    ])
    func sendsCommandToTheDevice(command: PlayerCommand, type: String) async throws {
        let transport = MockTransport { _ in .text("", contentType: "application/json") }
        let client = AlexaClient(credentials: .fixture(), transport: transport)
        try await client.send(command, to: .kitchen)
        let request = try #require(transport.requests.last)
        #expect(request.httpMethod == "POST")
        #expect(request.url?.path == "/api/np/command")
        #expect(request.url?.query?.contains("deviceSerialNumber=\(EchoDevice.kitchen.serialNumber)") == true)
        #expect(request.jsonBody?["type"] as? String == type)
    }

    @Test func clampsVolume() {
        #expect(PlayerCommand.volume(150).body["volumeLevel"] as? Int == 100)
        #expect(PlayerCommand.volume(-3).body["volumeLevel"] as? Int == 0)
    }

    @Test func readsVolumeFromMediaState() async throws {
        let transport = MockTransport { _ in .json(["volume": 54, "currentState": "IDLE"]) }
        let client = AlexaClient(credentials: .fixture(), transport: transport)
        #expect(try await client.volume(on: .kitchen) == 54)
        #expect(transport.requests.last?.url?.path == "/api/media/state")
    }

    @Test func parsesProgress() throws {
        let json: [String: Any] = ["playerInfo": [
            "state": "PLAYING", "infoText": ["title": "Marginalia #162", "subText1": "Marginalia VIII"],
            "progress": ["mediaLength": 305, "mediaProgress": 19],
        ]]
        let playing = try #require(NowPlaying.parse(JSONSerialization.data(withJSONObject: json)))
        #expect(playing.progressSeconds == 19)
        #expect(playing.lengthSeconds == 305)
    }

    @Test func fetchesEveryDeviceAtOnce() async throws {
        let transport = MockTransport { request in
            let serial = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?
                .queryItems?.first { $0.name == "deviceSerialNumber" }?.value ?? ""
            if serial == "B" { return .text("", status: 500) }
            return .json(["playerInfo": ["state": "PLAYING", "infoText": ["title": "Song \(serial)"]]])
        }
        let client = AlexaClient(credentials: .fixture(), transport: transport)
        let devices = ["A", "B", "C"].map {
            EchoDevice(accountName: $0, serialNumber: $0, deviceType: "T", deviceOwnerCustomerId: "C")
        }
        let statuses = await client.nowPlaying(on: devices)
        #expect(Set(statuses.keys) == ["A", "C"], "failing devices are skipped")
        #expect(statuses["C"]?.title == "Song C")
    }
}
