import Foundation

/// What kind of thing an Apple Music link points to.
public enum MusicItemKind: String, Codable, Sendable {
    case song, album, artist, playlist, station, musicVideo, unknown
}

/// A parsed Apple Music share link, e.g.
/// `https://music.apple.com/us/album/better-together/1440857781?i=1440857786`.
public struct MusicLink: Equatable, Sendable {
    public let url: URL
    /// Two-letter storefront from the path (`us`, `gb`, ...). Defaults to `us`.
    public let storefront: String
    public let kind: MusicItemKind
    /// Catalog id (numeric for songs/albums/artists, `pl.…` for playlists, `ra.…` for stations).
    public let id: String?
    /// URL slug, e.g. `better-together`. Used as a last-resort title.
    public let slug: String?

    static let hosts: Set<String> = [
        "music.apple.com", "geo.music.apple.com", "embed.music.apple.com",
        "itunes.apple.com", "geo.itunes.apple.com",
    ]

    /// Returns nil when `url` isn't an Apple Music / iTunes link.
    public static func parse(_ url: URL) -> MusicLink? {
        guard let host = url.host?.lowercased(), hosts.contains(host) else { return nil }
        var parts = url.path.split(separator: "/").map(String.init)
        var storefront = "us"
        if let first = parts.first, first.count == 2, first.allSatisfy(\.isLetter) {
            storefront = first.lowercased()
            parts.removeFirst()
        }
        guard let type = parts.first else { return nil }
        let rest = Array(parts.dropFirst())
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let trackId = query.first { $0.name == "i" }?.value

        // The id is the last path component; the slug (if any) is the one before it.
        let id = rest.last.map { $0.hasPrefix("id") && $0.dropFirst(2).allSatisfy(\.isNumber) ? String($0.dropFirst(2)) : $0 }
        let slug = rest.count >= 2 ? rest[rest.count - 2] : nil

        let kind: MusicItemKind
        var resolvedId = id
        switch type {
        case "album":
            if let trackId, !trackId.isEmpty {
                kind = .song
                resolvedId = trackId
            } else {
                kind = .album
            }
        case "song": kind = .song
        case "artist": kind = .artist
        case "playlist": kind = .playlist
        case "station": kind = .station
        case "music-video": kind = .musicVideo
        default: kind = .unknown
        }
        return MusicLink(url: url, storefront: storefront, kind: kind, id: resolvedId, slug: slug)
    }

    /// Finds the first URL in arbitrary shared text ("Check this out https://music.apple.com/...").
    public static func firstURL(in text: String) -> URL? {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        return detector.firstMatch(in: text, options: [], range: range)?.url
    }
}

/// What we'll ask Alexa to play, plus display info for the UI.
public struct ResolvedMusic: Equatable, Sendable, Codable {
    public var title: String
    public var artist: String?
    public var kind: MusicItemKind
    public var artworkURL: URL?
    /// The phrase sent to Alexa, e.g. "Better Together by Jack Johnson". Editable by the user.
    public var searchPhrase: String

    public init(title: String, artist: String? = nil, kind: MusicItemKind, artworkURL: URL? = nil, searchPhrase: String) {
        self.title = title
        self.artist = artist
        self.kind = kind
        self.artworkURL = artworkURL
        self.searchPhrase = searchPhrase
    }

    /// Builds a natural search phrase the way you'd say it to Alexa.
    public static func phrase(kind: MusicItemKind, title: String, artist: String?) -> String {
        let cleanTitle = MusicResolver.cleanTitle(title)
        switch kind {
        case .song, .musicVideo:
            return artist.map { "\(cleanTitle) by \($0)" } ?? cleanTitle
        case .album:
            return artist.map { "the album \(cleanTitle) by \($0)" } ?? "the album \(cleanTitle)"
        case .artist:
            return cleanTitle
        case .playlist:
            return cleanTitle.lowercased().hasSuffix("playlist") ? cleanTitle : "the \(cleanTitle) playlist"
        case .station:
            return cleanTitle
        case .unknown:
            return artist.map { "\(cleanTitle) by \($0)" } ?? cleanTitle
        }
    }
}

/// Turns whatever was shared (Apple Music URL, any URL, or plain text) into a `ResolvedMusic`.
///
/// Uses Apple's public iTunes Lookup API for songs/albums/artists, and the public web page's `<title>`
/// for playlists/stations. No Apple Music developer token is needed.
public struct MusicResolver: Sendable {
    let transport: HTTPTransport

    public init(transport: HTTPTransport = URLSessionTransport()) {
        self.transport = transport
    }

    /// Resolves shared content. `text` may contain a URL; if there's no URL the text itself is the search phrase.
    public func resolve(url: URL?, text: String?) async throws -> ResolvedMusic {
        let candidateURL = url ?? text.flatMap(MusicLink.firstURL(in:))
        if let candidateURL, let link = MusicLink.parse(candidateURL) {
            return try await resolve(link)
        }
        let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !trimmed.isEmpty, candidateURL == nil {
            return ResolvedMusic(title: trimmed, kind: .unknown, searchPhrase: trimmed)
        }
        if let candidateURL, let page = try? await pageMetadata(candidateURL), !page.title.isEmpty {
            return ResolvedMusic(title: page.title, kind: .unknown, artworkURL: page.image, searchPhrase: page.title)
        }
        throw AlexaError.unsupportedLink(candidateURL?.absoluteString ?? "the shared item")
    }

    public func resolve(_ link: MusicLink) async throws -> ResolvedMusic {
        switch link.kind {
        case .song, .album, .artist, .musicVideo:
            if let id = link.id, id.allSatisfy(\.isNumber), let item = try? await lookup(id: id, storefront: link.storefront) {
                return item.resolved(kind: link.kind)
            }
        case .playlist, .station, .unknown:
            break
        }
        // Fallback: scrape the public page title ("Today’s Hits - Playlist - Apple Music").
        if let page = try? await pageMetadata(link.url), !page.title.isEmpty {
            let parsed = Self.parsePageTitle(page.title)
            let kind = link.kind == .unknown ? parsed.kind : link.kind
            return ResolvedMusic(
                title: parsed.title,
                artist: parsed.artist,
                kind: kind,
                artworkURL: page.image,
                searchPhrase: ResolvedMusic.phrase(kind: kind, title: parsed.title, artist: parsed.artist)
            )
        }
        // Last resort: the slug.
        if let slug = link.slug {
            let title = slug.replacingOccurrences(of: "-", with: " ")
            return ResolvedMusic(title: title, kind: link.kind, searchPhrase: ResolvedMusic.phrase(kind: link.kind, title: title, artist: nil))
        }
        throw AlexaError.unsupportedLink(link.url.absoluteString)
    }

    // MARK: iTunes Lookup

    struct LookupItem: Decodable {
        let wrapperType: String?
        let kind: String?
        let trackName: String?
        let collectionName: String?
        let artistName: String?
        let artworkUrl100: String?

        func resolved(kind linkKind: MusicItemKind) -> ResolvedMusic {
            let kind: MusicItemKind
            let title: String
            switch wrapperType {
            case "track":
                kind = linkKind == .musicVideo ? .musicVideo : .song
                title = trackName ?? collectionName ?? ""
            case "collection":
                kind = .album
                title = collectionName ?? ""
            case "artist":
                kind = .artist
                title = artistName ?? ""
            default:
                kind = linkKind
                title = trackName ?? collectionName ?? artistName ?? ""
            }
            let artist = kind == .artist ? nil : artistName
            // Ask for a bigger image than the 100px default.
            let artwork = artworkUrl100
                .map { $0.replacingOccurrences(of: "100x100bb", with: "600x600bb") }
                .flatMap(URL.init(string:))
            return ResolvedMusic(
                title: title,
                artist: artist,
                kind: kind,
                artworkURL: artwork,
                searchPhrase: ResolvedMusic.phrase(kind: kind, title: title, artist: artist)
            )
        }
    }

    func lookup(id: String, storefront: String) async throws -> LookupItem? {
        struct Response: Decodable { let results: [LookupItem] }
        var components = URLComponents(string: "https://itunes.apple.com/lookup")!
        components.queryItems = [URLQueryItem(name: "id", value: id), URLQueryItem(name: "country", value: storefront)]
        let (data, response) = try await transport.send(URLRequest(url: components.url!))
        try HTTP.ensureSuccess(data, response)
        return try JSONDecoder().decode(Response.self, from: data).results.first
    }

    // MARK: Web page metadata

    struct PageMetadata {
        var title: String
        var image: URL?
    }

    func pageMetadata(_ url: URL) async throws -> PageMetadata {
        var request = URLRequest(url: url)
        request.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await transport.send(request)
        try HTTP.ensureSuccess(data, response)
        let html = String(decoding: data.prefix(400_000), as: UTF8.self)
        let title = Self.firstMatch(#"<title[^>]*>([^<]+)</title>"#, in: html)
            ?? Self.metaContent(property: "og:title", in: html)
            ?? ""
        let image = Self.metaContent(property: "og:image", in: html).flatMap(URL.init(string:))
        return PageMetadata(title: Self.decodeEntities(title).trimmingCharacters(in: .whitespacesAndNewlines.union(Self.invisibleMarks)), image: image)
    }

    // MARK: Text helpers (internal for tests)

    static let invisibleMarks = CharacterSet(charactersIn: "\u{200E}\u{200F}\u{202A}\u{202B}\u{202C}\u{FEFF}")

    /// Parses Apple Music page titles like
    /// "Better Together - Song with Lyrics by Jack Johnson - Apple Music" or "Today’s Hits - Playlist - Apple Music".
    static func parsePageTitle(_ raw: String) -> (title: String, artist: String?, kind: MusicItemKind) {
        var parts = raw.components(separatedBy: " - ")
        if parts.last?.trimmingCharacters(in: .whitespaces) == "Apple Music" { parts.removeLast() }
        guard parts.count >= 2 else {
            let title = raw.replacingOccurrences(of: " on Apple Music", with: "")
            return (title, nil, .unknown)
        }
        let descriptor = parts.removeLast()
        let title = parts.joined(separator: " - ")
        var artist: String?
        if let range = descriptor.range(of: " by ") {
            artist = String(descriptor[range.upperBound...])
        }
        let lower = descriptor.lowercased()
        let kind: MusicItemKind =
            lower.hasPrefix("song") || lower.hasPrefix("single") ? .song :
            lower.hasPrefix("album") || lower.hasPrefix("ep") ? .album :
            lower.hasPrefix("playlist") ? .playlist :
            lower.contains("station") ? .station :
            lower.hasPrefix("music video") ? .musicVideo :
            lower.hasPrefix("artist") ? .artist : .unknown
        return (title, artist, kind)
    }

    /// Drops decorations that confuse voice search: "(feat. X)", "(Remastered 2011)", "- Single", "(Deluxe Edition)".
    public static func cleanTitle(_ title: String) -> String {
        var result = title
        let patterns = [
            #"\s*[\(\[][^\)\]]*\b(feat\.?|ft\.|featuring|remaster(ed)?|deluxe|bonus track|expanded|anniversary|edition)\b[^\)\]]*[\)\]]"#,
            #"\s+-\s+(.*remaster(ed)?.*|single|ep)$"#,
        ]
        for pattern in patterns {
            result = result.replacingOccurrences(of: pattern, with: "", options: [.regularExpression, .caseInsensitive])
        }
        result = result.trimmingCharacters(in: .whitespaces)
        return result.isEmpty ? title : result
    }

    static func firstMatch(_ pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              match.numberOfRanges > 1,
              let range = Range(match.range(at: 1), in: text)
        else { return nil }
        return String(text[range])
    }

    static func metaContent(property: String, in html: String) -> String? {
        let escaped = NSRegularExpression.escapedPattern(for: property)
        return firstMatch(#"<meta[^>]+property=["']\#(escaped)["'][^>]+content=["']([^"']+)["']"#, in: html)
            .map(decodeEntities)
    }

    static func decodeEntities(_ string: String) -> String {
        var result = string
        let entities = ["&amp;": "&", "&quot;": "\"", "&#39;": "'", "&#x27;": "'", "&apos;": "'", "&lt;": "<", "&gt;": ">", "&nbsp;": " "]
        for (entity, value) in entities { result = result.replacingOccurrences(of: entity, with: value) }
        return result
    }
}
