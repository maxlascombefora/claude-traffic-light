// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "claude-traffic-light",
    platforms: [.macOS(.v13)],
    targets: [
        .target(name: "TrafficLightCore"),
        .executableTarget(
            name: "reporter",
            dependencies: ["TrafficLightCore"]
        ),
        .executableTarget(
            name: "TrafficLight",
            dependencies: ["TrafficLightCore"]
        ),
        // Plain executable self-test — XCTest needs full Xcode, which CLT-only setups lack.
        // Run with: swift run ctl-selftest
        .executableTarget(
            name: "ctl-selftest",
            dependencies: ["TrafficLightCore"]
        ),
    ],
    swiftLanguageModes: [.v5]
)
