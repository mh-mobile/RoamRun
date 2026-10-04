// swift-tools-version: 6.0
import PackageDescription

import Foundation

var targets: [Target] = [
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

// Experimental (device control): only with ROAMRUN_DEVICE set, after `make device-lib` built
// the library. Without it the app and its tests don't need Rust.
if ProcessInfo.processInfo.environment["ROAMRUN_DEVICE"] != nil {
    targets += [
        .systemLibrary(
            name: "RoamRunDevice",
            path: "Rust/RoamRunDevice/include"
        ),
        .executableTarget(
            name: "DeviceProbe",
            dependencies: ["RoamRunDevice"],
            path: "Sources/DeviceProbe",
            linkerSettings: [
                .unsafeFlags(["-L", ".build/device/release"]),
                .linkedLibrary("roamrun_device"),
            ]
        ),
    ]
}

let package = Package(
    name: "RoamRun",
    platforms: [.macOS(.v13)],
    targets: targets
)
