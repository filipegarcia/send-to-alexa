import Foundation

/// Everything needed to talk to Alexa on behalf of a user.
///
/// The only long-lived secret is `refreshToken` (Amazon device-registration token, starts with `Atnr|`).
/// Treat the whole struct as a secret: store it in the Keychain (see `KeychainStore`) or a 0600 file.
public struct AlexaCredentials: Codable, Sendable, Equatable {
    /// Domain the device was registered with (e.g. `amazon.com`). Token calls go to `api.<loginDomain>`.
    public var loginDomain: String
    /// Marketplace the account belongs to (e.g. `amazon.co.uk`). Alexa calls go to `alexa.<marketplaceDomain>`.
    public var marketplaceDomain: String
    /// Locale used in Alexa requests (e.g. `en-GB`).
    public var locale: String
    /// Serial number of our virtual "device" in the user's Amazon account.
    public var deviceSerial: String
    /// Long-lived refresh token returned by device registration.
    public var refreshToken: String
    /// First name from the Amazon account, for display only.
    public var customerName: String?
    public var registeredAt: Date

    /// Cached web-session cookies for `alexa.<marketplaceDomain>` (derived from the refresh token).
    public var cookies: [String: String]?
    /// CSRF token required by the Alexa web API (derived together with `cookies`).
    public var csrf: String?
    public var cookiesFetchedAt: Date?

    public init(
        loginDomain: String,
        marketplaceDomain: String,
        locale: String,
        deviceSerial: String,
        refreshToken: String,
        customerName: String? = nil,
        registeredAt: Date = Date(),
        cookies: [String: String]? = nil,
        csrf: String? = nil,
        cookiesFetchedAt: Date? = nil
    ) {
        self.loginDomain = loginDomain
        self.marketplaceDomain = marketplaceDomain
        self.locale = locale
        self.deviceSerial = deviceSerial
        self.refreshToken = refreshToken
        self.customerName = customerName
        self.registeredAt = registeredAt
        self.cookies = cookies
        self.csrf = csrf
        self.cookiesFetchedAt = cookiesFetchedAt
    }

    public var marketplace: AmazonRegion { AmazonRegion.forDomain(marketplaceDomain) }
    public var loginRegion: AmazonRegion { AmazonRegion.forDomain(loginDomain) }

    /// Web cookies are refreshed when older than this.
    public static let cookieLifetime: TimeInterval = 12 * 60 * 60

    public func hasFreshWebSession(now: Date = Date()) -> Bool {
        guard let cookies, !cookies.isEmpty, csrf != nil, let fetched = cookiesFetchedAt else { return false }
        return now.timeIntervalSince(fetched) < Self.cookieLifetime
    }
}
