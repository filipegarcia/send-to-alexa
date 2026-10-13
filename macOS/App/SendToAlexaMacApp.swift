import SwiftUI

@main
struct SendToAlexaMacApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                .frame(minWidth: 420, idealWidth: 460, minHeight: 520, idealHeight: 640)
        }
        .windowResizability(.contentMinSize)
        .defaultSize(width: 460, height: 640)
    }
}
