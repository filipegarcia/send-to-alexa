import Foundation

/// An Alexa endpoint from `GET /api/devices-v2/device` (Echo speaker, Echo Show, Fire TV, speaker group, ...).
public struct EchoDevice: Codable, Hashable, Sendable, Identifiable {
    /// The name shown in the Alexa app, e.g. "Kitchen Echo".
    public let accountName: String
    public let serialNumber: String
    public let deviceType: String
    public let deviceFamily: String?
    public let deviceOwnerCustomerId: String
    public let online: Bool?
    public let capabilities: [String]?

    public var id: String { serialNumber }

    public init(
        accountName: String,
        serialNumber: String,
        deviceType: String,
        deviceFamily: String? = nil,
        deviceOwnerCustomerId: String,
        online: Bool? = true,
        capabilities: [String]? = ["AUDIO_PLAYER"]
    ) {
        self.accountName = accountName
        self.serialNumber = serialNumber
        self.deviceType = deviceType
        self.deviceFamily = deviceFamily
        self.deviceOwnerCustomerId = deviceOwnerCustomerId
        self.online = online
        self.capabilities = capabilities
    }

    /// Multi-room speaker groups ("Everywhere", "Downstairs", ...).
    public var isSpeakerGroup: Bool { deviceFamily == "WHA" }

    /// Whether this endpoint can play music (speakers, Shows, Fire TVs, groups).
    public var canPlayMusic: Bool {
        if isSpeakerGroup { return true }
        if deviceFamily == "VOX" { return false } // Alexa app instances on phones
        if deviceType == AlexaAppIdentity.deviceType { return false }
        let caps = Set(capabilities ?? [])
        return caps.contains("AUDIO_PLAYER") || caps.contains("AMAZON_MUSIC") || deviceFamily == "FIRE_TV"
    }

    /// Short, human readable kind for UI subtitles.
    public var kindDescription: String {
        switch deviceFamily {
        case "WHA": return "Speaker group"
        case "ECHO": return "Echo"
        case "KNIGHT": return "Echo Show"
        case "ROOK": return "Echo Show"
        case "FIRE_TV": return "Fire TV"
        case "TABLET": return "Fire tablet"
        case "THIRD_PARTY_AVS_SONOS_BOOTLEG", "THIRD_PARTY_AVS_MEDIA_DISPLAY": return "Alexa-enabled speaker"
        case let family?: return family.capitalized
        case nil: return "Alexa device"
        }
    }
}

extension EchoDevice {
    /// Case/whitespace-insensitive lookup by name or serial number.
    public static func find(_ nameOrSerial: String, in devices: [EchoDevice]) -> EchoDevice? {
        let needle = nameOrSerial.trimmingCharacters(in: .whitespaces).lowercased()
        return devices.first { $0.serialNumber.lowercased() == needle }
            ?? devices.first { $0.accountName.lowercased() == needle }
            ?? devices.first { $0.accountName.lowercased().contains(needle) }
    }

    /// Music-capable devices, online first, then alphabetically.
    public static func musicTargets(_ devices: [EchoDevice]) -> [EchoDevice] {
        devices
            .filter(\.canPlayMusic)
            .sorted {
                let lhsOnline = $0.online ?? true, rhsOnline = $1.online ?? true
                if lhsOnline != rhsOnline { return lhsOnline }
                return $0.accountName.localizedCaseInsensitiveCompare($1.accountName) == .orderedAscending
            }
    }
}
