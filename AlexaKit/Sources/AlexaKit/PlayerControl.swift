import Foundation

/// Transport controls for whatever an Echo is playing (`POST /api/np/command`).
public enum PlayerCommand: Equatable, Sendable {
    case play
    case pause
    case next
    case previous
    /// 0…100
    case volume(Int)

    var body: [String: Any] {
        switch self {
        case .play: return ["type": "PlayCommand"]
        case .pause: return ["type": "PauseCommand"]
        case .next: return ["type": "NextCommand"]
        case .previous: return ["type": "PreviousCommand"]
        case .volume(let level): return ["type": "VolumeLevelCommand", "volumeLevel": min(100, max(0, level))]
        }
    }
}

extension AlexaClient {
    /// Play / pause / skip / set volume on `device`.
    public func send(_ command: PlayerCommand, to device: EchoDevice) async throws {
        let path = "/api/np/command?deviceSerialNumber=\(device.serialNumber)&deviceType=\(device.deviceType)"
        _ = try await rawRequest("POST", path, jsonBody: try JSONSerialization.data(withJSONObject: command.body))
    }

    /// Current volume (0…100) of `device`, from `GET /api/media/state`.
    public func volume(on device: EchoDevice) async throws -> Int? {
        let path = "/api/media/state?deviceSerialNumber=\(device.serialNumber)&deviceType=\(device.deviceType)&screenWidth=1392"
        let json = HTTP.jsonObject(try await rawRequest("GET", path))
        return (json?["volume"] as? NSNumber)?.intValue
    }

    /// What every device in `devices` is playing, fetched concurrently. Devices that fail or report nothing are omitted.
    public func nowPlaying(on devices: [EchoDevice]) async -> [String: NowPlaying] {
        await withTaskGroup(of: (String, NowPlaying?).self) { group in
            for device in devices {
                group.addTask { (device.serialNumber, try? await self.nowPlaying(on: device)) }
            }
            var result: [String: NowPlaying] = [:]
            for await (serial, playing) in group {
                if let playing { result[serial] = playing }
            }
            return result
        }
    }
}
