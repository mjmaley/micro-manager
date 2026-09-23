// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "WLTools",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "WLKit", targets: ["WLKit"]),
        .executable(name: "WLInspector", targets: ["WLInspector"]),
        .executable(name: "WLMicroManager", targets: ["WLMicroManager"]),
        .executable(name: "WLLayerProbe", targets: ["WLLayerProbe"]),
        .executable(name: "WLMediaProbe", targets: ["WLMediaProbe"]),
    ],
    targets: [
        // Device transport, vendor protocol, Herdr client and the bridge engine.
        // Shared by the debug inspector and the menu-bar manager.
        .target(name: "WLKit", path: "Sources/WLKit"),

        // Debug UI: traffic log and manual lighting control.
        .executableTarget(name: "WLInspector", dependencies: ["WLKit"], path: "Sources/WLInspector"),

        // Menu-bar app: runs the bridge in the background.
        .executableTarget(name: "WLMicroManager", dependencies: ["WLKit"], path: "Sources/WLMicroManager"),

        // Safe diagnostic for validating AG lighting and input on non-Codex layers.
        .executableTarget(name: "WLLayerProbe", dependencies: ["WLKit"], path: "Sources/WLLayerProbe"),

        // Read-only Now Playing + dictation input diagnostic; never controls media.
        .executableTarget(name: "WLMediaProbe", dependencies: ["WLKit"], path: "Sources/WLMediaProbe"),

        // Fixtures are read from the source directory via #filePath rather than
        // from the test bundle, so they are excluded rather than declared as
        // resources — SwiftPM would otherwise warn about an unhandled file.
        .testTarget(
            name: "WLKitTests",
            dependencies: ["WLKit"],
            path: "Tests/WLKitTests",
            exclude: ["Fixtures"]
        ),
    ]
)
