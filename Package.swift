// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "CmdTab",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "CmdTab",
            path: "Sources/CmdTab",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("ScreenCaptureKit"),
                .linkedFramework("ServiceManagement"),
            ]
        )
    ]
)
