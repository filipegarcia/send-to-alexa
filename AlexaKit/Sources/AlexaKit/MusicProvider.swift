import Foundation

/// Music services Alexa can search. The raw value is Alexa's `musicProviderId`.
/// The service must be linked in the Alexa app (More > Settings > Music & Podcasts).
public enum MusicProvider: String, Codable, CaseIterable, Sendable, Identifiable {
    case appleMusic = "APPLE_MUSIC"
    case amazonMusic = "AMAZON_MUSIC"
    case spotify = "SPOTIFY"
    case deezer = "DEEZER"
    case tuneIn = "TUNEIN"
    case iHeartRadio = "I_HEART_RADIO"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .appleMusic: return "Apple Music"
        case .amazonMusic: return "Amazon Music"
        case .spotify: return "Spotify"
        case .deezer: return "Deezer"
        case .tuneIn: return "TuneIn"
        case .iHeartRadio: return "iHeartRadio"
        }
    }
}
