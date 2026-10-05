// swift-tools-version: 6.0
import PackageDescription

import Foundation

// Experimental (device control): with ROAMRUN_DEVICE set (`make app DEVICE=1`), after
// `make device-lib` built the Rust library, the app holds connections to devices and the CLI
// has `look` and `tap`. Without it nothing here needs Rust.
let deviceControl = ProcessInfo.processInfo.environment["ROAMRUN_DEVICE"] != nil

var targets: [Target] = [
    .executableTarget(
        name: "RoamRun",
        dependencies: deviceControl ? ["DeviceControl"] : [],
        path: "Sources/RoamRun",
        swiftSettings: deviceControl ? [.define("DEVICE_CONTROL")] : []
    ),
    .testTarget(
        name: "RoamRunTests",
        dependencies: ["RoamRun"],
        path: "Tests/RoamRunTests",
        swiftSettings: deviceControl ? [.define("DEVICE_CONTROL")] : []
    ),
]

if deviceControl {
    targets += [
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
}

let package = Package(
    name: "RoamRun",
    platforms: [.macOS(.v13)],
    targets: targets
)
