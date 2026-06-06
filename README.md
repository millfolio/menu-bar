# millpond

A macOS menu-bar companion for [**millrace**](https://github.com/millrace/mojo-backend),
the pure-Mojo local LLM inference server. Millpond lives in the menu bar and
shows whether the server is up and which model it's serving — a calm pond
watching over the millrace.

## Layout

| folder                    | what                                                  |
|---------------------------|-------------------------------------------------------|
| [`menu/`](menu)           | the SwiftUI `MenuBarExtra` app (Swift Package)        |
| [`installer/`](installer) | packages the app into a `.app` bundle and installs it |

## Quick start

```sh
# run the menu-bar app in dev
cd menu && swift run

# or build + install it as /Applications/Millpond.app
cd installer && ./install.sh && open /Applications/Millpond.app
```

Requires macOS 14+ and a Swift toolchain. Point it at a running millrace server
(`pixi run serve` in mojo-backend; defaults to `http://127.0.0.1:8000`).
