// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Millpond",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Millpond",
            path: "Sources/Millpond"
        )
    ]
)
