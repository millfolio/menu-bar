// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Millrace",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.3.0"),
    ],
    targets: [
        // Vendored zstd decompressor (decoder-only amalgamation), statically
        // linked so we never need a system `zstd`/`libzstd` — see Sources/CZstd.
        .target(
            name: "CZstd",
            path: "Sources/CZstd",
            sources: ["zstddeclib.c"],
            publicHeadersPath: "include"
        ),
        // Shared engine-lifecycle logic (install/build/start the server + headgate),
        // UI-agnostic, used by BOTH the menu-bar app and the `millrace` CLI.
        .target(
            name: "MillraceCore",
            dependencies: ["CZstd"],
            path: "Sources/MillraceCore"
        ),
        // The menu-bar app. Binary is `Millrace` (the installer bundles it as
        // Millrace.app — see installer/bundle.sh, which hardcodes that name).
        .executableTarget(
            name: "Millrace",
            dependencies: ["MillraceCore"],
            path: "Sources/Millrace"
        ),
        // The `millrace` CLI. Target/binary is `millrace-cli` to avoid colliding
        // with the `Millrace` app binary on case-insensitive filesystems; CI /
        // the Homebrew formula install it as `millrace`.
        .executableTarget(
            name: "millrace-cli",
            dependencies: [
                "MillraceCore",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            path: "Sources/millrace-cli"
        ),
    ]
)
