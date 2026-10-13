import Foundation

// Alexa can't play an Apple Music track *by id*: Apple Music is a third-party music skill, and Alexa only hands it
// a parsed search. So instead of "exact play" we do "play, then check": read what the Echo reports as now playing,
// compare it with the shared song, and retry with more specific wording if Alexa picked something else.

/// What an Echo reports as playing (`GET /api/np/player`).
public struct NowPlaying: Equatable, Sendable, Codable {
    /// `PLAYING`, `PAUSED`, `IDLE`, ...
    public var state: String?
    public var title: String?
    /// Second line on the Echo screen — usually the artist, sometimes the album.
    public var subtitle: String?
    /// e.g. "Apple Music".
    public var provider: String?
    public var artworkURL: URL?
    /// Changes every time something new is queued; used to detect that *our* request started playing.
    public var queueId: String?

    public init(state: String? = nil, title: String? = nil, subtitle: String? = nil, provider: String? = nil, artworkURL: URL? = nil, queueId: String? = nil) {
        self.state = state
        self.title = title
        self.subtitle = subtitle
        self.provider = provider
        self.artworkURL = artworkURL
        self.queueId = queueId
    }

    public var isPlaying: Bool { state == "PLAYING" }

    /// "Better Together — Jack Johnson"
    public var summary: String {
        [title, subtitle].compactMap { $0?.isEmpty == false ? $0 : nil }.joined(separator: " — ")
    }

    /// Parses the `/api/np/player` response. Returns nil when the device has no player info.
    static func parse(_ data: Data) -> NowPlaying? {
        guard let json = HTTP.jsonObject(data), let info = json["playerInfo"] as? [String: Any] else { return nil }
        let text = info["infoText"] as? [String: Any]
        let provider = info["provider"] as? [String: Any]
        let art = info["mainArt"] as? [String: Any]
        let result = NowPlaying(
            state: info["state"] as? String,
            title: text?["title"] as? String,
            subtitle: text?["subText1"] as? String,
            provider: provider?["providerName"] as? String,
            artworkURL: (art?["url"] as? String).flatMap(URL.init(string:)),
            queueId: info["queueId"] as? String
        )
        return result.state == nil && result.title == nil ? nil : result
    }
}

/// Outcome of `SendToAlexa.playVerified`.
public struct PlaybackResult: Equatable, Sendable {
    public enum Verdict: String, Equatable, Sendable {
        /// The Echo is playing the shared song (title + artist/album match).
        case matched
        /// The Echo is playing something else, even after retries.
        case mismatched
        /// We couldn't tell (playlist/station or edited search).
        case unverified
        /// Nothing started playing — Alexa most likely found no match for any phrasing.
        case notStarted
    }

    public var verdict: Verdict
    /// What the Echo reported last (nil if it never reported).
    public var nowPlaying: NowPlaying?
    /// The search phrase that produced `nowPlaying`.
    public var phrase: String
    /// How many play requests were sent.
    public var attempts: Int
}

/// Timing for verification; tests use tiny values.
public struct VerificationTiming: Sendable {
    public var pollInterval: Duration
    /// How long to wait for the Echo to report the new item, per attempt.
    public var timeout: Duration

    public init(pollInterval: Duration = .milliseconds(700), timeout: Duration = .seconds(7)) {
        self.pollInterval = pollInterval
        self.timeout = timeout
    }

    public static let `default` = VerificationTiming()
}

extension ResolvedMusic {
    /// Search phrases to try in order: the current `searchPhrase` first, then alternatives
    /// from `SearchPhrasing` (songs and albums only).
    public var searchCandidates: [String] {
        var phrases = [searchPhrase]
        switch kind {
        case .song, .musicVideo:
            phrases += SearchPhrasing.songCandidates(title: title, artist: artist, album: album)
        case .album:
            phrases += SearchPhrasing.albumCandidates(title: title, artist: artist)
        default:
            break
        }
        return SearchPhrasing.unique(phrases)
    }

    /// Does `playing` look like this item? `nil` means "can't tell" (no retry in that case).
    public func matches(_ playing: NowPlaying) -> Bool? {
        switch kind {
        case .song, .musicVideo:
            guard let playingTitle = playing.title, !playingTitle.isEmpty else { return nil }
            // Strict on the title: "(Remix)", "(Live)", "(Instrumental)" are different recordings.
            guard Self.normalize(playingTitle) == Self.normalize(title) else { return false }
            guard let subtitle = playing.subtitle, !subtitle.isEmpty else { return true }
            let artistOK = artist.map { Self.artistsOverlap(subtitle, $0) } ?? true
            let albumOK = album.map { Self.normalize(subtitle) == Self.normalize($0) } ?? false
            return artistOK || albumOK
        case .album:
            guard let subtitle = playing.subtitle, !subtitle.isEmpty, let artist else { return nil }
            return Self.artistsOverlap(subtitle, artist) || Self.normalize(subtitle) == Self.normalize(title)
        case .artist:
            guard let subtitle = playing.subtitle else { return nil }
            return Self.artistsOverlap(subtitle, title) ? true : nil
        default:
            return nil
        }
    }

    /// Lower-case, no accents, no decorations like "(feat. …)" / "- Remastered", punctuation collapsed.
    static func normalize(_ string: String) -> String {
        let cleaned = MusicResolver.cleanTitle(string)
            .folding(options: [.diacriticInsensitive, .caseInsensitive, .widthInsensitive], locale: nil)
            .lowercased()
            .replacingOccurrences(of: "&", with: " and ")
            .replacingOccurrences(of: "’", with: "")
            .replacingOccurrences(of: "'", with: "")
        let scalars = cleaned.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) ? Character($0) : " " }
        return String(scalars).split(separator: " ").joined(separator: " ")
    }

    /// True if any credited artist on one side appears on the other ("Ja Rule" vs "Ashanti, Ja Rule & R. Kelly").
    static func artistsOverlap(_ a: String, _ b: String) -> Bool {
        let left = splitArtists(a), right = splitArtists(b)
        let leftJoined = normalize(a), rightJoined = normalize(b)
        if !leftJoined.isEmpty, leftJoined == rightJoined { return true }
        return left.contains { name in name.count >= 2 && (right.contains(name) || rightJoined.contains(name)) }
            || right.contains { name in name.count >= 2 && leftJoined.contains(name) }
    }

    static func splitArtists(_ string: String) -> [String] {
        var parts = [string]
        for separator in [",", "&", " and ", " feat. ", " feat ", " ft. ", " x ", " with ", " / "] {
            parts = parts.flatMap { $0.components(separatedBy: separator) }
        }
        return parts.map(normalize).filter { !$0.isEmpty }
    }
}

extension AlexaClient {
    /// What `device` is playing right now (nil if it reports nothing).
    public func nowPlaying(on device: EchoDevice) async throws -> NowPlaying? {
        let path = "/api/np/player?deviceSerialNumber=\(device.serialNumber)&deviceType=\(device.deviceType)&screenWidth=1392"
        return NowPlaying.parse(try await rawRequest("GET", path))
    }

    /// Polls until the Echo reports something *new* playing (different queue or title than `previous`).
    /// Returns the last report if it never changes but something is playing, nil if nothing is playing.
    func waitForNewPlayback(on device: EchoDevice, previous: NowPlaying?, timing: VerificationTiming) async -> NowPlaying? {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timing.timeout)
        var latest: NowPlaying?
        while clock.now < deadline {
            try? await Task.sleep(for: timing.pollInterval)
            guard let current = try? await nowPlaying(on: device) else { continue }
            latest = current
            let isNew = current.queueId != previous?.queueId || current.title != previous?.title
            if current.isPlaying, previous == nil || isNew {
                return current
            }
        }
        return latest?.isPlaying == true ? latest : nil
    }
}

extension SendToAlexa {
    /// Plays `music` on `device`, checks what the Echo actually started, and — if it's a different song —
    /// retries with more specific wording (`music.searchCandidates`).
    ///
    /// - Parameters:
    ///   - phrase: the (possibly user-edited) phrase to try first. If it differs from `music.searchPhrase`
    ///     the user has taken over, so we play it once and just report what's playing.
    ///   - retry: whether to try alternative phrasings on a mismatch (`Preferences.retryOnMismatch` by default).
    ///   - progress: called with short status messages for the UI.
    public func playVerified(
        _ music: ResolvedMusic,
        phrase: String? = nil,
        on device: EchoDevice,
        provider: MusicProvider? = nil,
        retry: Bool? = nil,
        timing: VerificationTiming = .default,
        progress: (@Sendable (String) -> Void)? = nil
    ) async throws -> PlaybackResult {
        let prefs = store.loadPreferences()
        let provider = provider ?? prefs.provider
        let retry = retry ?? prefs.retryOnMismatch
        let client = try client()

        let firstPhrase = (phrase ?? music.searchPhrase).trimmingCharacters(in: .whitespacesAndNewlines)
        let edited = firstPhrase != music.searchPhrase
        let candidates = edited ? [firstPhrase] : Array(music.searchCandidates.prefix(retry ? 3 : 1))

        var previous = try? await client.nowPlaying(on: device)
        var result = PlaybackResult(verdict: .unverified, nowPlaying: nil, phrase: firstPhrase, attempts: 0)

        for (index, candidate) in candidates.enumerated() {
            progress?(index == 0 ? "Asking Alexa to play it…" : "Not quite — trying “\(candidate)”…")
            try await client.play(candidate, provider: provider, on: device)
            result.attempts = index + 1
            result.phrase = candidate

            progress?("Checking what’s playing…")
            guard let playing = await client.waitForNewPlayback(on: device, previous: previous, timing: timing) else {
                // Nothing new started: Alexa probably found nothing for this wording. Try the next one.
                result.verdict = .notStarted
                result.nowPlaying = nil
                continue
            }
            result.nowPlaying = playing
            previous = playing

            if edited {
                result.verdict = .unverified
                break
            }
            switch music.matches(playing) {
            case true?:
                result.verdict = .matched
            case false?:
                result.verdict = .mismatched
                continue
            case nil:
                result.verdict = .unverified
            }
            break
        }

        try? store.updatePreferences { $0.defaultDeviceSerial = device.serialNumber }
        return result
    }
}
