// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "CodexSignal",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "CodexSignal", targets: ["SignalApp"]), .library(name: "SignalCore", targets: ["SignalCore"])],
    targets: [
        .target(name: "SignalCore"),
        .executableTarget(name: "SignalApp", dependencies: ["SignalCore"], resources: [.copy("Resources")]),
        .testTarget(name: "SignalCoreTests", dependencies: ["SignalCore"]),
        .testTarget(name: "SignalAppTests", dependencies: ["SignalApp", "SignalCore"])
    ]
)
