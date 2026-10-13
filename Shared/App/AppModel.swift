import AlexaKit
import Foundation
import Observation

/// State for the main app screen: sign-in, device list, preferences.
@MainActor
@Observable
final class AppModel {
    let service: SendToAlexa

    private(set) var credentials: AlexaCredentials?
    private(set) var preferences = Preferences()
    private(set) var isBusy = false
    var errorMessage: String?

    /// Marketplace picked on the sign-in screen.
    var marketplace: AmazonRegion = AppEnvironment.suggestedMarketplace
    /// Non-nil while the Amazon sign-in sheet is showing.
    var pendingLogin: AmazonLoginRequest?

    init(service: SendToAlexa = AppEnvironment.service) {
        self.service = service
        reload()
    }

    var isSignedIn: Bool { credentials != nil }
    var devices: [EchoDevice] { preferences.cachedDevices }

    func reload() {
        credentials = service.store.loadCredentials()
        preferences = service.store.loadPreferences()
    }

    // MARK: Sign in / out

    func startSignIn() {
        errorMessage = nil
        pendingLogin = AmazonLoginRequest.forMarketplace(marketplace)
    }

    func finishSignIn(redirect: URL, cookies: [String: String]) async {
        guard let login = pendingLogin else { return }
        pendingLogin = nil
        isBusy = true
        defer { isBusy = false }
        do {
            try await service.completeSignIn(login, redirectURL: redirect, websiteCookies: cookies)
        } catch {
            errorMessage = error.localizedDescription
        }
        reload()
    }

    func signOut() async {
        isBusy = true
        defer { isBusy = false }
        await service.signOut()
        reload()
    }

    // MARK: Devices & preferences

    func refreshDevices() async {
        guard isSignedIn else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            try await service.refreshDevices()
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
        reload()
    }

    var defaultDeviceSerial: String? {
        get { preferences.defaultDeviceSerial }
        set { update { $0.defaultDeviceSerial = newValue } }
    }

    var provider: MusicProvider {
        get { preferences.provider }
        set { update { $0.provider = newValue } }
    }

    var playImmediately: Bool {
        get { preferences.playImmediately }
        set { update { $0.playImmediately = newValue } }
    }

    var retryOnMismatch: Bool {
        get { preferences.retryOnMismatch }
        set { update { $0.retryOnMismatch = newValue } }
    }

    private func update(_ change: (inout Preferences) -> Void) {
        do {
            try service.store.updatePreferences(change)
        } catch {
            errorMessage = error.localizedDescription
        }
        reload()
    }
}
