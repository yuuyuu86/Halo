// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Halo",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Halo", targets: ["Halo"])
    ],
    targets: [
        .executableTarget(
            name: "Halo",
            path: "Sources/Halo",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "HaloTests",
            dependencies: ["Halo"],
            path: "Tests/HaloTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
