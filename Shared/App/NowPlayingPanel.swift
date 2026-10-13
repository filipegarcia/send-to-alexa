import AlexaKit
import SwiftUI

/// Echo picker for the player (shows ▶︎ / ❚❚ next to Echos that are playing / paused).
struct EchoPicker: View {
    let player: PlayerModel

    var body: some View {
        Menu {
            ForEach(player.devices) { device in
                Button {
                    player.watchedSerial = device.serialNumber
                } label: {
                    let state = player.statuses[device.serialNumber]
                    Text("\(device.accountName)\(state?.isPlaying == true ? "  ▶︎" : state?.isPaused == true ? "  ❚❚" : "")")
                }
            }
        } label: {
            Label(player.watchedDevice?.accountName ?? "Choose Echo", systemImage: player.watchedDevice?.symbolName ?? "hifispeaker")
        }
        #if os(macOS)
        .menuStyle(.borderlessButton)
        #endif
        .fixedSize()
    }
}

/// Artwork, title/artist, ticking progress bar, transport controls and volume — the "now playing" panel
/// used by the Mac menu bar and the iPhone app.
struct NowPlayingPanel: View {
    let player: PlayerModel
    var artworkSize: CGFloat = 72

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            card
            progress
            controls
        }
    }

    private var card: some View {
        HStack(alignment: .top, spacing: 12) {
            AsyncImage(url: player.nowPlaying?.artworkURL) { image in
                image.resizable().scaledToFill()
            } placeholder: {
                ZStack {
                    RoundedRectangle(cornerRadius: 8).fill(.quaternary)
                    Image(systemName: "music.note").font(.title2).foregroundStyle(.secondary)
                }
            }
            .frame(width: artworkSize, height: artworkSize)
            .clipShape(RoundedRectangle(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 3) {
                if let playing = player.nowPlaying, let title = playing.title, !title.isEmpty {
                    Text(title).font(.headline).lineLimit(2)
                    if let subtitle = playing.subtitle {
                        Text(subtitle).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Text([playing.provider, stateLabel(playing)].compactMap { $0 }.joined(separator: " · "))
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                } else {
                    Text("Nothing playing").font(.headline)
                    Text("on \(player.watchedDevice?.accountName ?? "your Echo")").foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            Spacer(minLength: 0)
        }
        .frame(height: artworkSize)
    }

    private var progress: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            if let progress = player.progress(at: context.date) {
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

    private var controls: some View {
        VStack(spacing: 10) {
            HStack(spacing: 28) {
                Spacer()
                Button { player.perform(.previous) } label: { Image(systemName: "backward.fill") }
                Button { player.togglePlayPause() } label: {
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill").font(.title2)
                }
                Button { player.perform(.next) } label: { Image(systemName: "forward.fill") }
                Spacer()
            }
            .buttonStyle(.borderless)
            .font(.title3)
            .disabled(player.nowPlaying == nil)

            HStack(spacing: 6) {
                Image(systemName: "speaker.fill").font(.caption).foregroundStyle(.secondary)
                Slider(
                    value: Binding(
                        get: { Double(player.volume ?? 0) },
                        set: { player.setVolume(Int($0.rounded())) }
                    ),
                    in: 0...100
                )
                .controlSize(.small)
                .disabled(player.volume == nil)
                Image(systemName: "speaker.wave.3.fill").font(.caption).foregroundStyle(.secondary)
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
