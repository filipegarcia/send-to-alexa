import Foundation
import Testing
@testable import AlexaKit

@Suite("Playback verification")
struct VerificationTests {
    static let betterTogether = ResolvedMusic(
        title: "Better Together", artist: "Jack Johnson", album: "In Between Dreams (Bonus Track Version)",
        kind: .song, searchPhrase: "Better Together by Jack Johnson"
    )

    static func player(_ title: String, _ subtitle: String, queue: String, state: String = "PLAYING") -> [String: Any] {
        ["playerInfo": [
            "state": state, "queueId": queue,
            "infoText": ["title": title, "subText1": subtitle, "subText2": "Apple Music"],
            "provider": ["providerName": "Apple Music"],
            "mainArt": ["url": "https://example.com/art.jpg"],
        ]]
    }

    // MARK: Parsing

    @Test func parsesNowPlaying() throws {
        let data = try JSONSerialization.data(withJSONObject: Self.player("Wonderful", "Ashanti, Ja Rule & R. Kelly", queue: "q1", state: "PAUSED"))
        let playing = try #require(NowPlaying.parse(data))
        #expect(playing.title == "Wonderful")
        #expect(playing.subtitle == "Ashanti, Ja Rule & R. Kelly")
        #expect(playing.provider == "Apple Music")
        #expect(playing.queueId == "q1")
        #expect(!playing.isPlaying)
        #expect(playing.summary == "Wonderful — Ashanti, Ja Rule & R. Kelly")
        #expect(NowPlaying.parse(Data(#"{"playerInfo":null}"#.utf8)) == nil)
    }

    // MARK: Matching

    @Test func matchesSameSongByArtistOrAlbum() {
        let song = Self.betterTogether
        #expect(song.matches(NowPlaying(title: "Better Together", subtitle: "Jack Johnson")) == true)
        #expect(song.matches(NowPlaying(title: "better together", subtitle: "In Between Dreams")) == true, "subtitle can be the album")
        #expect(song.matches(NowPlaying(title: "Better Together", subtitle: nil)) == true)
    }

    @Test func rejectsOtherRecordings() {
        let song = Self.betterTogether
        #expect(song.matches(NowPlaying(title: "Better Together (Live)", subtitle: "Jack Johnson")) == false)
        #expect(song.matches(NowPlaying(title: "Better Together", subtitle: "Some Cover Band")) == false)
        #expect(song.matches(NowPlaying(title: "Banana Pancakes", subtitle: "Jack Johnson")) == false)
    }

    @Test func toleratesFeaturingAndAccents() {
        let song = ResolvedMusic(title: "Wonderful (feat. R. Kelly & Ashanti)", artist: "Ja Rule", kind: .song, searchPhrase: "Wonderful by Ja Rule")
        #expect(song.matches(NowPlaying(title: "Wonderful", subtitle: "Ashanti, Ja Rule & R. Kelly")) == true)
        let accented = ResolvedMusic(title: "Café Del Mar", artist: "Energy 52", kind: .song, searchPhrase: "x")
        #expect(accented.matches(NowPlaying(title: "Cafe del Mar", subtitle: "Energy 52")) == true)
    }

    @Test func cannotTellForPlaylistsAndStations() {
        let playlist = ResolvedMusic(title: "Today’s Hits", kind: .playlist, searchPhrase: "the Today’s Hits playlist")
        #expect(playlist.matches(NowPlaying(title: "Anything", subtitle: "Anyone")) == nil)
    }

    @Test func buildsMoreSpecificCandidates() {
        #expect(Self.betterTogether.searchCandidates == [
            "Better Together by Jack Johnson",
            "the song Better Together by Jack Johnson",
            "Better Together by Jack Johnson from the album In Between Dreams",
        ])
        let single = ResolvedMusic(title: "Hello", artist: "Adele", album: "Hello - Single", kind: .song, searchPhrase: "Hello by Adele")
        #expect(single.searchCandidates == ["Hello by Adele", "the song Hello by Adele"], "album equal to title adds nothing")
    }

    // MARK: Flow

    /// Fake Echo whose now-playing changes after each play request.
    static func fakeEcho(playing: [[String: Any]]) -> (MockTransport, SendToAlexa) {
        let plays = Counter()
        let bodies = playing.map { try! JSONSerialization.data(withJSONObject: $0) } // Data is Sendable
        let transport = MockTransport { request in
            switch request.url!.path {
            case "/api/behaviors/operation/validate":
                return .json(["result": "VALID", "operationPayload": [:]])
            case "/api/behaviors/preview":
                _ = plays.next()
                return .text("", contentType: "application/json")
            case "/api/np/player":
                let index = min(plays.peek(), bodies.count - 1)
                return MockTransport.Reply(body: bodies[index])
            default:
                return .text("", status: 404)
            }
        }
        let store = AlexaStore(MemoryStore())
        try! store.saveCredentials(.fixture())
        return (transport, SendToAlexa(store: store, transport: transport))
    }

    static let fast = VerificationTiming(pollInterval: .milliseconds(1), timeout: .milliseconds(300))

    @Test func retriesUntilTheRightSongPlays() async throws {
        let (transport, app) = Self.fakeEcho(playing: [
            Self.player("Old song", "Someone", queue: "q0"),
            Self.player("Better Together (Live)", "Jack Johnson", queue: "q1"),
            Self.player("Better Together", "Jack Johnson", queue: "q2"),
        ])
        let result = try await app.playVerified(Self.betterTogether, on: .kitchen, timing: Self.fast)
        #expect(result.verdict == .matched)
        #expect(result.attempts == 2)
        #expect(result.phrase == "the song Better Together by Jack Johnson")
        #expect(result.nowPlaying?.queueId == "q2")
        #expect(transport.requests.filter { $0.url!.path == "/api/behaviors/preview" }.count == 2)
    }

    @Test func reportsMismatchAfterAllCandidates() async throws {
        let (transport, app) = Self.fakeEcho(playing: [
            Self.player("Old", "x", queue: "q0"),
            Self.player("Better Together (Live)", "Jack Johnson", queue: "q1"),
            Self.player("Better Together (Live)", "Jack Johnson", queue: "q2"),
            Self.player("Better Together (Live)", "Jack Johnson", queue: "q3"),
        ])
        let result = try await app.playVerified(Self.betterTogether, on: .kitchen, timing: Self.fast)
        #expect(result.verdict == .mismatched)
        #expect(result.attempts == 3)
        #expect(result.nowPlaying?.title == "Better Together (Live)")
        #expect(transport.requests.filter { $0.url!.path == "/api/behaviors/preview" }.count == 3)
    }

    @Test func noRetryWhenDisabled() async throws {
        let (_, app) = Self.fakeEcho(playing: [
            Self.player("Old", "x", queue: "q0"),
            Self.player("Wrong", "Someone", queue: "q1"),
        ])
        let result = try await app.playVerified(Self.betterTogether, on: .kitchen, retry: false, timing: Self.fast)
        #expect(result.verdict == .mismatched)
        #expect(result.attempts == 1)
    }

    @Test func editedSearchIsPlayedOnceAndReported() async throws {
        let (_, app) = Self.fakeEcho(playing: [
            Self.player("Old", "x", queue: "q0"),
            Self.player("Something", "Else", queue: "q1"),
        ])
        let result = try await app.playVerified(Self.betterTogether, phrase: "Better Together live at Mauna Kea", on: .kitchen, timing: Self.fast)
        #expect(result.verdict == .unverified)
        #expect(result.attempts == 1)
        #expect(result.nowPlaying?.summary == "Something — Else")
    }

    @Test func unverifiedWhenTheEchoNeverStarts() async throws {
        let (_, app) = Self.fakeEcho(playing: [Self.player("Old", "x", queue: "q0", state: "IDLE")])
        let result = try await app.playVerified(Self.betterTogether, on: .kitchen, timing: Self.fast)
        #expect(result.verdict == .unverified)
        #expect(result.nowPlaying == nil)
        #expect(result.attempts == 1)
    }
}
