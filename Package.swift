// swift-tools-version: 5.9
import PackageDescription

// Zero external dependencies, deliberately. Every line that ships is in this
// repo and auditable — the app reads arbitrary user code and can be pointed at
// network endpoints, so the supply chain is kept at exactly zero.
let package = Package(
    name: "Understanley",
    platforms: [
        .macOS(.v13)
    ],
    targets: [
        .executableTarget(
            name: "Understanley",
            path: "Sources/Understanley",
            swiftSettings: [
                // Complete concurrency checking. Under the Swift 5 language mode
                // these surface as warnings rather than errors, which is the point:
                // they guide the port without blocking it, and the codebase is held
                // at zero of them.
                .enableExperimentalFeature("StrictConcurrency")
            ]
        ),
        .testTarget(
            name: "UnderstanleyTests",
            dependencies: ["Understanley"],
            path: "Tests/UnderstanleyTests"
        )
    ]
)
