// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "RoamRun",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "RoamRun",
            path: "Sources/RoamRun"
        ),
        .testTarget(
            name: "RoamRunTests",
            dependencies: ["RoamRun"],
            path: "Tests/RoamRunTests"
        ),
    ]
)
