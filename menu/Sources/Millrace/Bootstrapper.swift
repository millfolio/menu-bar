import Foundation
import AppKit

/// Drives the local engine lifecycle from the menu bar, as three explicit steps:
///
///   1. **Download runner** — fetch the official Mojo compiler+runtime from
///      Modular's conda channel (so the *user* accepts Modular's license — we
///      never redistribute it), unpack our engine source zip (mojo-backend +
///      minja2 + flare + a prebuilt libflare_tls.so), build the server with
///      `mojo build`, then download the default model's weights with the engine's
///      own native-Mojo downloader (no huggingface_hub).
///   2. **Start runner** — launch the built server against the downloaded model.
///   3. **Start opencode** — point opencode at the running server (new Terminal).
///
/// Everything lives under ~/Library/Application Support/Millrace, including the
/// model weights (HF_HOME=<support>/hf), so uninstall is a single directory.
///
/// NOTE: the Mojo fetch is "rattler-by-URL" — we don't link the rattler crate, we
/// GET the pinned `.conda` packages (a .conda is a zip of zstd tarballs) and
/// extract them with the system `unzip`/`tar`. Keep `mojoVersion` in sync with
/// mojo-backend/pixi.lock.
@MainActor
final class Bootstrapper: ObservableObject {
    enum Phase: Equatable {
        case idle
        case running(String)
        case done
        case failed(String)

        var message: String? {
            switch self {
            case .idle, .done: return nil
            case .running(let m): return m
            case .failed(let e): return "Failed: \(e)"
            }
        }
    }

    /// Progress of the long-running "Download runner" provisioning step.
    @Published var phase: Phase = .idle
    /// True while the engine server we launched is running.
    @Published var serverRunning = false

    var isBusy: Bool { if case .running = phase { return true }; return false }

    // ── pinned manifest (keep in sync with mojo-backend/pixi.lock) ─────────────
    static let mojoVersion = "1.0.0b2.dev2026053106"
    static let condaChannel = "https://conda.modular.com/max-nightly"
    /// Default model served by the runner. The 3B is int4-friendly and the
    /// quality target; its tokenizer.json is read directly by the engine.
    static let model = "Qwen/Qwen2.5-3B-Instruct"
    static let modelSlug = "Qwen--Qwen2.5-3B-Instruct"

    private var mojoCompilerURL: URL {
        URL(string: "\(Self.condaChannel)/osx-arm64/mojo-compiler-\(Self.mojoVersion)-release.conda")!
    }
    private var mojoPythonURL: URL {
        URL(string: "\(Self.condaChannel)/noarch/mojo-python-\(Self.mojoVersion)-release.conda")!
    }
    /// The engine ("runner") source bundle (mojo-backend + vendored minja2/flare +
    /// prebuilt libflare_tls.so), published by mojo-backend CI.
    private let runnerZipURL =
        URL(string: "https://github.com/millrace/mojo-backend/releases/latest/download/runner.zip")!

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
    /// mojo-backend checkout inside the unpacked engine zip.
    private var backendDir: URL { engineRoot.appendingPathComponent("mojo-backend", isDirectory: true) }
    private var serverBin: URL { backendDir.appendingPathComponent("build/server") }
    /// All subprocess output (mojo build, weights download, the running server)
    /// is appended here so errors that flash by in the menu can be read in full.
    var logFileURL: URL { support.appendingPathComponent("Millrace.log") }
    var hasLog: Bool { FileManager.default.fileExists(atPath: logFileURL.path) }

    /// The built engine server binary is present.
    var isRunnerInstalled: Bool {
        FileManager.default.isExecutableFile(atPath: serverBin.path)
    }
    /// The default model's weights have been fully downloaded (refs/main is the
    /// downloader's last write, so its presence means the snapshot is complete).
    var weightsPresent: Bool {
        FileManager.default.fileExists(
            atPath: hfHome.appendingPathComponent("hub/models--\(Self.modelSlug)/refs/main").path)
    }
    /// Ready to launch: engine built and weights downloaded.
    var canStartRunner: Bool { isRunnerInstalled && weightsPresent && !serverRunning }

    private var serverProcess: Process?

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
    func openLog() {
        NSWorkspace.shared.open(ensureLog())
    }

    // ── step 1: download runner (+ weights) ─────────────────────────────────────
    func downloadRunner() {
        guard !isBusy else { return }
        phase = .running("Starting…")
        Task.detached(priority: .userInitiated) { [weak self] in
            await self?.provision()
        }
    }

    private func provision() async {
        do {
            let fm = FileManager.default
            for d in [support, mojoPrefix, engineRoot, cacheDir, hfHome] {
                try fm.createDirectory(at: d, withIntermediateDirectories: true)
            }
            logHeader("Download runner")

            if !fm.fileExists(atPath: mojoPrefix.appendingPathComponent("bin/mojo").path) {
                await set("Downloading Mojo compiler (~70 MB)…")
                let compiler = try await download(mojoCompilerURL, name: "mojo-compiler.conda")
                await set("Extracting Mojo…")
                try extractConda(compiler, into: mojoPrefix)
                let py = try await download(mojoPythonURL, name: "mojo-python.conda")
                try extractConda(py, into: mojoPrefix)
            }
            try relocateMojo()   // rewrite modular.cfg's baked placeholder prefix

            await set("Downloading engine source…")
            let zip = try await download(runnerZipURL, name: "runner.zip")
            await set("Unpacking engine…")
            try unpackZip(zip, into: engineRoot)

            await set("Locating Python…")
            let python = try findPython()

            await set("Building engine (first run, ~1 min)…")
            try buildBinary(python: python, source: "src/server.mojo",
                            args: ["-I", "../minja2/src", "-I", "../flare"], out: "build/server")

            if !weightsPresent {
                await set("Building downloader…")
                try buildBinary(python: python, source: "src/download.mojo",
                                args: ["-I", "../flare"], out: "build/download")
                await set("Downloading model weights (\(Self.model), several GB)…")
                try downloadWeights()
            }

            await set(done: true)
        } catch {
            await MainActor.run { self.phase = .failed(humanError(error)) }
        }
    }

    // ── step 2: start / stop runner ─────────────────────────────────────────────
    func startRunner() {
        guard canStartRunner, serverProcess == nil else { return }
        do {
            let p = Process()
            p.executableURL = serverBin
            p.currentDirectoryURL = backendDir   // hardcoded relative data paths resolve here
            p.arguments = [Self.model]           // resolved from the HF cache below
            var env = runtimeEnv()
            env["HF_HOME"] = hfHome.path
            p.environment = env
            // Stream the server's stdout/stderr into the shared log.
            logHeader("Start runner: \(Self.model)")
            if let h = try? FileHandle(forWritingTo: ensureLog()) {
                h.seekToEndOfFile()
                p.standardOutput = h
                p.standardError = h
            }
            // terminationHandler is @Sendable and fires on an arbitrary thread.
            // Unwrap to a strong local first, then hop to the main actor — so the
            // concurrent Task captures an immutable `self`, not the closure's
            // captured weak `var` (a hard error under strict concurrency).
            p.terminationHandler = { [weak self] _ in
                guard let self else { return }
                Task { @MainActor in
                    self.serverProcess = nil
                    self.serverRunning = false
                }
            }
            try p.run()
            serverProcess = p
            serverRunning = true
        } catch {
            phase = .failed("start runner: \(humanError(error))")
        }
    }

    func stopRunner() {
        serverProcess?.terminate()
        serverProcess = nil
        serverRunning = false
    }

    // ── step 3: start opencode ──────────────────────────────────────────────────
    /// Generate an opencode config from the running server's /v1/models, then open
    /// opencode in a new Terminal window pointed at it. opencode is an interactive
    /// TUI, so it must run in a real terminal, not detached.
    func startOpencode() {
        Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            do { try await self.launchOpencode() }
            catch { await MainActor.run { self.phase = .failed("opencode: \(humanError(error))") } }
        }
    }

    private func launchOpencode() async throws {
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
        exec "\(opencode)"
        """
        try body.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        try run("/usr/bin/osascript",
                ["-e", "tell application \"Terminal\" to activate",
                 "-e", "tell application \"Terminal\" to do script \"\(script.path)\""])
    }

    /// Build the opencode provider config the way mojo-backend/opencode_config.py
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
            throw BootstrapError.step("opencode", "server not reachable at \(baseURL)/models — start the runner first")
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
            throw BootstrapError.step("unpack", "engine zip missing mojo-backend/src/server.mojo")
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
        let candidates = ["/opt/homebrew/bin/opencode", "/usr/local/bin/opencode"]
            + (ProcessInfo.processInfo.environment["PATH"]?.split(separator: ":").map { String($0) + "/opencode" } ?? [])
        for path in candidates where FileManager.default.isExecutableFile(atPath: path) { return path }
        throw BootstrapError.step("opencode", "opencode not found on PATH — install it (https://opencode.ai) first")
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

    /// Env for *running* the compiled Mojo binaries (download / server) — the
    /// opposite of the build env: keep CONDA_PREFIX unset so flare loads
    /// `build/libflare_tls.so` next to the binary (cwd) rather than
    /// `$CONDA_PREFIX/lib`, and point OpenSSL at the system CA bundle (the bundled
    /// libssl's compiled-in cert path is the CI prefix, which is absent here).
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
    private func relocateMojo() throws {
        let cfg = mojoPrefix.appendingPathComponent("share/max/modular.cfg")
        guard var text = try? String(contentsOf: cfg, encoding: .utf8) else {
            throw BootstrapError.step("relocate", "modular.cfg missing after extract")
        }
        guard let line = text.split(separator: "\n").first(where: { $0.hasPrefix("package_root") }),
              let eq = line.firstIndex(of: "=") else {
            throw BootstrapError.step("relocate", "no package_root in modular.cfg")
        }
        let placeholder = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
        guard !placeholder.isEmpty, placeholder != mojoPrefix.path else { return }  // already done
        text = text.replacingOccurrences(of: placeholder, with: mojoPrefix.path)
        try text.write(to: cfg, atomically: true, encoding: .utf8)
        appendLog("relocated mojo prefix: \(placeholder) -> \(mojoPrefix.path)\n")
    }

    private func buildBinary(python: URL, source: String, args: [String], out: String) throws {
        let mojo = mojoPrefix.appendingPathComponent("bin/mojo").path
        // flare's libflare_tls.so ships at mojo-backend/build/ relative to cwd.
        try run(mojo, ["build", source] + args + ["-o", out], cwd: backendDir, env: mojoEnv(python: python))
    }

    private func downloadWeights() throws {
        let dl = backendDir.appendingPathComponent("build/download").path
        var env = runtimeEnv()
        env["HF_HOME"] = hfHome.path
        try run(dl, [Self.model], cwd: backendDir, env: env)
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

    private func set(_ msg: String) async { await MainActor.run { self.phase = .running(msg) } }
    private func set(done: Bool) async { await MainActor.run { self.phase = .done } }
}

enum BootstrapError: Error, CustomStringConvertible {
    case step(String, String)
    var description: String {
        switch self { case .step(let s, let m): return "\(s): \(m)" }
    }
}

private func humanError(_ error: Error) -> String {
    if let b = error as? BootstrapError { return b.description }
    return (error as NSError).localizedDescription
}
