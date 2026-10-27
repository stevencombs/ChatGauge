// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "ChatGauge",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "ChatGauge", targets: ["ChatGauge"]),
    ],
    targets: [
        // Pure Foundation logic: settings, tiers, the Ollama client and NDJSON parser, instructions,
        // chat files, whisper arguments, update checks. Unit-tested.
        .target(name: "ChatGaugeCore"),
        // The menu bar app (AppKit + SwiftUI) and a few debug CLI flags.
        .executableTarget(name: "ChatGauge", dependencies: ["ChatGaugeCore"]),
        .testTarget(name: "ChatGaugeCoreTests", dependencies: ["ChatGaugeCore"]),
    ]
)
