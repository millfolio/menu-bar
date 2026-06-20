import Foundation
import AppKit

/// Drives the local engine lifecycle, as three explicit steps:
///
///   1. **Install server** — fetch the official Mojo compiler+runtime from
///      Modular's conda channel (so the *user* accepts Modular's license — we
///      never redistribute it), unpack our engine source zip (inference-server +
///      jinja2.mojo + flare + a prebuilt libflare_tls.so), build the server with
///      `mojo build`, then download the default model's weights with the engine's
///      own native-Mojo downloader (no huggingface_hub).
///   2. **Start server** — launch the built server (via a launchd LaunchAgent, so
///      the CLI and the menu app share one managed process).
///   3. **Start opencode** — point opencode at the running server (new Terminal).
///
/// Everything lives under ~/Library/Application Support/Millfolio, including the
/// model weights (HF_HOME=<support>/hf), so uninstall is a single directory.
///
/// This type is UI-agnostic on purpose: the menu-bar app observes it as an
/// `ObservableObject` (via `phase`/`serverRunning`), while the `millfolio` CLI
/// drives the same methods and streams progress through `onProgress`.
///
/// NOTE: the Mojo fetch is "rattler-by-URL" — we don't link the rattler crate, we
/// GET the pinned `.conda` packages (a .conda is a zip of zstd tarballs) and
/// extract them with the system `unzip`/`tar`. Keep `mojoVersion` in sync with
/// inference-server/pixi.lock.
@MainActor
public final class Bootstrapper: ObservableObject {
    public enum Phase: Equatable {
        case idle
        case running(String)
        case done
        case failed(String)

        public var message: String? {
            switch self {
            case .idle, .done: return nil
            case .running(let m): return m
            case .failed(let e): return "Failed: \(e)"
            }
        }
    }

    /// Progress of the long-running provisioning steps.
    @Published public var phase: Phase = .idle
    /// True while the engine server's LaunchAgent is loaded.
    @Published public var serverRunning = false

    /// Optional progress sink — every status message is forwarded here as well as
    /// to `phase`, so a non-UI driver (the CLI) can stream the same text.
    public var onProgress: ((String) -> Void)?

    public init() {
        refreshServerRunning()
    }

    public var isBusy: Bool { if case .running = phase { return true }; return false }

    // ── pinned manifest (keep in sync with inference-server/pixi.lock) ─────────────
    public static let mojoVersion = "1.0.0b3.dev2026061206"
    public static let condaChannel = "https://conda.modular.com/max-nightly"
    /// Default model served by the server. The 3B is int4-friendly and the
    /// quality target; its tokenizer.json is read directly by the engine.
    public static let model = "Qwen/Qwen2.5-3B-Instruct"
    public static let modelSlug = "Qwen--Qwen2.5-3B-Instruct"
    /// SECONDARY embedding model. The server resolves this from the HF cache to
    /// serve /v1/embeddings (else that endpoint 503s), so the installer fetches its
    /// weights too — via the same native-Mojo downloader, another HF id.
    /// Single-file safetensors (small).
    public static let embedModel = "Qwen/Qwen3-Embedding-0.6B"
    public static let embedModelSlug = "Qwen--Qwen3-Embedding-0.6B"

    private var mojoCompilerURL: URL {
        URL(string: "\(Self.condaChannel)/osx-arm64/mojo-compiler-\(Self.mojoVersion)-release.conda")!
    }
    private var mojoPythonURL: URL {
        URL(string: "\(Self.condaChannel)/noarch/mojo-python-\(Self.mojoVersion)-release.conda")!
    }
    /// The engine ("server") source bundle (inference-server + vendored jinja2.mojo/flare +
    /// prebuilt libflare_tls.so), published by inference-server CI. The asset is still
    /// named `runner.zip` (wire name retained for now).
    private let serverZipURL =
        URL(string: "https://github.com/millfolio/engine/releases/latest/download/runner.zip")!

    // ── default config files (~/.config) ───────────────────────────────────────
    // Seeded with sensible defaults on install if absent, so a fresh setup has an
    // editable starting point. The engine reads this; we NEVER overwrite an
    // existing file.
    private var dotConfig: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config", isDirectory: true)
    }
    private var millfolioConfigURL: URL { dotConfig.appendingPathComponent("millfolio/config.json") }

    private static let millfolioConfigDefault = """
    {
      "port": 8000,
      "model": "Qwen/Qwen2.5-3B-Instruct",
      "q4": false,
      "kv_budget_mb": 8192
    }
    """

    /// Create `path` with `json` if it doesn't exist (best-effort; never overwrites).
    private func ensureConfig(at path: URL, _ json: String) {
        let fm = FileManager.default
        guard !fm.fileExists(atPath: path.path) else { return }
        do {
            try fm.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
            try json.write(to: path, atomically: true, encoding: .utf8)
            appendLog("wrote default config: \(path.path)\n")
        } catch {
            appendLog("could not write config \(path.path): \(error)\n")  // non-fatal
        }
    }

    // ── install locations ─────────────────────────────────────────────────────
    private var support: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Millfolio", isDirectory: true)
    }
    private var mojoPrefix: URL { support.appendingPathComponent("mojo", isDirectory: true) }
    private var engineRoot: URL { support.appendingPathComponent("engine", isDirectory: true) }
    private var cacheDir: URL { support.appendingPathComponent("cache", isDirectory: true) }
    /// HF cache root for the model weights (HF_HOME). Self-contained under support/.
    private var hfHome: URL { support.appendingPathComponent("hf", isDirectory: true) }
    /// inference-server checkout inside the unpacked engine zip.
    private var backendDir: URL { engineRoot.appendingPathComponent("inference-server", isDirectory: true) }
    private var serverBin: URL { backendDir.appendingPathComponent("build/server") }
    /// All subprocess output (mojo build, weights download, the running server)
    /// is appended here so errors that flash by in the menu can be read in full.
    public var logFileURL: URL { support.appendingPathComponent("Millfolio.log") }
    public var hasLog: Bool { FileManager.default.fileExists(atPath: logFileURL.path) }

    /// The built engine server binary is present.
    public var isServerInstalled: Bool {
        FileManager.default.isExecutableFile(atPath: serverBin.path)
    }
    /// The default model's weights have been fully downloaded (refs/main is the
    /// downloader's last write, so its presence means the snapshot is complete).
    public var weightsPresent: Bool {
        FileManager.default.fileExists(
            atPath: hfHome.appendingPathComponent("hub/models--\(Self.modelSlug)/refs/main").path)
    }
    /// The embedding model's weights are fully downloaded (refs/main is the
    /// downloader's last write). When present, the server serves /v1/embeddings.
    public var embedWeightsPresent: Bool {
        FileManager.default.fileExists(
            atPath: hfHome.appendingPathComponent("hub/models--\(Self.embedModelSlug)/refs/main").path)
    }
    /// Ready to launch: engine built and (chat) weights downloaded. The embedding
    /// weights are not required to start the chat server, so they don't gate this.
    public var canStartServer: Bool { isServerInstalled && weightsPresent && !serverRunning }

    // ── logging ──────────────────────────────────────────────────────────────
    /// Ensure the log file (and its directory) exist; returns the path.
    @discardableResult
    private func ensureLog() -> URL {
        let fm = FileManager.default
        try? fm.createDirectory(at: support, withIntermediateDirectories: true)
        if !fm.fileExists(atPath: logFileURL.path) {
            fm.createFile(atPath: logFileURL.path, contents: nil)
        }
        return logFileURL
    }

    /// Append text to the log (best-effort; never throws).
    private func appendLog(_ text: String) {
        ensureLog()
        guard let fh = try? FileHandle(forWritingTo: logFileURL) else { return }
        defer { try? fh.close() }
        fh.seekToEndOfFile()
        if let d = text.data(using: .utf8) { fh.write(d) }
    }

    private func logHeader(_ what: String) {
        appendLog("\n===== \(what) — \(Self.stamp()) =====\n")
    }

    private static func stamp() -> String {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f.string(from: Date())
    }

    /// Open the log in the user's default viewer (Console/TextEdit).
    public func openLog() {
        NSWorkspace.shared.open(ensureLog())
    }

    // ── step 1: install server (+ weights) ──────────────────────────────────────
    /// Menu-app entry point: fire-and-forget, drives `phase`. The CLI calls the
    /// throwing `installServer()` directly.
    public func downloadServer() {
        guard !isBusy else { return }
        phase = .running("Starting…")
        Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            do { try await self.installServer(); await self.set(done: true) }
            catch { await self.set(failed: humanError(error)) }
        }
    }

    // ── one-time migration: millrace → millfolio (pre-rename installs) ───────────
    /// Older versions installed under `~/Library/Application Support/Millrace`, with
    /// config/cache under `~/.config/millrace` + `~/.cache/millrace` and a
    /// `me.millrace.server` LaunchAgent. Move each to its `millfolio` location once,
    /// so upgraders keep their multi-GB model weights instead of re-downloading.
    ///
    /// Idempotent and best-effort: a path is moved only when the legacy location
    /// exists and the new one does not, so re-running (or a fresh install) is a
    /// no-op. After moving the tree, the stale engine *build* is dropped (weights
    /// under `hf/` are kept) so `installServer` rebuilds the binary against the new
    /// source + `~/.config/millfolio` config path.
    public func migrateLegacyLayout() {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        let appSup = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]

        // Boot out + remove the old LaunchAgent first; the new install writes the
        // me.millfolio.server agent, and leaving the old one loaded runs a stale
        // binary against a config path that no longer exists.
        let oldAgent = home.appendingPathComponent("Library/LaunchAgents/me.millrace.server.plist")
        if fm.fileExists(atPath: oldAgent.path) {
            _ = try? run("/bin/launchctl", ["bootout", "gui/\(getuid())/me.millrace.server"])
            try? fm.removeItem(at: oldAgent)
            appendLog("migrated: removed legacy LaunchAgent me.millrace.server\n")
        }

        let legacyTree = appSup.appendingPathComponent("Millrace", isDirectory: true)
        let migratedTree = fm.fileExists(atPath: legacyTree.path)
            && !fm.fileExists(atPath: support.path)

        let moves: [(URL, URL)] = [
            (legacyTree, support),
            (home.appendingPathComponent(".config/millrace", isDirectory: true),
             home.appendingPathComponent(".config/millfolio", isDirectory: true)),
            (home.appendingPathComponent(".cache/millrace", isDirectory: true),
             home.appendingPathComponent(".cache/millfolio", isDirectory: true)),
        ]
        for (old, new) in moves where fm.fileExists(atPath: old.path) && !fm.fileExists(atPath: new.path) {
            do {
                try fm.createDirectory(at: new.deletingLastPathComponent(), withIntermediateDirectories: true)
                try fm.moveItem(at: old, to: new)
                appendLog("migrated: \(old.path) → \(new.path)\n")
            } catch {
                appendLog("migration skipped for \(old.lastPathComponent): \(humanError(error))\n")
            }
        }

        guard migratedTree else { return }
        // Keep the model weights (hf/) + cache; drop the stale engine checkout so the
        // server is rebuilt from the new source against ~/.config/millfolio.
        try? fm.removeItem(at: engineRoot)
        // The per-day diagnostic log inside the moved tree kept its old name.
        let oldLog = support.appendingPathComponent("Millrace.log")
        if fm.fileExists(atPath: oldLog.path) && !fm.fileExists(atPath: logFileURL.path) {
            try? fm.moveItem(at: oldLog, to: logFileURL)
        }
    }

    /// Provision the Mojo toolchain, engine source, build, and weights. Throws on
    /// the first failure (the CLI surfaces it; the menu wrapper maps it to `phase`).
    public func installServer() async throws {
        migrateLegacyLayout()   // upgrade an older millrace-layout install in place
        // Idempotent fast-path: everything (engine + both models' weights) already
        // present → nothing to do. Otherwise fall through; the steps below each
        // skip what's already done (toolchain, weights), so a partial install
        // resumes (e.g. just the missing embedding weights).
        if isServerInstalled && weightsPresent && embedWeightsPresent {
            set("server already installed — skipping")
            return
        }
        let fm = FileManager.default
        for d in [support, mojoPrefix, engineRoot, cacheDir, hfHome] {
            try fm.createDirectory(at: d, withIntermediateDirectories: true)
        }
        logHeader("Install server")

        if !fm.fileExists(atPath: mojoPrefix.appendingPathComponent("bin/mojo").path) {
            set("Downloading Mojo compiler (~70 MB)…")
            let compiler = try await download(mojoCompilerURL, name: "mojo-compiler.conda")
            set("Extracting Mojo…")
            try extractConda(compiler, into: mojoPrefix)
            let py = try await download(mojoPythonURL, name: "mojo-python.conda")
            try extractConda(py, into: mojoPrefix)
        }
        try relocateMojoPrefix(mojoPrefix)   // rewrite modular.cfg's baked placeholder prefix

        set("Downloading engine source…")
        let zip = try await download(serverZipURL, name: "runner.zip")
        set("Unpacking engine…")
        try unpackZip(zip, into: engineRoot)

        set("Locating Python…")
        let python = try findPython()

        set("Building engine (first run, ~1 min)…")
        try buildBinary(python: python, source: "src/server.mojo",
                        args: ["-I", "../jinja2.mojo/src", "-I", "../flare"], out: "build/server")
        signServerIdentity()

        if !weightsPresent || !embedWeightsPresent {
            set("Building downloader…")
            try buildBinary(python: python, source: "src/download.mojo",
                            args: ["-I", "../flare"], out: "build/download")
        }
        if !weightsPresent {
            set("Downloading model weights (\(Self.model), several GB)…")
            try downloadWeights(Self.model)
        }
        // The server resolves the embedding model from the HF cache to serve
        // /v1/embeddings; fetch its weights with the same native downloader.
        if !embedWeightsPresent {
            set("Downloading embedding model weights (\(Self.embedModel))…")
            try downloadWeights(Self.embedModel)
        }

        ensureConfig(at: millfolioConfigURL, Self.millfolioConfigDefault)
    }

    // ── step 2: start / stop server (launchd LaunchAgent) ────────────────────────
    // The server runs as a per-user LaunchAgent (me.millfolio.server) instead of a
    // child Process, so a CLI `millfolio server start` and the menu app's "Start
    // server" drive the SAME managed process — either surface can start/stop/see it.
    public static let serverLabel = "me.millfolio.server"
    private var launchAgentURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(Self.serverLabel).plist")
    }
    private var guiDomain: String { "gui/\(getuid())" }

    /// Start the server LaunchAgent. Idempotent: re-bootstraps a fresh plist.
    public func startServer() throws {
        guard isServerInstalled, weightsPresent else {
            throw BootstrapError.step("start server", "engine not installed or weights missing — run install first")
        }
        try writeLaunchAgent()
        logHeader("Start server: \(Self.model)")
        // Replace any prior instance, then load (RunAtLoad starts it).
        _ = try? runStatus("/bin/launchctl", ["bootout", "\(guiDomain)/\(Self.serverLabel)"])
        try run("/bin/launchctl", ["bootstrap", guiDomain, launchAgentURL.path])
        serverRunning = true
    }

    /// Stop the server LaunchAgent (no-op if not loaded).
    public func stopServer() throws {
        let rc = try runStatus("/bin/launchctl", ["bootout", "\(guiDomain)/\(Self.serverLabel)"])
        if rc != 0 { appendLog("[launchctl bootout exited \(rc) — not loaded?]\n") }
        serverRunning = false
    }

    /// Non-throwing menu-button wrappers: surface any failure via `phase`.
    public func tryStartServer() {
        do { try startServer() } catch { phase = .failed(humanError(error)) }
    }
    public func tryStopServer() {
        do { try stopServer() } catch { phase = .failed(humanError(error)) }
    }

    /// Reconcile `serverRunning` with launchd's actual state (e.g. at app launch).
    public func refreshServerRunning() {
        let loaded = (try? runStatus("/bin/launchctl", ["print", "\(guiDomain)/\(Self.serverLabel)"])) == 0
        serverRunning = loaded
    }

    /// Write the LaunchAgent plist that runs the built server against the weights.
    private func writeLaunchAgent() throws {
        try FileManager.default.createDirectory(
            at: launchAgentURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        // Minimal explicit env — launchd does NOT inherit the app's environment.
        // Keep CONDA_PREFIX unset so flare loads build/libflare_tls.so next to the
        // binary; HOME is provided by launchd (kv-cache lives under ~/.cache).
        var env: [String: String] = [
            "HF_HOME": hfHome.path,
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
        ]
        if FileManager.default.fileExists(atPath: "/etc/ssl/cert.pem") {
            env["SSL_CERT_FILE"] = "/etc/ssl/cert.pem"
        }
        let plist: [String: Any] = [
            "Label": Self.serverLabel,
            "ProgramArguments": [serverBin.path, Self.model],
            "WorkingDirectory": backendDir.path,   // hardcoded relative data paths resolve here
            "EnvironmentVariables": env,
            "StandardOutPath": logFileURL.path,
            "StandardErrorPath": logFileURL.path,
            "RunAtLoad": true,
            "ProcessType": "Interactive",
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: launchAgentURL)
    }

    // ── step 3: start opencode ──────────────────────────────────────────────────
    /// Generate an opencode config from the running server's /v1/models, then open
    /// opencode in a new Terminal window pointed at it. opencode is an interactive
    /// TUI, so it must run in a real terminal, not detached.
    public func startOpencode() {
        Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            do { try await self.launchOpencode() }
            catch { await self.set(failed: "opencode: \(humanError(error))") }
        }
    }

    public func launchOpencode() async throws {
        let base = "http://127.0.0.1:8000/v1"
        let opencode = try findOpencode()
        let configPath = try await writeOpencodeConfig(baseURL: base)

        // A small launcher script avoids AppleScript quoting pitfalls.
        let script = support.appendingPathComponent("run-opencode.sh")
        let body = """
        #!/bin/bash
        export OPENCODE_CONFIG="\(configPath)"
        export OPENAI_BASE_URL="\(base)"
        export OPENAI_API_KEY="millfolio"
        # opencode's own dir + common bins on PATH (Terminal already sources the
        # user's profile, but be explicit in case it shells out to helpers).
        export PATH="\(URL(fileURLWithPath: opencode).deletingLastPathComponent().path):$PATH"
        exec "\(opencode)"
        """
        try body.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        // `do script` runs its text as a shell command line, so the script path
        // (which lives under "Application Support" — note the space) must be shell-
        // quoted, or zsh splits it at the space. Single-quote it (the path has no
        // single quotes).
        let cmd = "'\(script.path)'"
        try run("/usr/bin/osascript",
                ["-e", "tell application \"Terminal\" to activate",
                 "-e", "tell application \"Terminal\" to do script \"\(cmd)\""])
    }

    /// Build the opencode provider config the way inference-server/opencode_config.py
    /// does, but in-process (no Python): query /v1/models and declare each served id.
    private func writeOpencodeConfig(baseURL: String) async throws -> String {
        guard let url = URL(string: baseURL + "/models") else {
            throw BootstrapError.step("opencode", "bad base URL")
        }
        var req = URLRequest(url: url); req.timeoutInterval = 3
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard (resp as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let arr = json["data"] as? [[String: Any]] else {
            throw BootstrapError.step("opencode", "server not reachable at \(baseURL)/models — start the server first")
        }
        let ids = arr.compactMap { $0["id"] as? String }
        guard let first = ids.first else { throw BootstrapError.step("opencode", "no models served") }
        var models: [String: Any] = [:]
        for id in ids { models[id] = ["name": id.components(separatedBy: "/").last ?? id] }
        let config: [String: Any] = [
            "$schema": "https://opencode.ai/config.json",
            "model": "millfolio/" + first,
            "provider": ["millfolio": [
                "npm": "@ai-sdk/openai-compatible",
                "name": "millfolio (local)",
                "options": ["baseURL": baseURL, "apiKey": "millfolio"],
                "models": models,
            ]],
        ]
        let out = cacheDir.appendingPathComponent("opencode.json")
        let blob = try JSONSerialization.data(withJSONObject: config, options: [.prettyPrinted])
        try blob.write(to: out)
        return out.path
    }

    // ── steps ────────────────────────────────────────────────────────────────
    private func download(_ url: URL, name: String) async throws -> URL {
        let dest = cacheDir.appendingPathComponent(name)
        let (tmp, resp) = try await URLSession.shared.download(from: url)
        guard (resp as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) ?? false else {
            throw BootstrapError.step("download \(name)", "HTTP error fetching \(url.absoluteString)")
        }
        try? FileManager.default.removeItem(at: dest)
        try FileManager.default.moveItem(at: tmp, to: dest)
        return dest
    }

    /// A `.conda` is a zip containing `pkg-*.tar.zst` (the files) + `info-*.tar.zst`.
    /// We unzip it (native), zstd-decompress each payload IN-PROCESS via the
    /// vendored decoder, then untar the resulting plain `.tar`. The two-step
    /// avoids `tar`'s zstd filter, which on macOS shells out to a `zstd` program
    /// that isn't installed (libarchive here is built without built-in zstd).
    private func extractConda(_ conda: URL, into prefix: URL) throws {
        let scratch = cacheDir.appendingPathComponent("conda-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        try run("/usr/bin/unzip", ["-o", "-q", conda.path, "-d", scratch.path])
        let entries = try FileManager.default.contentsOfDirectory(atPath: scratch.path)
        let pkgs = entries.filter { $0.hasPrefix("pkg-") && $0.hasSuffix(".tar.zst") }
        guard !pkgs.isEmpty else { throw BootstrapError.step("extract", "no pkg tar in \(conda.lastPathComponent)") }
        for pkg in pkgs {
            let zst = scratch.appendingPathComponent(pkg)
            let tar = scratch.appendingPathComponent(String(pkg.dropLast(4)))   // strip ".zst"
            try Zstd.decompressFile(zst, to: tar)
            // Plain (uncompressed) tar — core libarchive, no optional filter.
            try run("/usr/bin/tar", ["-xf", tar.path, "-C", prefix.path])
        }
    }

    private func unpackZip(_ zip: URL, into dir: URL) throws {
        try run("/usr/bin/unzip", ["-o", "-q", zip.path, "-d", dir.path])
        guard FileManager.default.fileExists(atPath: backendDir.appendingPathComponent("src/server.mojo").path) else {
            throw BootstrapError.step("unpack", "engine zip missing inference-server/src/server.mojo")
        }
    }

    /// Find an existing Python >= 3.10 on the system (we do NOT download one).
    private func findPython() throws -> URL {
        let candidates = ["/opt/homebrew/bin/python3", "/usr/local/bin/python3", "/usr/bin/python3"]
            + (ProcessInfo.processInfo.environment["PATH"]?.split(separator: ":").map { String($0) + "/python3" } ?? [])
        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            if let v = try? run(path, ["-c", "import sys;print(sys.version_info[0],sys.version_info[1])"]) {
                let parts = v.split(separator: " ").compactMap { Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
                if parts.count == 2, parts[0] == 3, parts[1] >= 10 { return URL(fileURLWithPath: path) }
            }
        }
        throw BootstrapError.step("python", "no Python >= 3.10 found on PATH (Mojo needs one; install one or add it to PATH)")
    }

    private func findOpencode() throws -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        // A GUI app's PATH is minimal and excludes per-user install dirs, so check
        // the common ones explicitly (opencode installs to ~/.opencode/bin).
        let candidates = [
            "\(home)/.opencode/bin/opencode",
            "\(home)/.local/bin/opencode",
            "/opt/homebrew/bin/opencode",
            "/usr/local/bin/opencode",
        ] + (ProcessInfo.processInfo.environment["PATH"]?.split(separator: ":").map { String($0) + "/opencode" } ?? [])
        for path in candidates where FileManager.default.isExecutableFile(atPath: path) { return path }
        throw BootstrapError.step("opencode", "opencode not found — install it (https://opencode.ai) or add it to PATH")
    }

    /// Env for invoking `mojo build`. What conda's activation script exports — the
    /// compiler reads $MODULAR_HOME/modular.cfg for its stdlib import path + libs.
    private func mojoEnv(python: URL) -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        let extraPath = "\(python.deletingLastPathComponent().path):\(mojoPrefix.appendingPathComponent("bin").path)"
        env["PATH"] = extraPath + ":" + (env["PATH"] ?? "/usr/bin:/bin")
        env["CONDA_PREFIX"] = mojoPrefix.path
        env["MODULAR_HOME"] = mojoPrefix.appendingPathComponent("share/max").path
        return env
    }

    /// Env for *running* the compiled Mojo binaries (download) — the opposite of
    /// the build env: keep CONDA_PREFIX unset so flare loads `build/libflare_tls.so`
    /// next to the binary (cwd) rather than `$CONDA_PREFIX/lib`, and point OpenSSL
    /// at the system CA bundle (the bundled libssl's compiled-in cert path is the
    /// CI prefix, which is absent here).
    private func runtimeEnv() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        env.removeValue(forKey: "CONDA_PREFIX")
        env.removeValue(forKey: "MODULAR_HOME")
        if FileManager.default.fileExists(atPath: "/etc/ssl/cert.pem") {
            env["SSL_CERT_FILE"] = "/etc/ssl/cert.pem"
        }
        return env
    }

    /// conda packages bake a placeholder install path into `share/max/modular.cfg`
    /// (the value of `package_root`), normally rewritten by conda's prefix-
    /// replacement step — which we skip by extracting the `.conda` by hand. Rewrite
    /// it to our real prefix so the compiler can locate the stdlib (`import_path`)
    /// and link the runtime libs (rpath). Idempotent; safe to run every time.
    private func relocateMojoPrefix(_ prefix: URL) throws {
        let cfg = prefix.appendingPathComponent("share/max/modular.cfg")
        guard var text = try? String(contentsOf: cfg, encoding: .utf8) else {
            throw BootstrapError.step("relocate", "modular.cfg missing after extract")
        }
        guard let line = text.split(separator: "\n").first(where: { $0.hasPrefix("package_root") }),
              let eq = line.firstIndex(of: "=") else {
            throw BootstrapError.step("relocate", "no package_root in modular.cfg")
        }
        let placeholder = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
        guard !placeholder.isEmpty, placeholder != prefix.path else { return }  // already done
        text = text.replacingOccurrences(of: placeholder, with: prefix.path)
        try text.write(to: cfg, atomically: true, encoding: .utf8)
        appendLog("relocated mojo prefix: \(placeholder) -> \(prefix.path)\n")
    }

    private func buildBinary(python: URL, source: String, args: [String], out: String) throws {
        let mojo = mojoPrefix.appendingPathComponent("bin/mojo").path
        // flare's libflare_tls.so ships at inference-server/build/ relative to cwd.
        try run(mojo, ["build", source] + args + ["-o", out], cwd: backendDir, env: mojoEnv(python: python))
    }

    /// `mojo build` ad-hoc "linker-signs" the server with the identifier "server".
    /// macOS's "<name> can run in the background" notification + Login Items entry
    /// for the LaunchAgent take that signing identifier as the name, so re-sign it
    /// (still ad-hoc) as "millfolio". Best-effort — purely cosmetic, so a failure
    /// never blocks the install.
    private func signServerIdentity() {
        do {
            try run("/usr/bin/codesign",
                    ["--force", "--sign", "-", "--identifier", "millfolio", serverBin.path])
        } catch {
            appendLog("could not re-sign server identity (cosmetic): \(humanError(error))\n")
        }
    }

    private func downloadWeights(_ modelID: String) throws {
        let dl = backendDir.appendingPathComponent("build/download").path
        var env = runtimeEnv()
        env["HF_HOME"] = hfHome.path
        try run(dl, [modelID], cwd: backendDir, env: env)
    }

    // ── helpers ────────────────────────────────────────────────────────────────
    @discardableResult
    private func run(_ launch: String, _ args: [String], cwd: URL? = nil, env: [String: String]? = nil) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: launch)
        p.arguments = args
        if let cwd { p.currentDirectoryURL = cwd }
        if let env { p.environment = env }
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        appendLog("\n$ \(launch) \(args.joined(separator: " "))\n")
        try p.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let out = String(data: data, encoding: .utf8) ?? ""
        appendLog(out)
        if p.terminationStatus != 0 {
            appendLog("\n[\(URL(fileURLWithPath: launch).lastPathComponent) exited \(p.terminationStatus)]\n")
            throw BootstrapError.step(URL(fileURLWithPath: launch).lastPathComponent,
                                      "exit \(p.terminationStatus): " + out.suffix(500))
        }
        return out
    }

    /// Like `run`, but returns the exit status instead of throwing on nonzero —
    /// for probes (launchctl print/bootout) where a nonzero code is expected.
    @discardableResult
    private func runStatus(_ launch: String, _ args: [String]) throws -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: launch)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        try p.run()
        _ = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return p.terminationStatus
    }

    // ── phase / progress sink ───────────────────────────────────────────────────
    private func set(_ msg: String) {
        phase = .running(msg)
        onProgress?(msg)
    }
    private func set(done: Bool) { phase = .done }
    private func set(failed msg: String) { phase = .failed(msg) }
}

public enum BootstrapError: Error, CustomStringConvertible {
    case step(String, String)
    public var description: String {
        switch self { case .step(let s, let m): return "\(s): \(m)" }
    }
}

func humanError(_ error: Error) -> String {
    if let b = error as? BootstrapError { return b.description }
    return (error as NSError).localizedDescription
}
