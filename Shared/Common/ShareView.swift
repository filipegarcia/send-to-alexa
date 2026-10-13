import AlexaKit
import SwiftUI

/// The sheet shown from the system Share menu: what will be played, where, and a big Play button.
struct ShareView: View {
    @Bindable var model: ShareModel
    var onClose: () -> Void

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Send to Alexa")
                #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
                #endif
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel", action: onClose)
                    }
                }
        }
        .task { await model.start() }
        .onChange(of: model.phase) { _, phase in
            if case .sent = phase {
                Task {
                    try? await Task.sleep(for: .seconds(1.2))
                    onClose()
                }
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .notSignedIn:
            ContentUnavailableView {
                Label("Not signed in", systemImage: "person.crop.circle.badge.exclamationmark")
            } description: {
                Text("Open the Send to Alexa app once and sign in with your Amazon account.")
            }
        case .sent(let device):
            ContentUnavailableView {
                Label("Playing on \(device)", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            } description: {
                Text(model.phrase)
            }
        default:
            form
        }
    }

    private var form: some View {
        Form {
            Section {
                NowPlayingCard(music: model.music, isLoading: model.phase == .resolving)
            }

            Section {
                TextField("Song, album, artist or playlist", text: $model.phrase, axis: .vertical)
                    .lineLimit(1...3)
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    #endif
                Picker("Service", selection: $model.provider) {
                    ForEach(MusicProvider.allCases) { Text($0.displayName).tag($0) }
                }
            } header: {
                Text("Alexa will search for")
            } footer: {
                Text("Edit the phrase if Alexa picks the wrong version.")
            }

            Section {
                if model.devices.isEmpty {
                    HStack {
                        ProgressView()
                        Text("Looking for your Echo devices…").foregroundStyle(.secondary)
                    }
                }
                ForEach(model.devices) { device in
                    DeviceRow(device: device, isSelected: device.serialNumber == model.selectedSerial)
                        .contentShape(Rectangle())
                        .onTapGesture { model.selectedSerial = device.serialNumber }
                }
            } header: {
                HStack {
                    Text("Play on")
                    Spacer()
                    if model.isRefreshingDevices { ProgressView().controlSize(.small) }
                }
            }

            if case .failed(let message) = model.phase {
                Section {
                    Label(message, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Button("Try again") { model.dismissError() }
                }
            }
        }
        #if os(macOS)
        .formStyle(.grouped)
        #endif
        .safeAreaInset(edge: .bottom) {
            Button {
                Task { await model.send() }
            } label: {
                HStack {
                    if model.phase == .sending {
                        ProgressView().tint(.white)
                    } else {
                        Image(systemName: "play.fill")
                    }
                    Text(model.selectedDevice.map { "Play on \($0.accountName)" } ?? "Choose an Echo")
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(!model.canSend)
            .keyboardShortcut(.defaultAction)
            .padding()
            .background(.bar)
        }
    }
}

struct NowPlayingCard: View {
    let music: ResolvedMusic?
    let isLoading: Bool

    var body: some View {
        HStack(spacing: 14) {
            AsyncImage(url: music?.artworkURL) { image in
                image.resizable().scaledToFill()
            } placeholder: {
                ZStack {
                    Rectangle().fill(.quaternary)
                    Image(systemName: "music.note").font(.title2).foregroundStyle(.secondary)
                }
            }
            .frame(width: 64, height: 64)
            .clipShape(RoundedRectangle(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 3) {
                if isLoading {
                    Text("Reading link…").foregroundStyle(.secondary)
                } else {
                    Text(music?.title ?? "Shared item").font(.headline).lineLimit(2)
                    if let artist = music?.artist {
                        Text(artist).foregroundStyle(.secondary).lineLimit(1)
                    }
                    if let kind = music?.kind, kind != .unknown {
                        Text(kind.label).font(.caption).foregroundStyle(.tertiary)
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
    }
}

struct DeviceRow: View {
    let device: EchoDevice
    let isSelected: Bool

    var body: some View {
        HStack {
            Image(systemName: device.symbolName)
                .frame(width: 28)
                .foregroundStyle(.tint)
            VStack(alignment: .leading) {
                Text(device.accountName)
                Text(device.online == false ? "\(device.kindDescription) · offline" : device.kindDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if isSelected {
                Image(systemName: "checkmark").foregroundStyle(.tint).fontWeight(.semibold)
            }
        }
        .opacity(device.online == false ? 0.6 : 1)
    }
}

extension EchoDevice {
    var symbolName: String {
        switch deviceFamily {
        case "WHA": return "hifispeaker.2.fill"
        case "KNIGHT", "ROOK": return "rectangle.on.rectangle"
        case "FIRE_TV": return "tv"
        case "TABLET": return "ipad.landscape"
        default: return "hifispeaker.fill"
        }
    }
}

extension MusicItemKind {
    var label: String {
        switch self {
        case .song: return "Song"
        case .album: return "Album"
        case .artist: return "Artist"
        case .playlist: return "Playlist"
        case .station: return "Radio station"
        case .musicVideo: return "Music video"
        case .unknown: return ""
        }
    }
}
