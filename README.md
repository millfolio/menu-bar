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

## Install

**Download:** grab `Millpond.dmg` from the
[latest release](https://github.com/millrace/millpond/releases/latest), open it,
and drag **Millpond** to **Applications**. (First launch: right-click → **Open**,
since the build isn't Apple-notarized — see [`installer/`](installer).)

**From source** (needs macOS 14+ and a Swift toolchain):

```sh
cd menu && swift run                                 # run in dev
cd installer && ./install.sh                         # build + install to /Applications
cd installer && ./make_dmg.sh Millpond.dmg           # build a .dmg
```

Point it at a running millrace server (`pixi run serve` in mojo-backend; defaults
to `http://127.0.0.1:8000`).
