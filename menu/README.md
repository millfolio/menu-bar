# menu

The Millrace macOS menu-bar app — a SwiftUI [`MenuBarExtra`](https://developer.apple.com/documentation/swiftui/menubarextra)
that watches a local [millrace](https://github.com/millrace/inference-server) server
and shows whether it's up and which model it's serving.

## Run (development)

```sh
swift build
swift run        # the icon appears in the menu bar
```

Requires macOS 14+ and a Swift toolchain (Xcode or the Swift CLI). To install it
as a proper menu-bar app bundle, use [`../installer`](../installer).

## Layout

- `Sources/Millrace/MillraceApp.swift` — the `MenuBarExtra` scene + menu content.
- `Sources/Millrace/MillraceClient.swift` — polls the server's `/v1/models`
  every 5 s for reachability + the served model id (default
  `http://127.0.0.1:8000`).

## Ideas / TODO

- Start / stop the `pixi run serve` process from the menu.
- Switch model (0.5B / 3B, bf16 / int4) and restart.
- Show live tokens/sec and prefix-cache stats.
- Launch-at-login toggle (`SMAppService`).
