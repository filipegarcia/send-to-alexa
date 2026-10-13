// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AlexaKit",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
    ],
    products: [
        // The reusable core: Amazon sign-in, Echo device list, "play this on that Echo",
        // and Apple Music link -> search phrase resolution. Used by the iOS/macOS apps and the CLI.
        .library(name: "AlexaKit", targets: ["AlexaKit"]),
        // A small developer CLI (`swift run alexa-send --help`) to exercise the core from a terminal.
        .executable(name: "alexa-send", targets: ["alexa-send"]),
    ],
    targets: [
        .target(name: "AlexaKit"),
        .executableTarget(
            name: "alexa-send",
            dependencies: ["AlexaKit"]
        ),
        .testTarget(
            name: "AlexaKitTests",
            dependencies: ["AlexaKit"]
        ),
    ]
)
