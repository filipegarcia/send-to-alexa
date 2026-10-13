import AlexaKit
import Foundation

// A tiny, dependency-free CLI around AlexaKit. Credentials live in ~/.config/send-to-alexa (0600),
// or $SEND_TO_ALEXA_HOME if set.

let usage = """
alexa-send — send Apple Music links (or any search) to an Echo.

USAGE
  alexa-send login [--region amazon.de] [--sign-in-domain amazon.com] [--no-open] [--redirect-url <url>]
  alexa-send status
  alexa-send devices [--all] [--json]
  alexa-send default <device name or serial>
  alexa-send provider <APPLE_MUSIC|AMAZON_MUSIC|SPOTIFY|DEEZER|TUNEIN|I_HEART_RADIO>
  alexa-send resolve <apple music url | text>
  alexa-send play [--device <name>] [--provider <id>] [--dry-run | --check] [--no-verify] [--no-retry] <url | phrase...>
  alexa-send now-playing [--device <name>]
  alexa-send speak [--device <name>] <text...>
  alexa-send providers
  alexa-send api <GET|POST|PUT> <path> [json-body]     (raw Alexa web API call, for exploring)
  alexa-send logout

EXAMPLES
  alexa-send login --region amazon.co.uk
  alexa-send play --device Kitchen "https://music.apple.com/gb/album/better-together/1440857781?i=1440857786"
  alexa-send play "Today's Hits playlist"

REGIONS
  \(AmazonRegion.all.map(\.domain).joined(separator: ", "))
"""

struct CLIError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

/// Minimal argument parsing: `--flag value`, `--switch`, and positionals.
struct Args {
    var positionals: [String] = []
    var options: [String: String] = [:]
    var switches: Set<String> = []

    init(_ raw: [String], switches knownSwitches: Set<String>) {
        var iterator = raw.makeIterator()
        while let arg = iterator.next() {
            if arg.hasPrefix("--") {
                let name = String(arg.dropFirst(2))
                if let eq = name.firstIndex(of: "=") {
                    options[String(name[..<eq])] = String(name[name.index(after: eq)...])
                } else if knownSwitches.contains(name) {
                    switches.insert(name)
                } else if let value = iterator.next() {
                    options[name] = value
                } else {
                    switches.insert(name)
                }
            } else {
                positionals.append(arg)
            }
        }
    }
}

let directory = FileStore.defaultDirectory()
let fileStore = FileStore(directory: directory)
let app = SendToAlexa(store: AlexaStore(fileStore))

func pendingLogin() -> AmazonLoginRequest? {
    guard let data = try? fileStore.read("pending-login") else { return nil }
    return try? JSONDecoder().decode(AmazonLoginRequest.self, from: data)
}

func savePendingLogin(_ login: AmazonLoginRequest?) throws {
    try fileStore.write(login.map { try JSONEncoder().encode($0) }, for: "pending-login")
}

func resolveDevice(_ name: String?) async throws -> EchoDevice {
    var prefs = app.store.loadPreferences()
    if prefs.cachedDevices.isEmpty {
        try await app.refreshDevices()
        prefs = app.store.loadPreferences()
    }
    if let name {
        if let device = EchoDevice.find(name, in: prefs.cachedDevices) { return device }
        // Maybe the list is stale.
        let fresh = try await app.refreshDevices()
        if let device = EchoDevice.find(name, in: fresh) { return device }
        throw AlexaError.deviceNotFound(name)
    }
    guard let device = prefs.defaultDevice ?? prefs.cachedDevices.first else {
        throw CLIError("No music-capable Echo devices found on this account.")
    }
    return device
}

func describe(_ device: EchoDevice, isDefault: Bool) -> String {
    let status = (device.online ?? true) ? "" : " (offline)"
    return "\(isDefault ? "*" : " ") \(device.accountName) — \(device.kindDescription)\(status)  [\(device.serialNumber)]"
}

func run() async throws {
    var arguments = Array(CommandLine.arguments.dropFirst())
    guard let command = arguments.first else {
        print(usage)
        return
    }
    arguments.removeFirst()
    let args = Args(arguments, switches: ["all", "json", "dry-run", "check", "help", "no-open", "no-verify", "no-retry"])
    if args.switches.contains("help") || command == "help" || command == "--help" || command == "-h" {
        print(usage)
        return
    }

    switch command {
    case "login":
        if let redirect = args.options["redirect-url"] ?? args.positionals.first {
            guard let login = pendingLogin() else {
                throw CLIError("No sign-in in progress. Run `alexa-send login` first.")
            }
            try await finishLogin(login, redirect: redirect)
            return
        }
        // --region is your Alexa marketplace (amazon.de, amazon.co.uk, ...). Sign-in itself goes through
        // amazon.com (or amazon.co.jp) unless --sign-in-domain says otherwise.
        let marketplace = AmazonRegion.forDomain(args.options["region"] ?? "amazon.com")
        let login = args.options["sign-in-domain"].map {
            AmazonLoginRequest(region: AmazonRegion.forDomain($0), marketplace: marketplace)
        } ?? AmazonLoginRequest.forMarketplace(marketplace)
        let region = login.region
        try savePendingLogin(login)
        print("""
        1. Sign in to Amazon (\(region.domain)) in your browser:

           \(login.url.absoluteString)

        2. After signing in you'll land on a page that looks broken ("Looking for something?").
           That's expected. Copy the FULL URL from the address bar (it contains /ap/maplanding).

        3. Paste it here and press Enter (or run: alexa-send login --redirect-url '<url>'):
        """)
        #if os(macOS)
        if !args.switches.contains("no-open") {
        let open = Process()
        open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        open.arguments = [login.url.absoluteString]
        try? open.run()
        }
        #endif
        print("> ", terminator: "")
        guard let line = readLine(), !line.trimmingCharacters(in: .whitespaces).isEmpty else {
            print("\nNo URL pasted. Finish later with: alexa-send login --redirect-url '<url>'")
            return
        }
        try await finishLogin(login, redirect: line)

    case "status":
        guard let creds = app.store.loadCredentials() else {
            print("Not signed in. Run `alexa-send login`.")
            return
        }
        let prefs = app.store.loadPreferences()
        print("Signed in\(creds.customerName.map { " as \($0)" } ?? "")")
        print("  Marketplace: \(creds.marketplaceDomain) (\(creds.locale)), registered via \(creds.loginDomain)")
        print("  Provider:    \(prefs.provider.displayName)")
        print("  Default:     \(prefs.defaultDevice?.accountName ?? "—")")
        print("  Data dir:    \(directory.path)")

    case "devices":
        let devices: [EchoDevice]
        if args.switches.contains("all") {
            devices = try await app.client().devices()
        } else {
            devices = try await app.refreshDevices()
        }
        if args.switches.contains("json") {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            print(String(decoding: try encoder.encode(devices), as: UTF8.self))
        } else {
            let defaultSerial = app.store.loadPreferences().defaultDeviceSerial
            devices.forEach { print(describe($0, isDefault: $0.serialNumber == defaultSerial)) }
            if devices.isEmpty { print("No devices found.") }
        }

    case "default":
        guard let name = args.positionals.first else { throw CLIError("Usage: alexa-send default <device>") }
        let device = try await resolveDevice(name)
        try app.store.updatePreferences { $0.defaultDeviceSerial = device.serialNumber }
        print("Default device: \(device.accountName)")

    case "provider":
        guard let raw = args.positionals.first, let provider = MusicProvider(rawValue: raw.uppercased()) else {
            throw CLIError("Usage: alexa-send provider <\(MusicProvider.allCases.map(\.rawValue).joined(separator: "|"))>")
        }
        try app.store.updatePreferences { $0.provider = provider }
        print("Provider: \(provider.displayName)")

    case "resolve":
        let input = args.positionals.joined(separator: " ")
        guard !input.isEmpty else { throw CLIError("Usage: alexa-send resolve <url | text>") }
        let music = try await app.resolver.resolve(url: nil, text: input)
        print("Kind:   \(music.kind.rawValue)")
        print("Title:  \(music.title)")
        if let artist = music.artist { print("Artist: \(artist)") }
        print("Phrase: \(music.searchPhrase)")
        let alternatives = music.searchCandidates.dropFirst()
        if !alternatives.isEmpty { print("Retries: \(alternatives.map { "“\($0)”" }.joined(separator: ", "))") }

    case "play":
        let input = args.positionals.joined(separator: " ")
        guard !input.isEmpty else { throw CLIError("Usage: alexa-send play [--device <name>] <url | phrase>") }
        let music = try await app.resolver.resolve(url: nil, text: input)
        let provider = try args.options["provider"].map { raw -> MusicProvider in
            guard let p = MusicProvider(rawValue: raw.uppercased()) else { throw CLIError("Unknown provider \(raw)") }
            return p
        }
        if args.switches.contains("dry-run") {
            print("Would ask Alexa to play \"\(music.searchPhrase)\" on \(provider?.displayName ?? app.store.loadPreferences().provider.displayName)")
            return
        }
        let device = try await resolveDevice(args.options["device"])
        if args.switches.contains("check") {
            // Ask Alexa to validate the request without playing anything.
            let sanitized = try await app.client().checkPlay(
                music.searchPhrase, provider: provider ?? app.store.loadPreferences().provider, on: device
            )
            print("✓ Alexa accepts \"\(music.searchPhrase)\" for \(device.accountName) (searches: \"\(sanitized)\"). Nothing was played.")
            return
        }
        if args.switches.contains("no-verify") {
            let sanitized = try await app.play(music.searchPhrase, on: device, provider: provider)
            print("▶︎ \(device.accountName): \(music.searchPhrase)\(sanitized != music.searchPhrase ? "  (Alexa: \"\(sanitized)\")" : "")")
            return
        }
        let result = try await app.playVerified(
            music, on: device, provider: provider, retry: args.switches.contains("no-retry") ? false : nil
        ) { message in print("  … \(message)") }
        let playing = result.nowPlaying?.summary ?? music.searchPhrase
        switch result.verdict {
        case .matched:
            print("✅ \(device.accountName) is playing \(playing)\(result.attempts > 1 ? "  (needed \(result.attempts) tries)" : "")")
        case .unverified:
            print("▶︎ \(device.accountName): \(playing)  (couldn't verify it's the exact item)")
        case .mismatched:
            let expected = [music.title, music.artist].compactMap { $0 }.joined(separator: " — ")
            print("⚠️  \(device.accountName) is playing \(playing), not \(expected) (tried \(result.attempts) phrasing\(result.attempts == 1 ? "" : "s")).")
            print("   Try a more specific search, e.g.: alexa-send play --device \"\(device.accountName)\" \"\(music.searchPhrase) <album or year>\"")
            exit(2)
        case .notStarted:
            print("⚠️  Nothing started on \(device.accountName) — Alexa found no match for: \(music.searchCandidates.prefix(3).map { "“\($0)”" }.joined(separator: ", ")).")
            exit(3)
        }

    case "now-playing":
        let device = try await resolveDevice(args.options["device"])
        if let playing = try await app.client().nowPlaying(on: device) {
            print("\(device.accountName): \(playing.state ?? "?") — \(playing.summary)\(playing.provider.map { " [\($0)]" } ?? "")")
        } else {
            print("\(device.accountName): nothing playing")
        }

    case "speak":
        let text = args.positionals.joined(separator: " ")
        guard !text.isEmpty else { throw CLIError("Usage: alexa-send speak [--device <name>] <text>") }
        let device = try await resolveDevice(args.options["device"])
        try await app.client().speak(text, on: device)
        print("🗣 \(device.accountName): \(text)")

    case "providers":
        let data = try await app.client().musicProvidersJSON()
        print(String(decoding: data, as: UTF8.self))

    case "api":
        guard args.positionals.count >= 2 else { throw CLIError("Usage: alexa-send api <METHOD> <path> [json-body]") }
        let method = args.positionals[0].uppercased()
        var path = args.positionals[1]
        if let device = args.options["device"] {
            // Convenience: --device fills in {serial} and {type} placeholders.
            let d = try await resolveDevice(device)
            path = path.replacingOccurrences(of: "{serial}", with: d.serialNumber)
                .replacingOccurrences(of: "{type}", with: d.deviceType)
                .replacingOccurrences(of: "{customer}", with: d.deviceOwnerCustomerId)
        }
        let body = args.positionals.count > 2 ? Data(args.positionals[2].utf8) : nil
        let data = try await app.client().rawRequest(method, path, jsonBody: body)
        if let object = try? JSONSerialization.jsonObject(with: data),
           let pretty = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]) {
            print(String(decoding: pretty, as: UTF8.self))
        } else {
            print(String(decoding: data, as: UTF8.self))
        }

    case "logout":
        await app.signOut()
        try? savePendingLogin(nil)
        print("Signed out and removed local data.")

    default:
        throw CLIError("Unknown command \"\(command)\".\n\n\(usage)")
    }
}

func finishLogin(_ login: AmazonLoginRequest, redirect: String) async throws {
    let trimmed = redirect.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "'\"")))
    guard let url = URL(string: trimmed) else { throw CLIError("That doesn't look like a URL.") }
    let devices = try await app.completeSignIn(login, redirectURL: url)
    try savePendingLogin(nil)
    let creds = app.store.loadCredentials()
    print("✅ Signed in\(creds?.customerName.map { " as \($0)" } ?? "") — marketplace \(creds?.marketplaceDomain ?? "?")")
    let defaultSerial = app.store.loadPreferences().defaultDeviceSerial
    devices.forEach { print(describe($0, isDefault: $0.serialNumber == defaultSerial)) }
}

do {
    try await run()
} catch {
    FileHandle.standardError.write(Data("error: \(error.localizedDescription)\n".utf8))
    exit(1)
}
