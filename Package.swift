// swift-tools-version:6.2
import PackageDescription

let package = Package(
    name: "Zero",
    platforms: [.macOS("26.0")],
    products: [
        .library(name: "ZeroCore", targets: ["ZeroCore"]),
        .executable(name: "zero-probe", targets: ["zero-probe"]),
    ],
    targets: [
        .target(
            name: "ZeroCore",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .executableTarget(
            name: "zero-probe",
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
