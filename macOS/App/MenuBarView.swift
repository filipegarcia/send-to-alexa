import AlexaKit
import SwiftUI

/// The menu bar icon (plus the song title while playing, if enabled).
struct MenuBarLabel: View {
    let model: MenuBarModel

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: model.isPlaying ? "hifispeaker.fill" : "hifispeaker")
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

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if model.isSignedIn {
                header
                MenuNowPlayingCard(model: model)
                controls
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

    private var header: some View {
        HStack {
            Text("Send to Alexa").font(.headline)
            Spacer()
            Menu {
                ForEach(model.devices) { device in
                    Button {
                        model.watchedSerial = device.serialNumber
                    } label: {
                        let state = model.statuses[device.serialNumber]
                        Text("\(device.accountName)\(state?.isPlaying == true ? "  ▶︎" : state?.isPaused == true ? "  ❚❚" : "")")
                    }
                }
            } label: {
                Label(model.watchedDevice?.accountName ?? "Choose Echo", systemImage: model.watchedDevice?.symbolName ?? "hifispeaker")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
    }

    private var controls: some View {
        VStack(spacing: 8) {
            HStack(spacing: 22) {
                Spacer()
                Button { model.perform(.previous) } label: { Image(systemName: "backward.fill") }
                Button { model.togglePlayPause() } label: {
                    Image(systemName: model.isPlaying ? "pause.fill" : "play.fill").font(.title2)
                }
                Button { model.perform(.next) } label: { Image(systemName: "forward.fill") }
                Spacer()
            }
            .buttonStyle(.borderless)
            .font(.title3)
            .disabled(model.nowPlaying == nil)

            HStack(spacing: 6) {
                Image(systemName: "speaker.fill").font(.caption).foregroundStyle(.secondary)
                Slider(
                    value: Binding(
                        get: { Double(model.volume ?? 0) },
                        set: { model.setVolume(Int($0.rounded())) }
                    ),
                    in: 0...100
                )
                .controlSize(.small)
                .disabled(model.volume == nil)
                Image(systemName: "speaker.wave.3.fill").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

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
            .disabled(model.clipboardText == nil || model.isBusy || model.watchedDevice == nil)

            if let message = model.message {
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

/// Artwork, title, artist and a progress bar that ticks between polls.
struct MenuNowPlayingCard: View {
    let model: MenuBarModel

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            AsyncImage(url: model.nowPlaying?.artworkURL) { image in
                image.resizable().scaledToFill()
            } placeholder: {
                ZStack {
                    RoundedRectangle(cornerRadius: 8).fill(.quaternary)
                    Image(systemName: "music.note").font(.title2).foregroundStyle(.secondary)
                }
            }
            .frame(width: 72, height: 72)
            .clipShape(RoundedRectangle(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 3) {
                if let playing = model.nowPlaying, let title = playing.title, !title.isEmpty {
                    Text(title).font(.headline).lineLimit(2)
                    if let subtitle = playing.subtitle {
                        Text(subtitle).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Text([playing.provider, stateLabel(playing)].compactMap { $0 }.joined(separator: " · "))
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                } else {
                    Text("Nothing playing").font(.headline)
                    Text("on \(model.watchedDevice?.accountName ?? "your Echo")").foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            Spacer(minLength: 0)
        }
        .frame(height: 72)
        .overlay(alignment: .bottom) { EmptyView() }

        TimelineView(.periodic(from: .now, by: 1)) { context in
            if let progress = model.progress(at: context.date) {
                VStack(spacing: 2) {
                    ProgressView(value: Double(progress.elapsed), total: Double(progress.total))
                        .progressViewStyle(.linear)
                        .tint(.accentColor)
                    HStack {
                        Text(Self.time(progress.elapsed))
                        Spacer()
                        Text("-" + Self.time(progress.total - progress.elapsed))
                    }
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func stateLabel(_ playing: NowPlaying) -> String? {
        switch playing.state {
        case "PLAYING": return nil
        case "PAUSED": return "Paused"
        case "IDLE": return "Stopped"
        case let other?: return other.capitalized
        case nil: return nil
        }
    }

    static func time(_ seconds: Int) -> String {
        String(format: "%d:%02d", max(0, seconds) / 60, max(0, seconds) % 60)
    }
}
