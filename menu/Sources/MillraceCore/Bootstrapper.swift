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
/// Everything lives under ~/Library/Application Support/Millrace, including the
/// model weights (HF_HOME=<support>/hf), so uninstall is a single directory.
///
/// This type is UI-agnostic on purpose: the menu-bar app observes it as an
/// `ObservableObject` (via `phase`/`serverRunning`), while the `millrace` CLI
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
    public static let mojoVersion = "1.0.0b2.dev2026053106"
    public static let condaChannel = "https://conda.modular.com/max-nightly"
    /// Default model served by the server. The 3B is int4-friendly and the
    /// quality target; its tokenizer.json is read directly by the engine.
    public static let model = "Qwen/Qwen2.5-3B-Instruct"
    public static let modelSlug = "Qwen--Qwen2.5-3B-Instruct"

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
        URL(string: "https://github.com/millrace/inference-server/releases/latest/download/runner.zip")!

    // ── headgate (privacy harness) ─────────────────────────────────────────────
    // headgate is a separate engine on a DIFFERENT Mojo nightly than the server
    // (its flare/json forks don't build on the server's), so it gets its own
    // toolchain + install tree. It's a one-shot CLI (not a daemon), so "start"
    // opens a ready-to-use Terminal rather than launching a server.
    public static let headgateMojoVersion = "1.0.0b2.dev2026060706"
    private let headgateZipURL =
        URL(string: "https://github.com/millrace/headgate/releases/latest/download/headgate.zip")!
    private var headgateMojoCompilerURL: URL {
        URL(string: "\(Self.condaChannel)/osx-arm64/mojo-compiler-\(Self.headgateMojoVersion)-release.conda")!
    }
    private var headgateMojoPythonURL: URL {
        URL(string: "\(Self.condaChannel)/noarch/mojo-python-\(Self.headgateMojoVersion)-release.conda")!
    }
    private var headgateMojoPrefix: URL { support.appendingPathComponent("headgate-mojo", isDirectory: true) }
    private var headgateRoot: URL { support.appendingPathComponent("headgate-engine", isDirectory: true) }
    /// headgate checkout inside the unpacked bundle (sibling of flare/json/jinja2.mojo).
    private var headgateDir: URL { headgateRoot.appendingPathComponent("headgate", isDirectory: true) }
    private var headgateBin: URL { headgateDir.appendingPathComponent("build/headgate") }
    /// The built headgate binary is present.
    public var isHeadgateInstalled: Bool { FileManager.default.isExecutableFile(atPath: headgateBin.path) }

    // ── dacular (personal data vault) ───────────────────────────────────────────
    // dacular is a one-shot vault CLI built on the SAME Mojo nightly as headgate.
    // Its bundle vendors the toolbox (flare/json + the LanceDB binding + pdftotext/
    // zlib readers) + prebuilt FFI shims, so the on-device build is
    // `mojo build src/dacular.mojo -I ../flare -I … ` then installDacularShims().
    private let dacularZipURL =
        URL(string: "https://github.com/millrace/dacular/releases/latest/download/dacular.zip")!
    private var dacularMojoCompilerURL: URL {
        URL(string: "\(Self.condaChannel)/osx-arm64/mojo-compiler-\(Self.headgateMojoVersion)-release.conda")!
    }
    private var dacularMojoPythonURL: URL {
        URL(string: "\(Self.condaChannel)/noarch/mojo-python-\(Self.headgateMojoVersion)-release.conda")!
    }
    private var dacularMojoPrefix: URL { support.appendingPathComponent("dacular-mojo", isDirectory: true) }
    private var dacularRoot: URL { support.appendingPathComponent("dacular-engine", isDirectory: true) }
    /// dacular checkout inside the unpacked bundle.
    private var dacularDir: URL { dacularRoot.appendingPathComponent("dacular", isDirectory: true) }
    private var dacularBin: URL { dacularDir.appendingPathComponent("build/dacular") }
    /// The built dacular binary is present.
    public var isDacularInstalled: Bool { FileManager.default.isExecutableFile(atPath: dacularBin.path) }

    // ── default config files (~/.config) ───────────────────────────────────────
    // Seeded with sensible defaults on install if absent, so a fresh setup has an
    // editable starting point. The engines read these (millrace = inference-server,
    // headgate = headgate); we NEVER overwrite an existing file.
    private var dotConfig: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config", isDirectory: true)
    }
    private var millraceConfigURL: URL { dotConfig.appendingPathComponent("millrace/config.json") }
    private var headgateConfigURL: URL { dotConfig.appendingPathComponent("headgate/config.json") }

    private static let millraceConfigDefault = """
    {
      "port": 8000,
      "model": "Qwen/Qwen2.5-3B-Instruct",
      "q4": false,
      "kv_budget_mb": 8192
    }
    """
    private static let headgateConfigDefault = """
    {
      "local_url": "http://127.0.0.1:8000/v1",
      "local_model": "Qwen2.5-0.5B-Instruct",
      "remote_base_url": "https://api.anthropic.com/v1",
      "remote_model": "claude-sonnet-4-6",
      "remote_token_budget": 200000,
      "mock": false,
      "use_local_summary": false,
      "data_dir": ""
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
            .appendingPathComponent("Millrace", isDirectory: true)
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
    public var logFileURL: URL { support.appendingPathComponent("Millrace.log") }
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
    /// Ready to launch: engine built and weights downloaded.
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

    /// Provision the Mojo toolchain, engine source, build, and weights. Throws on
    /// the first failure (the CLI surfaces it; the menu wrapper maps it to `phase`).
    public func installServer() async throws {
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

        if !weightsPresent {
            set("Building downloader…")
            try buildBinary(python: python, source: "src/download.mojo",
                            args: ["-I", "../flare"], out: "build/download")
            set("Downloading model weights (\(Self.model), several GB)…")
            try downloadWeights()
        }

        ensureConfig(at: millraceConfigURL, Self.millraceConfigDefault)
    }

    // ── step 2: start / stop server (launchd LaunchAgent) ────────────────────────
    // The server runs as a per-user LaunchAgent (me.millrace.server) instead of a
    // child Process, so a CLI `millrace server start` and the menu app's "Start
    // server" drive the SAME managed process — either surface can start/stop/see it.
    public static let serverLabel = "me.millrace.server"
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
        export OPENAI_API_KEY="millrace"
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
            "model": "millrace/" + first,
            "provider": ["millrace": [
                "npm": "@ai-sdk/openai-compatible",
                "name": "millrace (local)",
                "options": ["baseURL": baseURL, "apiKey": "millrace"],
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
    /// (still ad-hoc) as "millrace". Best-effort — purely cosmetic, so a failure
    /// never blocks the install.
    private func signServerIdentity() {
        do {
            try run("/usr/bin/codesign",
                    ["--force", "--sign", "-", "--identifier", "millrace", serverBin.path])
        } catch {
            appendLog("could not re-sign server identity (cosmetic): \(humanError(error))\n")
        }
    }

    private func downloadWeights() throws {
        let dl = backendDir.appendingPathComponent("build/download").path
        var env = runtimeEnv()
        env["HF_HOME"] = hfHome.path
        try run(dl, [Self.model], cwd: backendDir, env: env)
    }

    // ── headgate: install ──────────────────────────────────────────────────────
    /// Menu-app entry point: fire-and-forget, drives `phase`.
    public func installHeadgate() {
        guard !isBusy else { return }
        phase = .running("Starting…")
        Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            do { try await self.installHeadgateEngine(); await self.set(done: true) }
            catch { await self.set(failed: humanError(error)) }
        }
    }

    /// Download headgate's Mojo toolchain + source bundle and build it. Separate
    /// from the server: headgate is on a different nightly and ships its own
    /// vendored flare/json/jinja2.mojo + prebuilt FFI shims.
    public func installHeadgateEngine() async throws {
        let fm = FileManager.default
        for d in [support, headgateMojoPrefix, headgateRoot, cacheDir] {
            try fm.createDirectory(at: d, withIntermediateDirectories: true)
        }
        logHeader("Install headgate")

        // 1. Mojo toolchain (headgate's nightly — distinct from the engine's).
        if !fm.fileExists(atPath: headgateMojoPrefix.appendingPathComponent("bin/mojo").path) {
            set("Downloading Mojo compiler for headgate (~70 MB)…")
            let compiler = try await download(headgateMojoCompilerURL, name: "headgate-mojo-compiler.conda")
            set("Extracting Mojo…")
            try extractConda(compiler, into: headgateMojoPrefix)
            let py = try await download(headgateMojoPythonURL, name: "headgate-mojo-python.conda")
            try extractConda(py, into: headgateMojoPrefix)
        }
        try relocateMojoPrefix(headgateMojoPrefix)

        // 2. headgate source bundle (headgate + vendored flare/json/jinja2.mojo +
        //    prebuilt FFI shims), published by headgate CI.
        set("Downloading headgate source…")
        let zip = try await download(headgateZipURL, name: "headgate.zip")
        set("Unpacking headgate…")
        try run("/usr/bin/unzip", ["-o", "-q", zip.path, "-d", headgateRoot.path])
        guard fm.fileExists(atPath: headgateDir.appendingPathComponent("src/headgate.mojo").path) else {
            throw BootstrapError.step("unpack", "headgate zip missing headgate/src/headgate.mojo")
        }

        // 3. Build headgate against its vendored siblings.
        set("Locating Python…")
        let python = try findPython()
        set("Building headgate (first run, ~1 min)…")
        let mojo = headgateMojoPrefix.appendingPathComponent("bin/mojo").path
        try run(mojo, ["build", "src/headgate.mojo",
                       "-I", "../flare", "-I", "../json", "-I", "../jinja2.mojo/src",
                       "-o", "build/headgate"],
                cwd: headgateDir, env: headgateMojoEnv(python: python))
        // The HTTP server for the web UI (serves web/dist + POST /chat on :10000).
        set("Building headgate web server…")
        try run(mojo, ["build", "src/server.mojo",
                       "-I", "../flare", "-I", "../json", "-I", "../jinja2.mojo/src",
                       "-o", "build/headgate-server"],
                cwd: headgateDir, env: headgateMojoEnv(python: python))

        // 4. Put the bundle's FFI shims under the toolchain's lib/, so flare finds
        //    them via $CONDA_PREFIX/lib at runtime — headgate runs WITH CONDA_PREFIX
        //    set (it shells `mojo build` for the sandboxed generated-code compile),
        //    unlike the always-serving server.
        try installHeadgateShims()
        ensureConfig(at: headgateConfigURL, Self.headgateConfigDefault)
    }

    /// Copy the bundled relocatable FFI shims (+ their dylib deps) into the headgate
    /// Mojo prefix's lib/, where flare's `$CONDA_PREFIX/lib` lookup finds them.
    private func installHeadgateShims() throws {
        let fm = FileManager.default
        let libDir = headgateMojoPrefix.appendingPathComponent("lib", isDirectory: true)
        try fm.createDirectory(at: libDir, withIntermediateDirectories: true)
        let buildDir = headgateDir.appendingPathComponent("build", isDirectory: true)
        for name in (try? fm.contentsOfDirectory(atPath: buildDir.path)) ?? []
        where name.hasSuffix(".so") || name.hasSuffix(".dylib") {
            let dst = libDir.appendingPathComponent(name)
            try? fm.removeItem(at: dst)
            try fm.copyItem(at: buildDir.appendingPathComponent(name), to: dst)
        }
    }

    /// `mojo build` env for the headgate toolchain prefix.
    private func headgateMojoEnv(python: URL) -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        let extraPath = "\(python.deletingLastPathComponent().path):\(headgateMojoPrefix.appendingPathComponent("bin").path)"
        env["PATH"] = extraPath + ":" + (env["PATH"] ?? "/usr/bin:/bin")
        env["CONDA_PREFIX"] = headgateMojoPrefix.path
        env["MODULAR_HOME"] = headgateMojoPrefix.appendingPathComponent("share/max").path
        return env
    }

    // ── headgate: start (open a ready-to-use Terminal) ──────────────────────────
    /// headgate is a one-shot CLI, so "start" opens a Terminal in the install dir
    /// with the toolchain env pre-set — the user sets ANTHROPIC_API_KEY, points it
    /// at their data, and runs `./build/headgate`.
    public func startHeadgate() {
        Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            do { try await self.launchHeadgateTerminal() }
            catch { await self.set(failed: "headgate: \(humanError(error))") }
        }
    }

    /// Write the `run-headgate.sh` launcher — sets the toolchain env (headgate
    /// shells `mojo build` for the sandboxed generated-code compile), cd's to the
    /// install dir, and execs the headgate binary, forwarding any args (`"$@"`) as
    /// the task. Shared by the menu app (runs it in a NEW Terminal) and the CLI
    /// (execs it in the CURRENT terminal so headgate takes over stdin/stdout — a
    /// one-shot run with a task, or an interactive REPL with none). Returns its path.
    @discardableResult
    public func writeHeadgateScript() throws -> URL {
        let mojoBin = headgateMojoPrefix.appendingPathComponent("bin").path
        let modularHome = headgateMojoPrefix.appendingPathComponent("share/max").path
        // Single-quote paths (they live under "Application Support" — note the space).
        let script = support.appendingPathComponent("run-headgate.sh")
        let body = """
        #!/bin/bash
        cd '\(headgateDir.path)'
        export CONDA_PREFIX='\(headgateMojoPrefix.path)'
        export MODULAR_HOME='\(modularHome)'
        export PATH='\(mojoBin)':"$PATH"
        # flare's bundled OpenSSL has a CI-baked CA path; point it at the system
        # bundle so HTTPS to the Anthropic API verifies (else CertificateUntrusted).
        [ -f /etc/ssl/cert.pem ] && export SSL_CERT_FILE='/etc/ssl/cert.pem'
        exec ./build/headgate "$@"
        """
        try body.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        return script
    }

    public func launchHeadgateTerminal() async throws {
        let script = try writeHeadgateScript()
        let cmd = "'\(script.path)'"
        try run("/usr/bin/osascript",
                ["-e", "tell application \"Terminal\" to activate",
                 "-e", "tell application \"Terminal\" to do script \"\(cmd)\""])
    }

    // ── headgate: web (server on :10000 + open the browser) ─────────────────────
    /// Write the `run-headgate-web.sh` launcher: set the toolchain env, start the
    /// HTTP server (which serves the built web UI + the /chat API on :10000), and
    /// open the browser at it. Shared by the menu app (new Terminal) and the CLI
    /// (execs it in the current terminal). Returns its path.
    @discardableResult
    public func writeHeadgateWebScript() throws -> URL {
        let mojoBin = headgateMojoPrefix.appendingPathComponent("bin").path
        let modularHome = headgateMojoPrefix.appendingPathComponent("share/max").path
        let script = support.appendingPathComponent("run-headgate-web.sh")
        let body = """
        #!/bin/bash
        cd '\(headgateDir.path)'
        export CONDA_PREFIX='\(headgateMojoPrefix.path)'
        export MODULAR_HOME='\(modularHome)'
        export PATH='\(mojoBin)':"$PATH"
        # flare's bundled OpenSSL has a CI-baked CA path; use the system bundle.
        [ -f /etc/ssl/cert.pem ] && export SSL_CERT_FILE='/etc/ssl/cert.pem'
        # serve-web.sh: bind 127.0.0.1:10000, open the UI, and expose it on the
        # tailnet via `tailscale serve` when Tailscale is available (else localhost).
        exec bash scripts/serve-web.sh
        """
        try body.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        return script
    }

    /// Menu-app entry point: open the headgate web app in a new Terminal.
    public func startHeadgateWeb() {
        Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            do { try await self.launchHeadgateWebTerminal() }
            catch { await self.set(failed: "headgate web: \(humanError(error))") }
        }
    }

    public func launchHeadgateWebTerminal() async throws {
        let script = try writeHeadgateWebScript()
        let cmd = "'\(script.path)'"
        try run("/usr/bin/osascript",
                ["-e", "tell application \"Terminal\" to activate",
                 "-e", "tell application \"Terminal\" to do script \"\(cmd)\""])
    }

    /// Stop the headgate web server (started by `headgate web`). It runs as a
    /// foreground process (not a launchd agent), so terminate it by name —
    /// killing the server makes serve-web.sh's own `wait` return and its cleanup
    /// trap tear down any `tailscale serve` mapping. Returns true if one was
    /// running. Best-effort; never throws.
    @discardableResult
    public func stopHeadgateWeb() -> Bool {
        // pkill exits 0 if it signaled at least one process, 1 if none matched.
        let hit = (try? runStatus("/usr/bin/pkill", ["-f", "build/headgate-server"])) == 0
        _ = try? runStatus("/usr/bin/pkill", ["-f", "scripts/serve-web.sh"])
        return hit
    }

    // ── dacular: install ────────────────────────────────────────────────────────
    /// Menu-app entry point: fire-and-forget, drives `phase`.
    public func installDacular() {
        guard !isBusy else { return }
        phase = .running("Starting…")
        Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            do { try await self.installDacularEngine(); await self.set(done: true) }
            catch { await self.set(failed: humanError(error)) }
        }
    }

    /// Download dacular's Mojo toolchain + source bundle and build it. Same nightly
    /// as headgate; the bundle vendors flare/json + the LanceDB binding + pdftotext/
    /// zlib + prebuilt FFI shims, so the build uses `-I` includes + installs shims.
    public func installDacularEngine() async throws {
        let fm = FileManager.default
        for d in [support, dacularMojoPrefix, dacularRoot, cacheDir] {
            try fm.createDirectory(at: d, withIntermediateDirectories: true)
        }
        logHeader("Install dacular")

        // 1. Mojo toolchain (same nightly as headgate).
        if !fm.fileExists(atPath: dacularMojoPrefix.appendingPathComponent("bin/mojo").path) {
            set("Downloading Mojo compiler for dacular (~70 MB)…")
            let compiler = try await download(dacularMojoCompilerURL, name: "dacular-mojo-compiler.conda")
            set("Extracting Mojo…")
            try extractConda(compiler, into: dacularMojoPrefix)
            let py = try await download(dacularMojoPythonURL, name: "dacular-mojo-python.conda")
            try extractConda(py, into: dacularMojoPrefix)
        }
        try relocateMojoPrefix(dacularMojoPrefix)

        // 2. dacular source bundle (just source — no FFI/sibling deps yet).
        set("Downloading dacular source…")
        let zip = try await download(dacularZipURL, name: "dacular.zip")
        set("Unpacking dacular…")
        try run("/usr/bin/unzip", ["-o", "-q", zip.path, "-d", dacularRoot.path])
        guard fm.fileExists(atPath: dacularDir.appendingPathComponent("src/dacular.mojo").path) else {
            throw BootstrapError.step("unpack", "dacular zip missing dacular/src/dacular.mojo")
        }

        // 3. Build dacular against its vendored siblings (flare/json + the LanceDB
        //    binding + pdftotext/zlib readers), all bundled by package_dacular.sh.
        set("Locating Python…")
        let python = try findPython()
        set("Building dacular (first run, ~1 min)…")
        let mojo = dacularMojoPrefix.appendingPathComponent("bin/mojo").path
        try run(mojo, ["build", "src/dacular.mojo",
                       "-I", "../flare", "-I", "../json", "-I", "../lancedb.mojo/src",
                       "-I", "../pdftotext.mojo/src", "-I", "../zlib.mojo/src",
                       "-o", "build/dacular"],
                cwd: dacularDir, env: dacularMojoEnv(python: python))

        // 4. Put the bundle's FFI shims (libzlibmojo / liblancedbmojo / libflare_*
        //    + their dylib deps) under the toolchain's lib/, where each binding's
        //    `$CONDA_PREFIX/lib` lookup finds them at runtime (dacular runs WITH
        //    CONDA_PREFIX set via run-dacular.sh).
        try installDacularShims()
    }

    /// Copy the bundled relocatable FFI shims (+ their dylib deps) into the dacular
    /// Mojo prefix's lib/, where flare/zlib/lancedb's `$CONDA_PREFIX/lib` lookup
    /// finds them. Mirrors installHeadgateShims.
    private func installDacularShims() throws {
        let fm = FileManager.default
        let libDir = dacularMojoPrefix.appendingPathComponent("lib", isDirectory: true)
        try fm.createDirectory(at: libDir, withIntermediateDirectories: true)
        let buildDir = dacularDir.appendingPathComponent("build", isDirectory: true)
        for name in (try? fm.contentsOfDirectory(atPath: buildDir.path)) ?? []
        where name.hasSuffix(".so") || name.hasSuffix(".dylib") {
            let dst = libDir.appendingPathComponent(name)
            try? fm.removeItem(at: dst)
            try fm.copyItem(at: buildDir.appendingPathComponent(name), to: dst)
        }
    }

    /// `mojo build` env for the dacular toolchain prefix.
    private func dacularMojoEnv(python: URL) -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        let extraPath = "\(python.deletingLastPathComponent().path):\(dacularMojoPrefix.appendingPathComponent("bin").path)"
        env["PATH"] = extraPath + ":" + (env["PATH"] ?? "/usr/bin:/bin")
        env["CONDA_PREFIX"] = dacularMojoPrefix.path
        env["MODULAR_HOME"] = dacularMojoPrefix.appendingPathComponent("share/max").path
        return env
    }

    // ── dacular: start (open a ready-to-use Terminal) ───────────────────────────
    /// dacular is a one-shot vault CLI, so "start" opens a Terminal in the install
    /// dir with the toolchain env pre-set — the user runs e.g.
    /// `./build/dacular manifest ~/dacular`.
    public func startDacular() {
        Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            do { try await self.launchDacularTerminal() }
            catch { await self.set(failed: "dacular: \(humanError(error))") }
        }
    }

    /// Write the `run-dacular.sh` launcher — sets the toolchain env, cd's to the
    /// install dir, and execs the dacular binary forwarding any args (`"$@"`).
    /// Shared by the menu app (new Terminal) and the CLI (execs in the current
    /// terminal). Returns its path.
    @discardableResult
    public func writeDacularScript() throws -> URL {
        let mojoBin = dacularMojoPrefix.appendingPathComponent("bin").path
        let modularHome = dacularMojoPrefix.appendingPathComponent("share/max").path
        let script = support.appendingPathComponent("run-dacular.sh")
        let body = """
        #!/bin/bash
        cd '\(dacularDir.path)'
        export CONDA_PREFIX='\(dacularMojoPrefix.path)'
        export MODULAR_HOME='\(modularHome)'
        export PATH='\(mojoBin)':"$PATH"
        exec ./build/dacular "$@"
        """
        try body.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        return script
    }

    public func launchDacularTerminal() async throws {
        let script = try writeDacularScript()
        let cmd = "'\(script.path)'"
        try run("/usr/bin/osascript",
                ["-e", "tell application \"Terminal\" to activate",
                 "-e", "tell application \"Terminal\" to do script \"\(cmd)\""])
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
