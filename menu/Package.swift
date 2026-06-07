// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Millrace",
    platforms: [.macOS(.v14)],
    targets: [
        // Vendored zstd decompressor (decoder-only amalgamation), statically
        // linked so we never need a system `zstd`/`libzstd` — see Sources/CZstd.
        .target(
            name: "CZstd",
            path: "Sources/CZstd",
            sources: ["zstddeclib.c"],
            publicHeadersPath: "include"
        ),
        .executableTarget(
            name: "Millrace",
            dependencies: ["CZstd"],
            path: "Sources/Millrace"
        ),
    ]
)
