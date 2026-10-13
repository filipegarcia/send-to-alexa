import Foundation
import Testing
@testable import AlexaKit

@Suite("Storage")
struct StorageTests {
    @Test func roundTripsCredentialsAndPreferences() throws {
        let store = AlexaStore(MemoryStore())
        #expect(store.loadCredentials() == nil)
        #expect(store.loadPreferences() == Preferences())

        let creds = AlexaCredentials.fixture()
        try store.saveCredentials(creds)
        let loaded = try #require(store.loadCredentials())
        #expect(loaded.refreshToken == creds.refreshToken)
        #expect(loaded.marketplaceDomain == "amazon.co.uk")

        try store.updatePreferences {
            $0.cachedDevices = [.kitchen]
            $0.defaultDeviceSerial = EchoDevice.kitchen.serialNumber
            $0.provider = .spotify
        }
        #expect(store.loadPreferences().defaultDevice == .kitchen)
        #expect(store.loadPreferences().provider == .spotify)

        try store.reset()
        #expect(store.loadCredentials() == nil)
        #expect(store.loadPreferences().cachedDevices.isEmpty)
    }

    @Test func preferencesDecodingIsForwardCompatible() throws {
        let json = #"{"defaultDeviceSerial":"S1","provider":"SOME_FUTURE_PROVIDER"}"#
        let prefs = try JSONDecoder().decode(Preferences.self, from: Data(json.utf8))
        #expect(prefs.defaultDeviceSerial == "S1")
        #expect(prefs.provider == .appleMusic)
        #expect(prefs.cachedDevices.isEmpty)
        #expect(prefs.playImmediately == false)
    }

    @Test func fileStoreWritesPrivateFiles() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("alexakit-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = FileStore(directory: dir)
        try store.write(Data("secret".utf8), for: "credentials")
        #expect(try store.read("credentials") == Data("secret".utf8))

        let attributes = try FileManager.default.attributesOfItem(atPath: dir.appendingPathComponent("credentials.json").path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)

        try store.write(nil, for: "credentials")
        #expect(try store.read("credentials") == nil)
    }
}
