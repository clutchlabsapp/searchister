// swift-tools-version: 6.0
import PackageDescription

// Compiles the portable part of HisterKit on Linux, so changes can be typechecked and the unit
// tests run without a Mac. Sources are copied in by lintcheck.sh; the three files that import
// Security, CoreSpotlight or UIKit are left out and KeychainStore is stubbed.
let package = Package(
    name: "LinuxCheck",
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.0.0"),
        .package(url: "https://github.com/weichsel/ZIPFoundation.git", .upToNextMinor(from: "0.9.19")),
    ],
    targets: [
        .target(
            name: "HisterKit",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift"),
                .product(name: "ZIPFoundation", package: "ZIPFoundation"),
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "HisterKitTests",
            dependencies: ["HisterKit"],
            resources: [.copy("Fixtures")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
