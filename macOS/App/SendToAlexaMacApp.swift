import SwiftUI

/// Mac app = a menu bar item (now playing, controls, play copied link) + a settings window.
/// It has no Dock icon (LSUIElement). The Share extension works whether or not the app is running.
@main
struct SendToAlexaMacApp: App {
    @State private var menuBar = MenuBarModel()

    var body: some Scene {
        MenuBarExtra {
            MenuBarContent(model: menuBar)
        } label: {
            MenuBarLabel(model: menuBar)
        }
        .menuBarExtraStyle(.window)

        Window("Send to Alexa", id: "main") {
            ContentView()
                .frame(minWidth: 420, idealWidth: 460, minHeight: 520, idealHeight: 640)
                .onDisappear { menuBar.player.reloadAccount() }
        }
        .windowResizability(.contentMinSize)
        .defaultSize(width: 460, height: 640)
        // Only show the window at launch when there's something to set up.
        .defaultLaunchBehavior(AppEnvironment.service.isSignedIn ? .suppressed : .presented)
    }
}
