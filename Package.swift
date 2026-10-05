// swift-tools-version: 6.0
import PackageDescription

// Device control links RoamRun's own Rust library: `make device-lib` builds it first (the
// Makefile's targets do), and it needs Rust.
let targets: [Target] = [
    .executableTarget(
        name: "RoamRun",
        dependencies: ["DeviceControl"],
        path: "Sources/RoamRun"
    ),
    .testTarget(
        name: "RoamRunTests",
        dependencies: ["RoamRun"],
        path: "Tests/RoamRunTests"
    ),
    .systemLibrary(
        name: "RoamRunDevice",
        path: "Rust/RoamRunDevice/include"
    ),
    .target(
        name: "DeviceControl",
        dependencies: ["RoamRunDevice"],
        path: "Sources/DeviceControl",
        linkerSettings: [
            .unsafeFlags(["-L", ".build/device/release"]),
            .linkedLibrary("roamrun_device"),
        ]
    ),
    .executableTarget(
        name: "DeviceProbe",
        dependencies: ["DeviceControl"],
        path: "Sources/DeviceProbe"
    ),
]

let package = Package(
    name: "RoamRun",
    platforms: [.macOS(.v13)],
    targets: targets
)
