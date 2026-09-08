// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "RelaySetup",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "RelaySetup", targets: ["RelaySetup"])
    ],
    targets: [
        .executableTarget(
            name: "RelaySetup",
            path: "Sources/RelaySetup"
        ),
        .testTarget(
            name: "RelaySetupTests",
            dependencies: ["RelaySetup"],
            path: "Tests/RelaySetupTests"
        )
    ]
)
