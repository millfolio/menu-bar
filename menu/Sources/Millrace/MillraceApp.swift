import SwiftUI
import AppKit

/// Millrace — a macOS menu-bar companion for the local millrace inference server.
/// Lives in the menu bar (no Dock icon when bundled with LSUIElement); drives the
/// engine lifecycle: download the runner (+ model weights), start/stop it, and
/// open opencode against it.
@main
struct MillraceApp: App {
    @StateObject private var client = MillraceClient()
    @StateObject private var bootstrapper = Bootstrapper()

    var body: some Scene {
        MenuBarExtra {
            MenuContent(client: client, bootstrapper: bootstrapper)
        } label: {
            Image(systemName: client.status.symbol)
        }
        .menuBarExtraStyle(.menu)
    }
}

struct MenuContent: View {
    @ObservedObject var client: MillraceClient
    @ObservedObject var bootstrapper: Bootstrapper

    private let engineRepoURL = "https://github.com/millrace/mojo-backend"

    var body: some View {
        Text(client.status.title)

        if client.status == .online {
            if let version = client.version { Text("Engine v\(version)") }
            if let model = client.model { Text("Model: \(model)") }
        }

        Divider()

        engineActions

        Divider()

        Button("Refresh") { client.refresh() }
        if client.status == .online {
            Button("Open server in browser") {
                if let url = URL(string: client.baseURL) { NSWorkspace.shared.open(url) }
            }
        }
        if bootstrapper.hasLog {
            Button("Open Log") { bootstrapper.openLog() }
        }

        Divider()

        Button("Quit Millrace") { NSApplication.shared.terminate(nil) }
            .keyboardShortcut("q")
    }

    /// The three lifecycle actions, gated on what's installed / running.
    @ViewBuilder
    private var engineActions: some View {
        // Provisioning progress / errors take over while the download runs.
        if bootstrapper.isBusy {
            Text(bootstrapper.phase.message ?? "Working…")
        } else {
            if case .failed(let msg) = bootstrapper.phase {
                Text("Failed: \(msg.split(separator: "\n").first.map(String.init) ?? msg)")
                    .lineLimit(1)
                Button("Open Log") { bootstrapper.openLog() }
            }

            // 1. Download runner (+ weights). Hidden once both are present.
            if !(bootstrapper.isRunnerInstalled && bootstrapper.weightsPresent) {
                Button(downloadLabel) { bootstrapper.downloadRunner() }
            }

            // 2. Start / Stop runner.
            if bootstrapper.serverRunning || client.status == .online {
                Button("Stop runner") { bootstrapper.stopRunner() }
                    .disabled(!bootstrapper.serverRunning)
            } else {
                Button("Start runner") { bootstrapper.startRunner() }
                    .disabled(!bootstrapper.canStartRunner)
            }

            // 3. Start opencode (needs a running server).
            Button("Start opencode…") { bootstrapper.startOpencode() }
                .disabled(client.status != .online)
        }

        Button("View engine on GitHub") {
            if let url = URL(string: engineRepoURL) { NSWorkspace.shared.open(url) }
        }
    }

    private var downloadLabel: String {
        if case .failed = bootstrapper.phase { return "Retry download runner…" }
        return bootstrapper.isRunnerInstalled ? "Download model weights…" : "Download runner…"
    }
}
