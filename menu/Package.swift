// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Millfolio",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.3.0"),
        // Sparkle auto-update framework (Developer-ID / non-App-Store apps). Only the
        // menu-bar `Millfolio` app links it; the CLI does not.
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.9.4"),
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
        // UI-agnostic, used by BOTH the menu-bar app and the `millfolio` CLI.
        .target(
            name: "MillfolioCore",
            dependencies: ["CZstd"],
            path: "Sources/MillfolioCore"
        ),
        // The menu-bar app. Binary is `Millfolio` (the installer bundles it as
        // Millfolio.app — see installer/bundle.sh, which hardcodes that name).
        .executableTarget(
            name: "Millfolio",
            dependencies: [
                "MillfolioCore",
                .product(name: "Sparkle", package: "Sparkle"),
            ],
            path: "Sources/Millfolio"
        ),
        // The `millfolio` CLI. Target/binary is `millfolio-cli` to avoid colliding
        // with the `Millfolio` app binary on case-insensitive filesystems; CI /
        // the Homebrew formula install it as `millfolio`.
        .executableTarget(
            name: "millfolio-cli",
            dependencies: [
                "MillfolioCore",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            path: "Sources/millfolio-cli"
        ),
    ]
)
