// swift-tools-version: 6.0

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
            exclude: ["Info.plist"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "BundleTests",
            dependencies: ["Bundle"],
            path: "Tests/BundleTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
