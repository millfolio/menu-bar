import SwiftUI
import AppKit
import MillraceCore

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
            Image(nsImage: client.status == .online ? MenuBarIcon.active : MenuBarIcon.inactive)
        }
        .menuBarExtraStyle(.menu)
    }
}

struct MenuContent: View {
    @ObservedObject var client: MillraceClient
    @ObservedObject var bootstrapper: Bootstrapper

    private let engineRepoURL = "https://github.com/millrace/mojo-backend"
    private let headgateRepoURL = "https://github.com/millrace/headgate"

    var body: some View {
        Text(client.status.title)

        if client.status == .online {
            if let version = client.version { Text("Engine v\(version)") }
            if let model = client.model { Text("Model: \(model)") }
        }

        Divider()

        engineActions

        Divider()

        headgateActions

        Divider()

        Button("Refresh") { client.refresh(); bootstrapper.refreshServerRunning() }
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

            // 1. Install server (+ weights). Hidden once both are present.
            if !(bootstrapper.isServerInstalled && bootstrapper.weightsPresent) {
                Button(downloadLabel) { bootstrapper.downloadServer() }
            }

            // 2. Start / Stop server.
            if bootstrapper.serverRunning || client.status == .online {
                Button("Stop server") { bootstrapper.tryStopServer() }
                    .disabled(!bootstrapper.serverRunning)
            } else {
                Button("Start server") { bootstrapper.tryStartServer() }
                    .disabled(!bootstrapper.canStartServer)
            }

            // 3. Start opencode (needs a running server).
            Button("Start opencode…") { bootstrapper.startOpencode() }
                .disabled(client.status != .online)
        }

        Button("View engine on GitHub") {
            if let url = URL(string: engineRepoURL) { NSWorkspace.shared.open(url) }
        }
    }

    /// headgate (privacy harness): install (download toolchain + bundle, build) and
    /// start (open a ready-to-use Terminal — it's a one-shot CLI, not a daemon).
    @ViewBuilder
    private var headgateActions: some View {
        if bootstrapper.isHeadgateInstalled {
            Button("Open headgate web…") { bootstrapper.startHeadgateWeb() }
            Button("Start headgate (CLI)…") { bootstrapper.startHeadgate() }
        } else {
            Button("Install headgate…") { bootstrapper.installHeadgate() }
                .disabled(bootstrapper.isBusy)
        }
        Button("View headgate on GitHub") {
            if let url = URL(string: headgateRepoURL) { NSWorkspace.shared.open(url) }
        }
    }

    private var downloadLabel: String {
        if case .failed = bootstrapper.phase { return "Retry install server…" }
        return bootstrapper.isServerInstalled ? "Download model weights…" : "Install server…"
    }
}
