# Millrace (menu-bar app + CLI)

> Part of [**millrace**](https://millrace.app) — local-first LLM inference on Apple Silicon.

The desktop companions for the
[millrace inference server](https://github.com/millrace/inference-server) (the
pure-Mojo local LLM engine): a macOS **menu-bar app** and a **`millrace` CLI**.
Either one bootstraps the server — fetch the Mojo toolchain, build the engine,
download model weights, serve, and launch opencode. Both share one install tree
and one launchd-managed server.

> Looking for the personal data vault? That's [**dacular**](https://dacular.app)
> — its own `dacular` CLI ([dacularapp/cli](https://github.com/dacularapp/cli)),
> which installs this server plus headgate and the vault on top.

## Layout

| folder                            | what                                                            |
|-----------------------------------|-----------------------------------------------------------------|
| [`menu/`](menu)                   | Swift Package: `MillraceCore` + the menu-bar app + the `millrace` CLI |
| [`installer/`](installer)         | packages the app into a `.app` bundle and installs it           |
| [`dist/homebrew/`](dist/homebrew) | the Homebrew formula + tap tooling for the `millrace` CLI        |

## Install

Two ways to install — the **menu-bar app** (point-and-click) or the **`millrace`
CLI** (Homebrew). They share one install tree
(`~/Library/Application Support/Millrace`) and one launchd-managed server
(`me.millrace.server`), so you can start the server from one and see it from the
other.

### Menu-bar app

Grab `Millrace.pkg` from the
[latest release](https://github.com/millrace/app/releases/latest) and open it.
The installer puts **Millrace** in `/Applications` and quits any running copy
first (so updates work), signed + notarized — see [`installer/`](installer).

Then, from the menu bar:

1. **Install server…** — downloads the Mojo toolchain + engine, builds it, and
   fetches the default model's weights.
2. **Start server** — runs it (as a launchd LaunchAgent) on `http://127.0.0.1:8000`.
3. **Start opencode…** — opens opencode in a Terminal, pointed at the server.

### Command line (Homebrew)

```sh
brew install millrace/tap/millrace

millrace install     # toolchain + engine + weights (one time, several GB)
millrace start       # launchd LaunchAgent on http://127.0.0.1:8000
millrace status      # installed? weights? running? serving what?
millrace logs -f     # tail the engine log
millrace stop        # stop the server
millrace opencode    # open opencode pointed at the server
```

Run `millrace --help` for the full command list.

### From source (needs macOS 14+ and a Swift toolchain)

```sh
cd menu && swift run                                 # run the menu app in dev
cd menu && swift run millrace-cli status             # run the CLI in dev
cd installer && ./install.sh                         # build + install the app to /Applications
cd installer && ./make_pkg.sh Millrace.pkg           # build the installer .pkg
```

The CLI is published as a signed universal binary via a Homebrew tap — see
[`dist/homebrew/`](dist/homebrew).
