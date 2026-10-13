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
  alexa-send play [--device <name>] [--provider <id>] [--dry-run] <apple music url | search phrase...>
  alexa-send speak [--device <name>] <text...>
  alexa-send providers
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
    let args = Args(arguments, switches: ["all", "json", "dry-run", "help", "no-open"])
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
        let sanitized = try await app.play(music.searchPhrase, on: device, provider: provider)
        print("▶︎ \(device.accountName): \(music.searchPhrase)\(sanitized != music.searchPhrase ? "  (Alexa: \"\(sanitized)\")" : "")")

    case "speak":
        let text = args.positionals.joined(separator: " ")
        guard !text.isEmpty else { throw CLIError("Usage: alexa-send speak [--device <name>] <text>") }
        let device = try await resolveDevice(args.options["device"])
        try await app.client().speak(text, on: device)
        print("🗣 \(device.accountName): \(text)")

    case "providers":
        let data = try await app.client().musicProvidersJSON()
        print(String(decoding: data, as: UTF8.self))

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
