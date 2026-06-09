import Foundation
import Darwin
import ArgumentParser
import MillraceCore

// The `millrace` CLI — the same engine lifecycle the menu-bar app drives, on the
// command line. Backed by MillraceCore.Bootstrapper, so the CLI and the app share
// one install tree (~/Library/Application Support/Millrace) and one launchd-managed
// server (me.millrace.server) — start from either, see it from both.

@main
struct Millrace: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "millrace",
        abstract: "Manage the local millrace inference server and the headgate privacy harness.",
        subcommands: [Server.self, Headgate.self, Opencode.self]
    )
}

// ── millrace server … ────────────────────────────────────────────────────────
struct Server: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "server",
        abstract: "Install, run, and inspect the inference server.",
        subcommands: [Install.self, Status.self, Start.self, Stop.self, Logs.self]
    )

    struct Install: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Download the Mojo toolchain + engine, build it, and fetch model weights.")
        @MainActor func run() async throws {
            let boot = streaming()
            try await boot.installServer()
            print("✓ server installed")
        }
    }

    struct Start: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Start the server as a launchd LaunchAgent (me.millrace.server).")
        @MainActor func run() async throws {
            let boot = Bootstrapper()
            try boot.startServer()
            print("✓ server started — http://127.0.0.1:8000 (use `millrace server status`)")
        }
    }

    struct Stop: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Stop the server LaunchAgent.")
        @MainActor func run() async throws {
            let boot = Bootstrapper()
            try boot.stopServer()
            print("✓ server stopped")
        }
    }

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
}

// ── millrace headgate … ──────────────────────────────────────────────────────
struct Headgate: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "headgate",
        abstract: "Install and launch the headgate privacy harness.",
        subcommands: [Install.self, Start.self, Web.self, Status.self]
    )

    struct Install: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Download headgate's Mojo toolchain + source bundle and build it.")
        @MainActor func run() async throws {
            let boot = streaming()
            try await boot.installHeadgateEngine()
            print("✓ headgate installed")
        }
    }

    struct Start: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Run headgate in this terminal: a one-shot task, or an interactive REPL.",
            discussion: """
            With a TASK, runs it once and prints the answer; with no task, starts \
            headgate's interactive REPL. Either way headgate takes over this \
            terminal's stdin/stdout. With no controlling terminal (e.g. launched \
            from the menu app) it opens a new Terminal instead.
            """)
        @Argument(parsing: .remaining,
                  help: "Task to run once. Omit for an interactive REPL.")
        var task: [String] = []

        @MainActor func run() async throws {
            let boot = Bootstrapper()
            let script = try boot.writeHeadgateScript()
            // Attached to a terminal → REPLACE this process with the launcher (it
            // execs the headgate binary). execv is essential: a child Process would
            // land outside the terminal's foreground process group and get SIGTTIN
            // on read. Replacing the image hands headgate our controlling terminal,
            // so its REPL (or one-shot run) drives stdin/stdout directly. Any TASK
            // is forwarded as args → the launcher's `"$@"` → headgate.
            // No TTY (e.g. the GUI) → fall back to a new Terminal.
            if isatty(FileHandle.standardInput.fileDescriptor) != 0 {
                var argv: [UnsafeMutablePointer<CChar>?] =
                    [strdup("/bin/bash"), strdup(script.path)]
                for t in task { argv.append(strdup(t)) }
                argv.append(nil)
                execv("/bin/bash", argv)
                // Only reached if execv failed.
                throw BootstrapError.step("headgate start",
                                          "exec /bin/bash failed: \(String(cString: strerror(errno)))")
            } else {
                try await boot.launchHeadgateTerminal()
            }
        }
    }

    struct Web: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Open the headgate web app (chat UI) at http://localhost:10000.",
            discussion: """
            Starts the headgate HTTP server (which serves the web UI + the /chat \
            API on one origin) and opens it in your browser. Runs in the current \
            terminal — Ctrl-C stops the server.
            """)
        @MainActor func run() async throws {
            let boot = Bootstrapper()
            let script = try boot.writeHeadgateWebScript()
            if isatty(FileHandle.standardInput.fileDescriptor) != 0 {
                let argv: [UnsafeMutablePointer<CChar>?] =
                    [strdup("/bin/bash"), strdup(script.path), nil]
                execv("/bin/bash", argv)
                throw BootstrapError.step("headgate web",
                                          "exec /bin/bash failed: \(String(cString: strerror(errno)))")
            } else {
                try await boot.launchHeadgateWebTerminal()
            }
        }
    }

    struct Status: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Show headgate install state.")
        @MainActor func run() async throws {
            print("installed:  \(mark(Bootstrapper().isHeadgateInstalled))")
        }
    }
}

// ── millrace opencode ────────────────────────────────────────────────────────
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

/// One-shot GET /v1/version, mirroring MillraceClient.poll without the timer.
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
