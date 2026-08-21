// swift-tools-version:6.2
import PackageDescription

let package = Package(
    name: "Zero",
    platforms: [.macOS("26.0")],
    products: [
        .library(name: "ZeroCore", targets: ["ZeroCore"]),
        .executable(name: "Zero", targets: ["Zero"]),
        .executable(name: "zero-probe", targets: ["zero-probe"]),
        .executable(name: "zero-permission-hook", targets: ["zero-permission-hook"]),
    ],
    targets: [
        .target(
            name: "ZeroCore",
            resources: [.copy("Resources/pricing.json")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .executableTarget(
            name: "Zero",
            dependencies: ["ZeroCore"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .executableTarget(
            name: "zero-probe",
            dependencies: ["ZeroCore"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .executableTarget(
            name: "zero-permission-hook",
            dependencies: ["ZeroCore"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "ZeroCoreTests",
            dependencies: ["ZeroCore"],
            resources: [.copy("Fixtures")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
