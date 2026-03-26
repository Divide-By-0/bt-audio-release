// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "bt-kill-a2dp",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "bt-kill-a2dp",
            path: "Sources",
            linkerSettings: [
                .linkedFramework("IOBluetooth"),
            ]
        )
    ]
)
