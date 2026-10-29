// swift-tools-version: 5.10
import PackageDescription

// The harness is the whole behaviour of the app with no UI import:
// notation (parse, compile, canonical form, edits), the gate that checks
// model output, the evidence store, and the MapState + Action reducer.
let package = Package(
    name: "Harness",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "Harness", targets: ["Harness"]),
    ],
    targets: [
        .target(name: "Harness", resources: [.copy("Resources/Demo")]),
        .testTarget(
            name: "HarnessTests",
            dependencies: ["Harness"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
