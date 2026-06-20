# Millfolio (menu-bar app + CLI)

> Part of [**millfolio**](https://millfolio.app) — local-first LLM inference on Apple Silicon.

The desktop companions for the
[engine inference server](https://github.com/millfolio/engine) (the
pure-Mojo local LLM engine): a macOS **menu-bar app** and a **`millfolio` CLI**.
Either one bootstraps the server — fetch the Mojo toolchain, build the engine,
download model weights, serve, and launch opencode. Both share one install tree
and one launchd-managed server.

> Looking for the personal data vault? That's [**dacular**](https://dacular.app)
> — its own `dacular` CLI ([dacularapp/cli](https://github.com/dacularapp/cli)),
> which installs this server plus headgate and the vault on top.

## Layout

| folder                            | what                                                            |
|-----------------------------------|-----------------------------------------------------------------|
| [`menu/`](menu)                   | Swift Package: `MillfolioCore` + the menu-bar app + the `millfolio` CLI |
| [`installer/`](installer)         | packages the app into a `.app` bundle and installs it           |
| [`dist/homebrew/`](dist/homebrew) | the Homebrew formula + tap tooling for the `millfolio` CLI        |

## Install

Two ways to install — the **menu-bar app** (point-and-click) or the **`millfolio`
CLI** (Homebrew). They share one install tree
(`~/Library/Application Support/Millfolio`) and one launchd-managed server
(`me.millfolio.server`), so you can start the server from one and see it from the
other.

### Menu-bar app

Grab `Millfolio.pkg` from the
[latest release](https://github.com/millfolio/app/releases/latest) and open it.
The installer puts **Millfolio** in `/Applications` and quits any running copy
first (so updates work), signed + notarized — see [`installer/`](installer).

Then, from the menu bar:

1. **Install server…** — downloads the Mojo toolchain + engine, builds it, and
   fetches the default model's weights.
2. **Start server** — runs it (as a launchd LaunchAgent) on `http://127.0.0.1:8000`.
3. **Start opencode…** — opens opencode in a Terminal, pointed at the server.

### Command line (Homebrew)

```sh
brew install millfolio/tap/millfolio

millfolio install     # toolchain + engine + weights (one time, several GB)
millfolio start       # launchd LaunchAgent on http://127.0.0.1:8000
millfolio status      # installed? weights? running? serving what?
millfolio logs -f     # tail the engine log
millfolio stop        # stop the server
millfolio opencode    # open opencode pointed at the server
```

Run `millfolio --help` for the full command list.

### From source (needs macOS 14+ and a Swift toolchain)

```sh
cd menu && swift run                                 # run the menu app in dev
cd menu && swift run millfolio-cli status            # run the CLI in dev
cd installer && ./install.sh                         # build + install the app to /Applications
cd installer && ./make_pkg.sh Millfolio.pkg          # build the installer .pkg
```

The CLI is published as a signed universal binary via a Homebrew tap — see
[`dist/homebrew/`](dist/homebrew).
