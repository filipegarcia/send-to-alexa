import AlexaKit
import SwiftUI

/// Main app UI (iOS and macOS): sign in, pick your default Echo, set preferences, try a link.
struct ContentView: View {
    @State private var model = AppModel()
    @State private var player = PlayerModel()
    @State private var showingTrySheet = false
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        NavigationStack {
            Group {
                if model.isSignedIn {
                    signedIn
                } else {
                    signedOut
                }
            }
            .navigationTitle("Send to Alexa")
            .overlay {
                if model.isBusy && !model.isSignedIn {
                    ProgressView("Signing in…")
                        .padding()
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                }
            }
        }
        .sheet(item: $model.pendingLogin) { login in
            SignInSheet(login: login) { url, cookies in
                Task { await model.finishSignIn(redirect: url, cookies: cookies) }
            } onCancel: {
                model.pendingLogin = nil
            }
        }
        .sheet(isPresented: $showingTrySheet) {
            TryLinkSheet(service: model.service) {
                showingTrySheet = false
                model.reload()
            }
        }
        .task {
            await model.refreshDevices()
            player.reloadAccount()
        }
        // Poll what's playing only while the app is on screen.
        .onChange(of: scenePhase) { _, phase in
            if phase == .active, model.isSignedIn { player.activate() } else if phase != .active { player.startPolling(every: nil) }
        }
        .onChange(of: model.isSignedIn) { _, signedIn in
            if signedIn { player.activate() }
        }
    }

    // MARK: Signed out

    private var signedOut: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 12) {
                    Image(systemName: "hifispeaker.and.homepod.fill")
                        .font(.system(size: 44))
                        .foregroundStyle(.tint)
                    Text("Share a song from Apple Music and it starts playing on your Echo.")
                        .font(.headline)
                    Text("Sign in with the Amazon account your Echo devices use. You sign in on Amazon's own page; your password never touches this app.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 8)
            }

            Section {
                Picker("Alexa country", selection: $model.marketplace) {
                    ForEach(AmazonRegion.all) { region in
                        Text("\(region.name) (\(region.domain))").tag(region)
                    }
                }
                Button {
                    model.startSignIn()
                } label: {
                    Label("Sign in with Amazon", systemImage: "person.badge.key.fill")
                }
                .disabled(model.isBusy)
            } footer: {
                Text("Apple Music must be linked in the Alexa app (Settings › Music & Podcasts).")
            }

            if let error = model.errorMessage {
                Section { Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange) }
            }

            Section {
                Text("Not affiliated with Amazon or Apple. Uses the same private web API as the Alexa app, which Amazon may change at any time.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        #if os(macOS)
        .formStyle(.grouped)
        #endif
    }

    // MARK: Signed in

    private var signedIn: some View {
        Form {
            Section {
                NowPlayingPanel(player: player, artworkSize: 84)
                    .padding(.vertical, 6)
                if let message = player.message {
                    Text(message).font(.caption).foregroundStyle(.secondary)
                }
            } header: {
                HStack {
                    Text("Now playing")
                    Spacer()
                    EchoPicker(player: player)
                        .textCase(nil)
                }
            }
            .onAppear { player.activate() }
            .onDisappear { player.startPolling(every: nil) }

            Section {
                if model.devices.isEmpty {
                    Text(model.isBusy ? "Loading devices…" : "No music-capable Echo devices found.")
                        .foregroundStyle(.secondary)
                }
                ForEach(model.devices) { device in
                    DeviceRow(device: device, isSelected: device.serialNumber == model.defaultDeviceSerial)
                        .contentShape(Rectangle())
                        .onTapGesture { model.defaultDeviceSerial = device.serialNumber }
                        .contextMenu {
                            Button("Hide \(device.accountName)", systemImage: "eye.slash") { hide(device) }
                        }
                        #if os(iOS)
                        .swipeActions {
                            Button("Hide", systemImage: "eye.slash") { hide(device) }
                                .tint(.gray)
                        }
                        #endif
                }
            } header: {
                HStack {
                    Text("Default Echo")
                    Spacer()
                    Button {
                        Task { await model.refreshDevices() }
                    } label: {
                        if model.isBusy { ProgressView().controlSize(.small) } else { Image(systemName: "arrow.clockwise") }
                    }
                    .buttonStyle(.borderless)
                    .disabled(model.isBusy)
                }
            } footer: {
                #if os(iOS)
                Text("Preselected in the share sheet. Swipe left on an Echo to hide it from the share sheet and player.")
                #else
                Text("Preselected in the share sheet. Right-click an Echo to hide it from the share sheet and menu bar.")
                #endif
            }

            if !model.hiddenDevices.isEmpty {
                Section("Hidden") {
                    ForEach(model.hiddenDevices) { device in
                        HStack {
                            DeviceRow(device: device, isSelected: false).opacity(0.6)
                            Button("Show") {
                                model.setHidden(false, device)
                                player.reloadAccount()
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                }
            }

            Section {
                Picker("Music service", selection: $model.provider) {
                    ForEach(MusicProvider.allCases) { Text($0.displayName).tag($0) }
                }
                Toggle("Play immediately on the default Echo", isOn: $model.playImmediately)
                Toggle("Retry if Alexa picks a different song", isOn: $model.retryOnMismatch)
            } header: {
                Text("When sharing")
            } footer: {
                Text("Alexa can only search Apple Music by name. After playing, Send to Alexa checks what the Echo picked and, if it's a different song or version, tries a more specific search (up to 3 times).")
            }

            Section {
                Button {
                    showingTrySheet = true
                } label: {
                    Label("Send a link or search…", systemImage: "link")
                }
            } header: {
                Text("Try it")
            } footer: {
                Text("Or in Apple Music: ••• › Share › Send to Alexa. If it's missing, tap \"Edit Actions…\" / \"More\" at the end of the app row once to enable it.")
            }

            if let error = model.errorMessage {
                Section { Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange) }
            }

            Section("Amazon account") {
                if let creds = model.credentials {
                    LabeledContent("Signed in as", value: creds.customerName ?? "—")
                    LabeledContent("Marketplace", value: creds.marketplaceDomain)
                }
                Button("Sign out", role: .destructive) {
                    Task { await model.signOut() }
                }
            }
        }
        #if os(macOS)
        .formStyle(.grouped)
        #endif
    }
}

extension ContentView {
    private func hide(_ device: EchoDevice) {
        model.setHidden(true, device)
        player.reloadAccount()
    }
}

extension AmazonLoginRequest: @retroactive Identifiable {
    public var id: String { deviceSerial }
}

/// Wraps Amazon's sign-in page with a Cancel button.
struct SignInSheet: View {
    let login: AmazonLoginRequest
    let onRedirect: @MainActor (URL, [String: String]) -> Void
    let onCancel: () -> Void

    var body: some View {
        NavigationStack {
            AmazonSignInView(login: login, onRedirect: onRedirect)
                .ignoresSafeArea(edges: .bottom)
                .navigationTitle("Amazon sign-in")
                #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
                #endif
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel", action: onCancel)
                    }
                }
        }
        #if os(macOS)
        .frame(minWidth: 480, minHeight: 640)
        #endif
    }
}

/// Lets you paste an Apple Music link (or type a search) and run the same flow as the share sheet.
struct TryLinkSheet: View {
    let service: SendToAlexa
    let onClose: () -> Void
    @State private var text = ""
    @State private var shareModel: ShareModel?

    var body: some View {
        if let shareModel {
            ShareView(model: shareModel, onClose: onClose)
        } else {
            NavigationStack {
                Form {
                    Section {
                        TextField("https://music.apple.com/… or \"Bohemian Rhapsody by Queen\"", text: $text, axis: .vertical)
                            .lineLimit(1...4)
                            #if os(iOS)
                            .textInputAutocapitalization(.never)
                            .keyboardType(.webSearch)
                            #endif
                        PasteButton(payloadType: String.self) { strings in
                            if let first = strings.first { text = first }
                        }
                    } footer: {
                        Text("Apple Music links are turned into a search phrase like \"Song by Artist\".")
                    }
                }
                #if os(macOS)
                .formStyle(.grouped)
                #endif
                .navigationTitle("Send a link")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel", action: onClose) }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Next") {
                            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                            shareModel = ShareModel(service: service, sharedURL: nil, sharedText: trimmed)
                        }
                        .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
            }
            #if os(macOS)
            .frame(minWidth: 420, minHeight: 260)
            #endif
        }
    }
}
