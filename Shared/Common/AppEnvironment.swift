import AlexaKit
import Foundation

/// Builds the `SendToAlexa` service shared by the app and its share extension.
///
/// iOS: the app and extension share a Keychain Sharing group; its full id (`<TeamID>.<prefix>.SendToAlexa.shared`)
/// is injected into each Info.plist as `KeychainAccessGroup` by the build settings in `Config/Base.xcconfig`.
/// macOS: the app, extension and CLI share `~/.config/send-to-alexa` (0600 files).
enum AppEnvironment {
    static let appName = "Send to Alexa"

    static var keychainAccessGroup: String? {
        let value = Bundle.main.object(forInfoDictionaryKey: "KeychainAccessGroup") as? String
        // Unsigned simulator builds have no team prefix, e.g. ".com.example..." — fall back to the default group.
        guard let value, !value.isEmpty, !value.hasPrefix(".") else { return nil }
        return value
    }

    static let service: SendToAlexa = {
        #if os(macOS)
        // Mac: share ~/.config/send-to-alexa with the CLI. Works without an Apple Developer account
        // (no Keychain Sharing entitlement needed) — see the temporary-exception entitlement in project.yml.
        let backing: BlobStore = FileStore(directory: FileStore.defaultDirectory())
        #else
        let backing: BlobStore = KeychainStore(service: "SendToAlexa", accessGroup: keychainAccessGroup)
        #endif
        return SendToAlexa(store: AlexaStore(backing), appName: appName)
    }()

    /// Best guess at the user's Alexa marketplace from the device region.
    static var suggestedMarketplace: AmazonRegion {
        switch Locale.current.region?.identifier.uppercased() {
        case "GB", "IE": return .unitedKingdom
        case "DE", "AT", "CH", "LU": return .germany
        case "FR", "BE": return .france
        case "IT": return .italy
        case "ES", "PT": return .spain
        case "CA": return .canada
        case "AU", "NZ": return .australia
        case "IN": return .india
        case "JP": return .japan
        case "BR": return .brazil
        case "MX": return .mexico
        default: return .unitedStates
        }
    }
}
