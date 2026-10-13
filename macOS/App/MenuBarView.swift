import AlexaKit
import SwiftUI

/// The menu bar icon (plus the song title while playing, if enabled).
struct MenuBarLabel: View {
    let model: MenuBarModel

    var body: some View {
        HStack(spacing: 4) {
            // Template image (adapts to light/dark menu bars), rendered by scripts/make-icon.swift --glyph.
            Image("MenuBarIcon")
                .renderingMode(.template)
                .opacity(model.player.isPlaying ? 1 : 0.85)
            if let title = model.menuBarTitle {
                Text(title)
            }
        }
    }
}

/// The window that drops down from the menu bar icon.
struct MenuBarContent: View {
    @Bindable var model: MenuBarModel
    @Environment(\.openWindow) private var openWindow

    private var player: PlayerModel { model.player }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if player.isSignedIn {
                HStack {
                    Text("Send to Alexa").font(.headline)
                    Spacer()
                    EchoPicker(player: player)
                }
                NowPlayingPanel(player: player)
                Divider()
                actions
            } else {
                signedOut
            }
            Divider()
            footer
        }
        .padding(14)
        .frame(width: 330)
        .onAppear { model.menuOpened() }
        .onDisappear { model.menuClosed() }
    }

    // MARK: Sections

    private var actions: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                model.playClipboard()
            } label: {
                Label(
                    model.clipboardHasMusicLink ? "Play copied Apple Music link" : "Play copied link or text",
                    systemImage: "doc.on.clipboard"
                )
            }
            .disabled(model.clipboardText == nil || player.isBusy || player.watchedDevice == nil)

            if let message = player.message {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .buttonStyle(.borderless)
    }

    private var signedOut: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Not signed in", systemImage: "person.crop.circle.badge.exclamationmark").font(.headline)
            Text("Sign in with the Amazon account your Echo devices use.")
                .font(.callout)
                .foregroundStyle(.secondary)
            Button("Open Send to Alexa…") { showMainWindow() }
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle("Show song in menu bar", isOn: $model.showTitleInMenuBar)
            Toggle("Launch at login", isOn: Binding(get: { model.launchAtLogin }, set: { model.setLaunchAtLogin($0) }))
            HStack {
                Button("Settings…") { showMainWindow() }
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
            }
            .buttonStyle(.borderless)
        }
        .toggleStyle(.checkbox)
        .font(.callout)
    }

    private func showMainWindow() {
        openWindow(id: "main")
        NSApp.activate()
    }
}
