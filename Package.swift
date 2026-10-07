// swift-tools-version: 5.9
// MacStats builds with the Xcode Command Line Tools alone, which ship neither XCTest nor
// Swift Testing, so its tests are a second program that drives the built app through its
// command line: `make test`, or `swift build && .build/debug/MacStatsTests`.
import PackageDescription

let package = Package(
    name: "MacStats",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(name: "MacStats", path: "Sources/MacStats"),
        .executableTarget(name: "MacStatsTests", path: "Tests/MacStatsTests"),
    ]
)
