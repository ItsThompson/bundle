// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "Bundle",
    platforms: [
        .macOS(.v14)
    ],
    targets: [
        .executableTarget(
            name: "Bundle",
            path: "Sources/App",
            exclude: ["Info.plist"]
        )
    ]
)
