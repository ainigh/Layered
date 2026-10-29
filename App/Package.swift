// swift-tools-version: 5.10
import PackageDescription

// The macOS app: a thin projection of the harness's MapState. Build with
// `swift build -c release` (or open this file in Xcode); `make app` in this
// folder wraps the binary in a bundle with LSUIElement so it lives in the menu bar.
let package = Package(
    name: "Mindmap",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(path: "../Harness"),
        // whisper.cpp ships a Swift package exposing the C API with Metal enabled.
        // Pinned by revision (v1.7.2): later tags drop the source-building Package.swift,
        // and a versioned requirement is rejected because the target uses unsafeFlags.
        .package(url: "https://github.com/ggml-org/whisper.cpp", revision: "6266a9f9e56a5b925e9892acf650f3eb1245814d"),
    ],
    targets: [
        .executableTarget(
            name: "Mindmap",
            dependencies: [
                .product(name: "Harness", package: "Harness"),
                .product(name: "whisper", package: "whisper.cpp"),
            ],
            path: "Sources/Mindmap"
        ),
        .testTarget(
            name: "MindmapTests",
            dependencies: ["Mindmap"],
            path: "Tests/MindmapTests",
            exclude: ["__Snapshots__"]
        ),
    ]
)
