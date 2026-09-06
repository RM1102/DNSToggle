// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "DNSToggle",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "DNSToggle",
            path: "Sources/DNSToggle"
        )
    ]
)
