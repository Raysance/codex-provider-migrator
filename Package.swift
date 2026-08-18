// swift-tools-version: 6.1

import PackageDescription

let package = Package(
    name: "CodexProviderMigrator",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "CodexProviderMigrator", targets: ["CodexProviderMigrator"])
    ],
    targets: [
        .executableTarget(
            name: "CodexProviderMigrator",
            path: "Sources/CodexProviderMigrator"
        )
    ]
)
