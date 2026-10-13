import Foundation

/// Turns catalog metadata into phrases Alexa's search understands.
///
/// Lessons from real Echos:
/// - Long, punctuated phrases fail outright. `Songs from "Friday Afternoons", Op. 7: Cuckoo! by Choir of Downside
///   School, Purley, Benjamin Britten & Viola Tunnard` plays *nothing*.
/// - Short ones work: `Cuckoo by Choir of Downside School` or `Cuckoo from Friday Afternoons by Benjamin Britten`.
/// So: strip quotes, "!" and catalog numbers; for "Work: Movement" titles search the movement (+ work);
/// for long credit lists use the first performer.
public enum SearchPhrasing {
    /// Phrases to try for a song, most likely to hit first.
    public static func songCandidates(title: String, artist: String?, album: String?) -> [String] {
        let cleanTitle = MusicResolver.cleanTitle(title)
        let spokenTitle = speakable(cleanTitle)
        guard let artist, !artist.isEmpty else { return [spokenTitle] }
        let by = shortArtist(artist)

        var phrases: [String]
        if let parts = movement(of: cleanTitle) {
            // Classical-style "Work, Op. N: Movement".
            phrases = []
            if let work = parts.work { phrases.append("\(parts.movement) from \(work) by \(by)") }
            phrases.append("\(parts.movement) by \(by)")
            if let other = otherCredit(in: artist, excluding: by) {
                // Often the composer/conductor: "Cuckoo by Benjamin Britten".
                phrases.append("\(parts.movement) by \(other)")
            } else {
                phrases.append("\(speakable(removeCatalogNumbers(cleanTitle).replacingOccurrences(of: ":", with: " "))) by \(by)")
            }
        } else {
            phrases = ["\(spokenTitle) by \(by)", "the song \(spokenTitle) by \(by)"]
            if let album, !album.isEmpty {
                let spokenAlbum = speakable(MusicResolver.cleanTitle(album))
                if ResolvedMusic.normalize(spokenAlbum) != ResolvedMusic.normalize(spokenTitle) {
                    phrases.append("\(spokenTitle) by \(by) from the album \(spokenAlbum)")
                }
            }
        }
        return unique(phrases)
    }

    public static func albumCandidates(title: String, artist: String?) -> [String] {
        let spokenTitle = speakable(MusicResolver.cleanTitle(title))
        guard let artist, !artist.isEmpty else { return ["the album \(spokenTitle)"] }
        let by = shortArtist(artist)
        return unique(["the album \(spokenTitle) by \(by)", "\(spokenTitle) by \(by)"])
    }

    // MARK: Building blocks (internal for tests)

    /// The whole credit if it's short ("Earth, Wind & Fire", "Ashanti, Ja Rule & R. Kelly"),
    /// otherwise the first credited performer ("Choir of Downside School").
    static func shortArtist(_ artist: String) -> String {
        let trimmed = artist.trimmingCharacters(in: .whitespaces)
        guard trimmed.count > 40 else { return trimmed }
        let first = trimmed
            .components(separatedBy: ", ").first?
            .components(separatedBy: " & ").first?
            .trimmingCharacters(in: .whitespaces) ?? trimmed
        return first.isEmpty ? trimmed : first
    }

    /// Another credited name with at least two words ("Benjamin Britten"), skipping fragments like "Purley".
    static func otherCredit(in artist: String, excluding used: String) -> String? {
        let credits = artist
            .components(separatedBy: ", ")
            .flatMap { $0.components(separatedBy: " & ") }
            .map { $0.trimmingCharacters(in: .whitespaces) }
        return credits.first { $0 != used && $0.split(separator: " ").count >= 2 && !used.contains($0) }
    }

    /// Splits "Songs from \"Friday Afternoons\", Op. 7: Cuckoo!" into ("Cuckoo", "Friday Afternoons"),
    /// and "Symphony No. 5 in C Minor, Op. 67: I. Allegro con brio" into ("Allegro con brio", "Symphony No. 5 in C Minor").
    static func movement(of title: String) -> (movement: String, work: String?)? {
        guard let colon = title.range(of: ":", options: .backwards) else { return nil }
        var movement = String(title[colon.upperBound...])
        // Drop movement numbering like "I. ", "IV. ", "3. ".
        movement = movement.replacingOccurrences(of: #"^\s*(?:[IVXLC]+|\d+)\.\s+"#, with: "", options: .regularExpression)
        movement = speakable(movement)
        guard !movement.isEmpty else { return nil }

        let rawWork = String(title[..<colon.lowerBound])
        var work: String?
        if let quoted = firstQuoted(in: rawWork) {
            work = quoted
        } else {
            let stripped = speakable(removeCatalogNumbers(rawWork))
            work = stripped.isEmpty ? nil : stripped
        }
        if let w = work, ResolvedMusic.normalize(w) == ResolvedMusic.normalize(movement) { work = nil }
        return (movement, work)
    }

    /// Removes opus / catalogue numbers: "Op. 7", "Op. 10 No. 3", "BWV 1007", "K. 525", "Hob. XVI:52", "D. 960".
    static func removeCatalogNumbers(_ string: String) -> String {
        string.replacingOccurrences(
            of: #",?\s*\b(?:Op\.?|Opus|BWV|KV|K\.|Hob\.|D\.|RV|HWV|WoO|S\.)\s*[0-9IVXLC]+[a-z]?(?:[:.][0-9IVXLC]+)?(?:,?\s*No\.\s*\d+)?"#,
            with: "",
            options: [.regularExpression, .caseInsensitive]
        )
    }

    /// Removes characters that trip up voice-style search: quotes, "!", "?", stray dashes; collapses spaces.
    static func speakable(_ string: String) -> String {
        var result = string
        for character in ["\"", "“", "”", "„", "«", "»", "!", "?", "¡", "¿", "*"] {
            result = result.replacingOccurrences(of: character, with: "")
        }
        result = result.replacingOccurrences(of: " - ", with: " ")
        result = result.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        return result.trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: ",.;:-")))
    }

    static func firstQuoted(in string: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: #"["“„«]([^"”“»]{2,})["”“»]"#),
              let match = regex.firstMatch(in: string, range: NSRange(string.startIndex..., in: string)),
              let range = Range(match.range(at: 1), in: string)
        else { return nil }
        return speakable(String(string[range]))
    }

    static func unique(_ phrases: [String]) -> [String] {
        var seen = Set<String>()
        return phrases.filter { !$0.isEmpty && seen.insert(ResolvedMusic.normalize($0)).inserted }
    }
}
