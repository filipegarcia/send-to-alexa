import AlexaKit
import AppKit
import Observation
import ServiceManagement

/// Mac-only state around the shared `PlayerModel`: menu bar title, launch at login, clipboard,
/// and refreshing when the Share extension plays something.
@MainActor
@Observable
final class MenuBarModel {
    let player: PlayerModel

    var showTitleInMenuBar: Bool {
        didSet {
            UserDefaults.standard.set(showTitleInMenuBar, forKey: Keys.showTitle)
            updatePolling()
        }
    }

    private(set) var launchAtLogin = SMAppService.mainApp.status == .enabled
    private var isMenuOpen = false
    private var observers: [NSObjectProtocol] = []

    private enum Keys {
        static let showTitle = "showTitleInMenuBar"
    }

    init(player: PlayerModel = PlayerModel()) {
        self.player = player
        showTitleInMenuBar = UserDefaults.standard.object(forKey: Keys.showTitle) as? Bool ?? true

        // The share extension (and the app itself) announce plays so the menu updates right away.
        observers.append(DistributedNotificationCenter.default().addObserver(
            forName: AppEnvironment.didPlayNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.player.reloadAccount()
                try? await Task.sleep(for: .seconds(1.5))
                await self?.player.refresh(includeVolume: false)
            }
        })
        updatePolling()
        Task { await player.refresh(includeVolume: false) }
    }

    /// Short text for the menu bar (only while playing).
    var menuBarTitle: String? {
        guard showTitleInMenuBar, player.isPlaying, let playing = player.nowPlaying, !playing.summary.isEmpty else { return nil }
        let text = playing.summary
        return text.count > 34 ? String(text.prefix(33)) + "…" : text
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            player.message = "Couldn't change login item: \(error.localizedDescription)"
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    // MARK: Menu lifecycle

    func menuOpened() {
        isMenuOpen = true
        player.message = nil
        player.activate(polling: .seconds(2))
    }

    func menuClosed() {
        isMenuOpen = false
        updatePolling()
    }

    /// Fast polling while the menu is open; slow (only for the menu bar title) when closed.
    private func updatePolling() {
        player.startPolling(every: isMenuOpen ? .seconds(2) : (showTitleInMenuBar ? .seconds(30) : nil))
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
        guard let text = clipboardText else { return }
        player.play(text: text)
    }
}
