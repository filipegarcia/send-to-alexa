import Foundation

/// An Amazon marketplace. It decides which hosts are used for sign-in
/// (`www.<domain>`, `api.<domain>`) and for the Alexa web API (`alexa.<domain>`).
public struct AmazonRegion: Hashable, Codable, Sendable, Identifiable {
    /// Marketplace domain without `www.`, e.g. `amazon.com`, `amazon.co.uk`.
    public let domain: String
    /// Human readable name for pickers.
    public let name: String
    /// BCP-47 locale used for Alexa requests, e.g. `en-GB`.
    public let locale: String

    public var id: String { domain }

    public init(domain: String, name: String, locale: String) {
        self.domain = domain
        self.name = name
        self.locale = locale
    }

    public var wwwHost: String { "www.\(domain)" }
    public var apiHost: String { "api.\(domain)" }
    public var alexaHost: String { "alexa.\(domain)" }

    /// Top-level part of the domain (`com`, `uk`, `de`, `jp`, ...).
    var tld: String { String(domain.split(separator: ".").last ?? "com") }

    /// Suffix Amazon expects on the OpenID `assoc_handle` / `pageId` for non-.com marketplaces.
    var assocHandleSuffix: String { tld == "com" ? "" : "_\(tld)" }

    /// Locale formatted the way Amazon's sign-in page expects (`en_US`).
    var signInLanguage: String { locale.replacingOccurrences(of: "-", with: "_") }
}

public extension AmazonRegion {
    static let unitedStates = AmazonRegion(domain: "amazon.com", name: "United States", locale: "en-US")
    static let unitedKingdom = AmazonRegion(domain: "amazon.co.uk", name: "United Kingdom & Ireland", locale: "en-GB")
    static let germany = AmazonRegion(domain: "amazon.de", name: "Germany & Austria", locale: "de-DE")
    static let france = AmazonRegion(domain: "amazon.fr", name: "France", locale: "fr-FR")
    static let italy = AmazonRegion(domain: "amazon.it", name: "Italy", locale: "it-IT")
    static let spain = AmazonRegion(domain: "amazon.es", name: "Spain", locale: "es-ES")
    static let canada = AmazonRegion(domain: "amazon.ca", name: "Canada", locale: "en-CA")
    static let australia = AmazonRegion(domain: "amazon.com.au", name: "Australia", locale: "en-AU")
    static let india = AmazonRegion(domain: "amazon.in", name: "India", locale: "en-IN")
    static let japan = AmazonRegion(domain: "amazon.co.jp", name: "Japan", locale: "ja-JP")
    static let brazil = AmazonRegion(domain: "amazon.com.br", name: "Brazil", locale: "pt-BR")
    static let mexico = AmazonRegion(domain: "amazon.com.mx", name: "Mexico", locale: "es-MX")

    /// All marketplaces we know about, in picker order.
    static let all: [AmazonRegion] = [
        .unitedStates, .unitedKingdom, .germany, .france, .italy, .spain,
        .canada, .australia, .india, .japan, .brazil, .mexico,
    ]

    /// Looks up a known region by domain. Accepts `amazon.co.uk`, `www.amazon.co.uk`, `https://www.amazon.co.uk/`.
    /// Unknown domains are returned as a custom region with an `en-US` locale.
    static func forDomain(_ raw: String) -> AmazonRegion {
        var domain = raw.lowercased()
        for prefix in ["https://", "http://"] where domain.hasPrefix(prefix) {
            domain.removeFirst(prefix.count)
        }
        domain = domain.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        for prefix in ["www.", "alexa.", "api."] where domain.hasPrefix(prefix) {
            domain.removeFirst(prefix.count)
        }
        return all.first { $0.domain == domain } ?? AmazonRegion(domain: domain, name: domain, locale: "en-US")
    }
}
