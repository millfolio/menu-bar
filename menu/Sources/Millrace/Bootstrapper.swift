import Foundation

/// One-click engine bootstrap: fetch the official Mojo compiler+runtime straight
/// from Modular's conda channel (so the *user* accepts Modular's license — we
/// never redistribute it), unpack our engine source zip (mojo-backend + minja2 +
/// flare + a prebuilt libflare_tls.so), build it with `mojo build` using the
/// system Python, and launch the server. The menu's MillraceClient then sees
/// `/v1/version` come up.
///
/// Everything lives under ~/Library/Application Support/Millrace.
///
/// NOTE: this is the "rattler-by-URL" approach — we don't link the rattler crate,
/// we just GET the pinned `.conda` packages (a .conda is a zip of zstd tarballs)
/// and extract them ourselves with the system `unzip`/`tar`. Keep `mojoVersion`
/// in sync with mojo-backend's pixi.lock.
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
            case .failed(let e): return "Install failed: \(e)"
            }
        }
    }

    @Published var phase: Phase = .idle
    var isBusy: Bool { if case .running = phase { return true }; return false }

    // ── pinned manifest (keep in sync with mojo-backend/pixi.lock) ─────────────
    static let mojoVersion = "1.0.0b2.dev2026053106"
    static let condaChannel = "https://conda.modular.com/max-nightly"
    private var mojoCompilerURL: URL {
        URL(string: "\(Self.condaChannel)/osx-arm64/mojo-compiler-\(Self.mojoVersion)-release.conda")!
    }
    private var mojoPythonURL: URL {
        URL(string: "\(Self.condaChannel)/noarch/mojo-python-\(Self.mojoVersion)-release.conda")!
    }
    /// The engine source bundle (mojo-backend + vendored minja2/flare + prebuilt
    /// libflare_tls.so), published by mojo-backend CI. Layout assumed below.
    private let engineZipURL =
        URL(string: "https://github.com/millrace/mojo-backend/releases/latest/download/millrace-engine.zip")!

    // ── install locations ─────────────────────────────────────────────────────
    private var support: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Millrace", isDirectory: true)
    }
    private var mojoPrefix: URL { support.appendingPathComponent("mojo", isDirectory: true) }
    private var engineRoot: URL { support.appendingPathComponent("engine", isDirectory: true) }
    private var cacheDir: URL { support.appendingPathComponent("cache", isDirectory: true) }
    /// mojo-backend checkout inside the unpacked engine zip.
    private var backendDir: URL { engineRoot.appendingPathComponent("mojo-backend", isDirectory: true) }

    /// True if a built engine is already present (skip the build).
    var isInstalled: Bool {
        FileManager.default.isExecutableFile(atPath: backendDir.appendingPathComponent("build/server").path)
    }

    func installAndLaunch() {
        guard !isBusy else { return }
        phase = .running("Starting…")
        Task.detached(priority: .userInitiated) { [weak self] in
            await self?.run()
        }
    }

    // ── pipeline ───────────────────────────────────────────────────────────────
    private func run() async {
        do {
            let fm = FileManager.default
            for d in [support, mojoPrefix, engineRoot, cacheDir] {
                try fm.createDirectory(at: d, withIntermediateDirectories: true)
            }

            if !fm.fileExists(atPath: mojoPrefix.appendingPathComponent("bin/mojo").path) {
                await set("Downloading Mojo compiler (~70 MB)…")
                let compiler = try await download(mojoCompilerURL, name: "mojo-compiler.conda")
                await set("Extracting Mojo…")
                try extractConda(compiler, into: mojoPrefix)
                let py = try await download(mojoPythonURL, name: "mojo-python.conda")
                try extractConda(py, into: mojoPrefix)
            }

            await set("Downloading engine source…")
            let zip = try await download(engineZipURL, name: "millrace-engine.zip")
            await set("Unpacking engine…")
            try unpackZip(zip, into: engineRoot)

            await set("Locating Python…")
            let python = try findPython()

            await set("Building engine (first run, ~1 min)…")
            try buildEngine(python: python)

            await set("Starting engine…")
            try launchServer()

            await set(done: true)
        } catch {
            await MainActor.run { self.phase = .failed(humanError(error)) }
        }
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
    /// Unzip it, then extract every `pkg-*.tar.zst` into the prefix.
    private func extractConda(_ conda: URL, into prefix: URL) throws {
        let scratch = cacheDir.appendingPathComponent("conda-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        try run("/usr/bin/unzip", ["-o", "-q", conda.path, "-d", scratch.path])
        let entries = try FileManager.default.contentsOfDirectory(atPath: scratch.path)
        let pkgs = entries.filter { $0.hasPrefix("pkg-") && $0.hasSuffix(".tar.zst") }
        guard !pkgs.isEmpty else { throw BootstrapError.step("extract", "no pkg tar in \(conda.lastPathComponent)") }
        for pkg in pkgs {
            // bsdtar (macOS 12+) auto-detects zstd; -C extracts into the prefix root.
            try run("/usr/bin/tar", ["-xf", scratch.appendingPathComponent(pkg).path, "-C", prefix.path])
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

    private func buildEngine(python: URL) throws {
        let mojo = mojoPrefix.appendingPathComponent("bin/mojo").path
        var env = ProcessInfo.processInfo.environment
        // Put the chosen python + the mojo bin first so the toolchain finds them.
        let extraPath = "\(python.deletingLastPathComponent().path):\(mojoPrefix.appendingPathComponent("bin").path)"
        env["PATH"] = extraPath + ":" + (env["PATH"] ?? "/usr/bin:/bin")
        // flare looks for libflare_tls.so at $CONDA_PREFIX/lib else build/libflare_tls.so
        // relative to cwd — the zip ships it at mojo-backend/build/, so leave it.
        try run(mojo,
                ["build", "src/server.mojo", "-I", "../minja2/src", "-I", "../flare", "-o", "build/server"],
                cwd: backendDir, env: env)
    }

    private func launchServer() throws {
        let p = Process()
        p.executableURL = backendDir.appendingPathComponent("build/server")
        p.currentDirectoryURL = backendDir // hardcoded relative data paths resolve from here
        // NOTE: the server needs model weights (argv[1] or the meta.txt fixture).
        // Weights download is a separate step — TODO. For now it launches with the
        // bundled default; MillraceClient polls /v1/version to confirm readiness.
        try p.run()
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
        try p.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let out = String(data: data, encoding: .utf8) ?? ""
        if p.terminationStatus != 0 {
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
