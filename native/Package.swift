// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Breeze",
    platforms: [.macOS(.v14)],
    targets: [
        // Phase A/B: the native browser chrome + WKWebView engine.
        // Phase C will add a `CLlama` C target (llama.cpp) as a dependency here.
        .executableTarget(
            name: "Breeze",
            path: "Sources/Breeze"
        )
    ]
)
