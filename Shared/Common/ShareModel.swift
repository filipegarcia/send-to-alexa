import AlexaKit
import Foundation
import Observation

/// State for the "send this to an Echo" sheet. Used by the share extensions and by the app's "Paste link" screen.
@MainActor
@Observable
final class ShareModel {
    enum Phase: Equatable {
        case resolving
        case ready
        case sending
        case sent(device: String)
        case failed(String)
        case notSignedIn
    }

    private(set) var phase: Phase = .resolving
    private(set) var music: ResolvedMusic?
    var phrase: String = ""
    private(set) var devices: [EchoDevice] = []
    var selectedSerial: String?
    var provider: MusicProvider = .appleMusic {
        didSet { try? service.store.updatePreferences { $0.provider = provider } }
    }
    private(set) var isRefreshingDevices = false

    let service: SendToAlexa
    private let sharedURL: URL?
    private let sharedText: String?

    init(service: SendToAlexa, sharedURL: URL?, sharedText: String?) {
        self.service = service
        self.sharedURL = sharedURL
        self.sharedText = sharedText
    }

    var selectedDevice: EchoDevice? {
        devices.first { $0.serialNumber == selectedSerial }
    }

    var canSend: Bool {
        selectedDevice != nil
            && !phrase.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && phase != .sending
            && phase != .resolving
    }

    func start() async {
        guard service.isSignedIn else {
            phase = .notSignedIn
            return
        }
        let prefs = service.store.loadPreferences()
        devices = prefs.cachedDevices
        selectedSerial = prefs.defaultDeviceSerial ?? devices.first?.serialNumber
        provider = prefs.provider

        // Resolve the link and refresh the device list in parallel.
        async let refresh: Void = refreshDevices()
        do {
            let resolved = try await service.resolver.resolve(url: sharedURL, text: sharedText)
            music = resolved
            phrase = resolved.searchPhrase
            phase = .ready
        } catch {
            phrase = sharedText ?? ""
            phase = phrase.isEmpty ? .failed(error.localizedDescription) : .ready
        }
        await refresh

        if prefs.playImmediately, phase == .ready, selectedDevice != nil {
            await send()
        }
    }

    func refreshDevices() async {
        isRefreshingDevices = true
        defer { isRefreshingDevices = false }
        do {
            devices = try await service.refreshDevices()
            if selectedDevice == nil {
                selectedSerial = service.store.loadPreferences().defaultDeviceSerial ?? devices.first?.serialNumber
            }
        } catch AlexaError.sessionExpired {
            phase = .failed(AlexaError.sessionExpired.localizedDescription)
        } catch {
            // Keep the cached list; the user can still try to play.
        }
    }

    func send() async {
        guard let device = selectedDevice else { return }
        phase = .sending
        do {
            try await service.play(phrase, on: device, provider: provider)
            phase = .sent(device: device.accountName)
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    /// Lets the user retry after an error without losing their edits.
    func dismissError() {
        if case .failed = phase { phase = .ready }
    }
}
