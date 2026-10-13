import Foundation
import Testing
@testable import AlexaKit

@Suite("Apple Music links")
struct MusicLinkTests {
    @Test func songInsideAlbumLink() throws {
        let link = try #require(MusicLink.parse(URL(string: "https://music.apple.com/gb/album/better-together/1440857781?i=1440857786")!))
        #expect(link.kind == .song)
        #expect(link.id == "1440857786")
        #expect(link.storefront == "gb")
        #expect(link.slug == "better-together")
    }

    @Test(arguments: [
        ("https://music.apple.com/us/album/in-between-dreams/1440857781", MusicItemKind.album, "1440857781"),
        ("https://music.apple.com/us/song/better-together/1440857786", .song, "1440857786"),
        ("https://music.apple.com/us/artist/jack-johnson/909253", .artist, "909253"),
        ("https://music.apple.com/us/playlist/todays-hits/pl.f4d106fed2bd41149aaacabb233eb5eb", .playlist, "pl.f4d106fed2bd41149aaacabb233eb5eb"),
        ("https://music.apple.com/us/station/apple-music-1/ra.978194965", .station, "ra.978194965"),
        ("https://music.apple.com/album/1440857781", .album, "1440857781"),
        ("https://itunes.apple.com/us/album/in-between-dreams/id1440857781", .album, "1440857781"),
        ("https://music.apple.com/us/music-video/some-video/123", .musicVideo, "123"),
    ])
    func parsesLinkKinds(url: String, kind: MusicItemKind, id: String) throws {
        let link = try #require(MusicLink.parse(URL(string: url)!))
        #expect(link.kind == kind)
        #expect(link.id == id)
    }

    @Test func rejectsNonAppleLinks() {
        #expect(MusicLink.parse(URL(string: "https://open.spotify.com/track/abc")!) == nil)
        #expect(MusicLink.parse(URL(string: "https://music.apple.com/")!) == nil)
    }

    @Test func findsURLInSharedText() {
        let text = "Listen to Better Together by Jack Johnson on Apple Music. https://music.apple.com/us/album/x/1?i=2 🎶"
        #expect(MusicLink.firstURL(in: text)?.absoluteString == "https://music.apple.com/us/album/x/1?i=2")
        #expect(MusicLink.firstURL(in: "no links here") == nil)
    }

    @Test(arguments: [
        ("Stay (feat. Justin Bieber)", "Stay"),
        ("Come Together (Remastered 2009)", "Come Together"),
        ("Here Comes the Sun - Remastered 2019", "Here Comes the Sun"),
        ("In Between Dreams (Bonus Track Version)", "In Between Dreams"),
        ("Rumours (Super Deluxe)", "Rumours"),
        ("Hello - Single", "Hello"),
        ("Unplugged (Live)", "Unplugged (Live)"),
        ("(What's the Story) Morning Glory?", "(What's the Story) Morning Glory?"),
    ])
    func cleansTitles(raw: String, clean: String) {
        #expect(MusicResolver.cleanTitle(raw) == clean)
    }

    @Test func buildsNaturalPhrases() {
        #expect(ResolvedMusic.phrase(kind: .song, title: "Stay (feat. Justin Bieber)", artist: "The Kid LAROI") == "Stay by The Kid LAROI")
        #expect(ResolvedMusic.phrase(kind: .album, title: "Rumours", artist: "Fleetwood Mac") == "the album Rumours by Fleetwood Mac")
        #expect(ResolvedMusic.phrase(kind: .playlist, title: "Today’s Hits", artist: nil) == "the Today’s Hits playlist")
        #expect(ResolvedMusic.phrase(kind: .playlist, title: "Chill Playlist", artist: nil) == "Chill Playlist")
        #expect(ResolvedMusic.phrase(kind: .artist, title: "Queen", artist: nil) == "Queen")
    }

    @Test func parsesApplePageTitles() {
        let song = MusicResolver.parsePageTitle("Better Together - Song with Lyrics by Jack Johnson - Apple Music")
        #expect(song.title == "Better Together")
        #expect(song.artist == "Jack Johnson")
        #expect(song.kind == .song)

        let playlist = MusicResolver.parsePageTitle("Today’s Hits - Playlist - Apple Music")
        #expect(playlist.title == "Today’s Hits")
        #expect(playlist.kind == .playlist)

        let station = MusicResolver.parsePageTitle("Apple Music 1 - Radio Station - Apple Music")
        #expect(station.title == "Apple Music 1")
        #expect(station.kind == .station)

        let dashed = MusicResolver.parsePageTitle("Hits - Remixed - Playlist - Apple Music")
        #expect(dashed.title == "Hits - Remixed")
    }

    @Test func resolvesSongViaItunesLookup() async throws {
        let transport = MockTransport { request in
            #expect(request.url?.host == "itunes.apple.com")
            #expect(request.url?.query?.contains("id=1440857786") == true)
            #expect(request.url?.query?.contains("country=gb") == true)
            return .json(["resultCount": 1, "results": [[
                "wrapperType": "track", "kind": "song", "trackName": "Better Together", "artistName": "Jack Johnson",
                "collectionName": "In Between Dreams", "artworkUrl100": "https://example.com/a/100x100bb.jpg",
            ]]])
        }
        let music = try await MusicResolver(transport: transport)
            .resolve(url: URL(string: "https://music.apple.com/gb/album/better-together/1440857781?i=1440857786"), text: nil)
        #expect(music == ResolvedMusic(
            title: "Better Together",
            artist: "Jack Johnson",
            kind: .song,
            artworkURL: URL(string: "https://example.com/a/600x600bb.jpg"),
            searchPhrase: "Better Together by Jack Johnson"
        ))
    }

    @Test func resolvesPlaylistViaPageTitle() async throws {
        let html = """
        <html><head><title>\u{200E}Today&#39;s Hits - Playlist - Apple Music</title>
        <meta property="og:image" content="https://example.com/cover.jpg"></head></html>
        """
        let transport = MockTransport { _ in .text(html, contentType: "text/html") }
        let music = try await MusicResolver(transport: transport)
            .resolve(url: URL(string: "https://music.apple.com/us/playlist/todays-hits/pl.abc"), text: nil)
        #expect(music.title == "Today's Hits")
        #expect(music.kind == .playlist)
        #expect(music.searchPhrase == "the Today's Hits playlist")
        #expect(music.artworkURL?.absoluteString == "https://example.com/cover.jpg")
    }

    @Test func fallsBackToSlugWhenOffline() async throws {
        let transport = MockTransport { _ in .text("", status: 503) }
        let music = try await MusicResolver(transport: transport)
            .resolve(url: URL(string: "https://music.apple.com/us/song/bohemian-rhapsody/123"), text: nil)
        #expect(music.searchPhrase == "bohemian rhapsody")
    }

    @Test func plainTextIsUsedAsTheSearch() async throws {
        let transport = MockTransport { _ in .text("", status: 500) }
        let music = try await MusicResolver(transport: transport).resolve(url: nil, text: "  Jazz for a rainy day \n")
        #expect(music.searchPhrase == "Jazz for a rainy day")
        #expect(transport.requests.isEmpty)
    }
}
