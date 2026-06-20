import Foundation
import Darwin
import ArgumentParser
import MillfolioCore

// The `millfolio` CLI — the same engine lifecycle the menu-bar app drives,
// on the command line. Backed by MillfolioCore.Bootstrapper, so the CLI and the app
// share one install tree (~/Library/Application Support/Millfolio) and one
// launchd-managed server (me.millfolio.server) — start from either, see it from both.
//
// Scope: the engine inference server only. The personal-data-vault umbrella
// (server + headgate + the dacular site) is its own tool now — the `dacular` CLI
// (github.com/dacularapp/cli).

@main
struct Millfolio: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "millfolio",
        abstract: "Install, run, and inspect the local engine inference server.",
        subcommands: [Install.self, Start.self, Stop.self, Status.self, Logs.self, Opencode.self]
    )
}

// ── millfolio install ─────────────────────────────────────────────────────────
struct Install: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Download the Mojo toolchain + engine, build it, and fetch model weights.")
    @MainActor func run() async throws {
        let boot = streaming()
        try await boot.installServer()
        print("✓ server installed")
    }
}

// ── millfolio start ───────────────────────────────────────────────────────────
struct Start: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Start the server as a launchd LaunchAgent (me.millfolio.server).")
    @MainActor func run() async throws {
        let boot = Bootstrapper()
        try boot.startServer()
        print("✓ server started — http://127.0.0.1:8000 (use `millfolio status`)")
    }
}

// ── millfolio stop ────────────────────────────────────────────────────────────
struct Stop: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Stop the server LaunchAgent.")
    @MainActor func run() async throws {
        let boot = Bootstrapper()
        try boot.stopServer()
        print("✓ server stopped")
    }
}

// ── millfolio status ──────────────────────────────────────────────────────────
struct Status: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Show install state and whether the server is running.")
    @MainActor func run() async throws {
        let boot = Bootstrapper()
        boot.refreshServerRunning()
        print("installed:  \(mark(boot.isServerInstalled))")
        print("weights:    \(mark(boot.weightsPresent))")
        print("launchd:    \(boot.serverRunning ? "loaded" : "not loaded")")
        if let v = await probeVersion() {
            print("serving:    online — v\(v.version) (\(v.model))")
        } else {
            print("serving:    offline (no response on http://127.0.0.1:8000)")
        }
    }
}

// ── millfolio logs ────────────────────────────────────────────────────────────
struct Logs: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Show the engine log.")
    @Flag(name: .shortAndLong, help: "Follow the log (tail -f).") var follow = false
    @MainActor func run() async throws {
        let log = Bootstrapper().logFileURL
        guard FileManager.default.fileExists(atPath: log.path) else {
            print("no log yet at \(log.path)"); return
        }
        // Hand off to `tail` so -f streams live and Ctrl-C just works.
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/tail")
        p.arguments = (follow ? ["-f", "-n", "40"] : ["-n", "200"]) + [log.path]
        try p.run()
        p.waitUntilExit()
    }
}

// ── millfolio opencode ────────────────────────────────────────────────────────
struct Opencode: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "opencode",
        abstract: "Open opencode in a new Terminal pointed at the running server.")
    @MainActor func run() async throws {
        try await Bootstrapper().launchOpencode()
    }
}

// ── helpers ──────────────────────────────────────────────────────────────────
/// A Bootstrapper that streams progress lines to stdout (for install commands).
@MainActor private func streaming() -> Bootstrapper {
    let boot = Bootstrapper()
    boot.onProgress = { print($0) }
    return boot
}

private func mark(_ ok: Bool) -> String { ok ? "yes" : "no" }

/// One-shot GET /v1/version, mirroring MillfolioClient.poll without the timer.
private func probeVersion() async -> (version: String, model: String)? {
    guard let url = URL(string: "http://127.0.0.1:8000/v1/version") else { return nil }
    var req = URLRequest(url: url); req.timeoutInterval = 3
    guard let (data, resp) = try? await URLSession.shared.data(for: req),
          (resp as? HTTPURLResponse)?.statusCode == 200,
          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        return nil
    }
    return (json["version"] as? String ?? "?", json["model"] as? String ?? "?")
}
