import AlexaKit
import AppKit
import Observation
import ServiceManagement

/// State behind the menu bar item: what the watched Echo is playing, transport controls,
/// "play link from clipboard", and app preferences (menu bar title, launch at login).
@MainActor
@Observable
final class MenuBarModel {
    let service: SendToAlexa

    private(set) var isSignedIn = false
    private(set) var devices: [EchoDevice] = []
    /// Echo shown in the menu. Persisted; defaults to the app's default Echo.
    var watchedSerial: String? {
        didSet {
            UserDefaults.standard.set(watchedSerial, forKey: Keys.watched)
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
    /// Last known state of every Echo (filled when the menu opens).
    private(set) var statuses: [String: NowPlaying] = [:]
    private(set) var volume: Int?
    private(set) var message: String?
    private(set) var isBusy = false

    var showTitleInMenuBar: Bool {
        didSet {
            UserDefaults.standard.set(showTitleInMenuBar, forKey: Keys.showTitle)
            restartPolling()
        }
    }

    private(set) var launchAtLogin = SMAppService.mainApp.status == .enabled

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            message = "Couldn't change login item: \(error.localizedDescription)"
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    private var isMenuOpen = false
    private var pollTask: Task<Void, Never>?
    private var volumeTask: Task<Void, Never>?
    private var observers: [NSObjectProtocol] = []

    private enum Keys {
        static let watched = "watchedSerial"
        static let showTitle = "showTitleInMenuBar"
    }

    init(service: SendToAlexa = AppEnvironment.service) {
        self.service = service
        let defaults = UserDefaults.standard
        showTitleInMenuBar = defaults.object(forKey: Keys.showTitle) as? Bool ?? true
        watchedSerial = defaults.string(forKey: Keys.watched)
        reloadAccount()

        // The share extension (and the app itself) announce plays so the menu updates right away.
        observers.append(DistributedNotificationCenter.default().addObserver(
            forName: AppEnvironment.didPlayNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.reloadAccount()
                try? await Task.sleep(for: .seconds(1.5))
                await self?.refresh(includeVolume: false)
            }
        })
        restartPolling()
    }

    // MARK: Derived

    var watchedDevice: EchoDevice? {
        devices.first { $0.serialNumber == watchedSerial } ?? devices.first
    }

    var isPlaying: Bool { nowPlaying?.isPlaying == true }

    /// Short text for the menu bar (only while playing).
    var menuBarTitle: String? {
        guard showTitleInMenuBar, isPlaying, let playing = nowPlaying, !playing.summary.isEmpty else { return nil }
        let text = playing.summary
        return text.count > 34 ? String(text.prefix(33)) + "…" : text
    }

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
        devices = prefs.cachedDevices
        if watchedSerial == nil || !devices.contains(where: { $0.serialNumber == watchedSerial }) {
            watchedSerial = prefs.defaultDeviceSerial ?? devices.first?.serialNumber
        }
    }

    func menuOpened() {
        isMenuOpen = true
        message = nil
        reloadAccount()
        Task {
            await refreshAllDevices()
            await refresh(includeVolume: true)
        }
        restartPolling()
    }

    func menuClosed() {
        isMenuOpen = false
        restartPolling()
    }

    /// Fast polling while the menu is open; slow (only for the menu bar title) when closed.
    private func restartPolling() {
        pollTask?.cancel()
        let interval: Duration? = isMenuOpen ? .seconds(2) : (showTitleInMenuBar ? .seconds(30) : nil)
        guard let interval else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh(includeVolume: false)
                try? await Task.sleep(for: interval)
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
            message = "Amazon session expired — open Send to Alexa and sign in again."
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

    // MARK: Clipboard

    var clipboardText: String? {
        let pasteboard = NSPasteboard.general
        let text = pasteboard.string(forType: .URL) ?? pasteboard.string(forType: .string)
        let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let trimmed, !trimmed.isEmpty, trimmed.count < 500 else { return nil }
        return trimmed
    }

    var clipboardHasMusicLink: Bool {
        guard let text = clipboardText, let url = MusicLink.firstURL(in: text) else { return false }
        return MusicLink.parse(url) != nil
    }

    func playClipboard() {
        guard let text = clipboardText, let device = watchedDevice else { return }
        isBusy = true
        message = "Reading link…"
        Task {
            defer { isBusy = false }
            do {
                let music = try await service.resolver.resolve(url: nil, text: text)
                // The model lives as long as the app, so a strong capture is fine here.
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
