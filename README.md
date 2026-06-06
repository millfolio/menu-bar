# Millrace (menu-bar app)

The **Millrace** macOS menu-bar app — the desktop companion for the
[millrace inference server](https://github.com/millrace/mojo-backend) (the
pure-Mojo local LLM engine). It lives in the menu bar and shows whether the
server is up and which model it's serving.

## Layout

| folder                    | what                                                  |
|---------------------------|-------------------------------------------------------|
| [`menu/`](menu)           | the SwiftUI `MenuBarExtra` app (Swift Package)        |
| [`installer/`](installer) | packages the app into a `.app` bundle and installs it |

## Install

**Download:** grab `Millrace.pkg` from the
[latest release](https://github.com/millrace/app/releases/latest) and open it.
The installer puts **Millrace** in `/Applications` and quits any running copy
first (so updates work), signed + notarized — see [`installer/`](installer).

**From source** (needs macOS 14+ and a Swift toolchain):

```sh
cd menu && swift run                                 # run in dev
cd installer && ./install.sh                         # build + install to /Applications
cd installer && ./make_pkg.sh Millrace.pkg           # build the installer .pkg
```

Point it at a running millrace server (`pixi run serve` in mojo-backend; defaults
to `http://127.0.0.1:8000`).
