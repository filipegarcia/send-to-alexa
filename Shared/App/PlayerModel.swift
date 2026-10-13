import AlexaKit
import Foundation
import Observation

/// What the watched Echo is playing + transport controls. Shared by the iPhone app and the Mac menu bar.
@MainActor
@Observable
final class PlayerModel {
    let service: SendToAlexa

    private(set) var isSignedIn = false
    /// Visible (not hidden) music devices.
    private(set) var devices: [EchoDevice] = []
    /// Echo being shown. Persisted; defaults to the app's default Echo.
    var watchedSerial: String? {
        didSet {
            UserDefaults.standard.set(watchedSerial, forKey: Self.watchedKey)
            if oldValue != watchedSerial {
                nowPlaying = statuses[watchedSerial ?? ""]
                volume = nil
                Task { await refresh(includeVolume: true) }
            }
        }
    }
    private(set) var nowPlaying: NowPlaying?
    /// When `nowPlaying` was fetched — used to tick the progress bar between polls.
    private(set) var fetchedAt = Date()
    /// Last known state of every Echo.
    private(set) var statuses: [String: NowPlaying] = [:]
    private(set) var volume: Int?
    var message: String?
    private(set) var isBusy = false

    private var pollTask: Task<Void, Never>?
    private var volumeTask: Task<Void, Never>?
    private static let watchedKey = "watchedSerial"

    init(service: SendToAlexa = AppEnvironment.service) {
        self.service = service
        watchedSerial = UserDefaults.standard.string(forKey: Self.watchedKey)
        reloadAccount()
    }

    // MARK: Derived

    var watchedDevice: EchoDevice? {
        devices.first { $0.serialNumber == watchedSerial } ?? devices.first
    }

    var isPlaying: Bool { nowPlaying?.isPlaying == true }

    /// Progress including the time elapsed since the last poll, while playing.
    func progress(at date: Date) -> (elapsed: Int, total: Int)? {
        guard let playing = nowPlaying, let total = playing.lengthSeconds, total > 0 else { return nil }
        var elapsed = playing.progressSeconds ?? 0
        if playing.isPlaying { elapsed += Int(date.timeIntervalSince(fetchedAt)) }
        return (min(elapsed, total), total)
    }

    // MARK: Lifecycle

    func reloadAccount() {
        isSignedIn = service.isSignedIn
        let prefs = service.store.loadPreferences()
        devices = prefs.visibleDevices
        if watchedSerial == nil || !devices.contains(where: { $0.serialNumber == watchedSerial }) {
            watchedSerial = prefs.defaultDeviceSerial ?? devices.first?.serialNumber
        }
    }

    /// Call when the player becomes visible: checks every Echo, then polls the watched one every `interval`.
    func activate(polling interval: Duration = .seconds(2)) {
        reloadAccount()
        Task {
            await refreshAllDevices()
            await refresh(includeVolume: true)
        }
        startPolling(every: interval)
    }

    /// Starts (or changes) background polling of the watched Echo; nil stops it.
    func startPolling(every interval: Duration?) {
        pollTask?.cancel()
        guard let interval else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                await self?.refresh(includeVolume: false)
            }
        }
    }

    // MARK: Refresh

    func refresh(includeVolume: Bool) async {
        guard service.isSignedIn, let device = watchedDevice, let client = try? service.client() else { return }
        do {
            let playing = try await client.nowPlaying(on: device)
            nowPlaying = playing
            fetchedAt = Date()
            statuses[device.serialNumber] = playing
            if includeVolume, let level = try? await client.volume(on: device) { volume = level }
        } catch AlexaError.sessionExpired {
            message = "Amazon session expired — sign in again in Settings."
        } catch {
            // Network hiccups: keep the last state.
        }
    }

    /// Checks every Echo and, if the watched one is idle but another is playing, follows the playing one.
    func refreshAllDevices() async {
        guard service.isSignedIn, let client = try? service.client() else { return }
        if devices.isEmpty { _ = try? await service.refreshDevices(); reloadAccount() }
        statuses = await client.nowPlaying(on: devices)
        if let watched = watchedSerial, statuses[watched]?.isPlaying != true,
           let playing = devices.first(where: { statuses[$0.serialNumber]?.isPlaying == true }) {
            watchedSerial = playing.serialNumber
        }
        nowPlaying = statuses[watchedSerial ?? ""]
        fetchedAt = Date()
    }

    // MARK: Controls

    func perform(_ command: PlayerCommand) {
        guard let device = watchedDevice, let client = try? service.client() else { return }
        // Optimistic UI for play/pause.
        if command == .pause { nowPlaying?.state = "PAUSED" }
        if command == .play { nowPlaying?.state = "PLAYING"; fetchedAt = Date() }
        Task {
            do {
                try await client.send(command, to: device)
                try? await Task.sleep(for: .milliseconds(700))
                await refresh(includeVolume: false)
            } catch {
                message = error.localizedDescription
            }
        }
    }

    func togglePlayPause() {
        perform(isPlaying ? .pause : .play)
    }

    /// Debounced so dragging the slider sends one request.
    func setVolume(_ level: Int) {
        volume = level
        volumeTask?.cancel()
        guard let device = watchedDevice, let client = try? service.client() else { return }
        volumeTask = Task {
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            try? await client.send(.volume(level), to: device)
        }
    }

    // MARK: Play text / links

    /// Resolves `text` (Apple Music link or a search) and plays it on the watched Echo, with verification.
    func play(text: String) {
        guard let device = watchedDevice else { return }
        isBusy = true
        message = "Reading link…"
        Task {
            defer { isBusy = false }
            do {
                let music = try await service.resolver.resolve(url: nil, text: text)
                // The model lives as long as its screen; a strong capture is fine here.
                let result = try await service.playVerified(music, on: device) { status in
                    Task { @MainActor in self.message = status }
                }
                switch result.verdict {
                case .matched, .unverified:
                    message = "▶︎ \(result.nowPlaying?.summary ?? music.searchPhrase)"
                case .mismatched:
                    message = "Alexa picked “\(result.nowPlaying?.summary ?? "something else")” instead."
                case .notStarted:
                    message = "Alexa couldn't find “\(music.searchPhrase)”."
                }
                await refresh(includeVolume: false)
            } catch {
                message = error.localizedDescription
            }
        }
    }
}
