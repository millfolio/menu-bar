import SwiftUI
import AppKit
import MillfolioCore

/// Millfolio — a macOS menu-bar companion for the local engine inference server.
/// Lives in the menu bar (no Dock icon when bundled with LSUIElement); drives the
/// engine lifecycle: download the runner (+ model weights), start/stop it, and
/// open opencode against it.
@main
struct MillfolioApp: App {
    // The AppKit delegate owns the native WKWebView main window + the app menu,
    // and manages the activation policy (menu-bar agent ⇄ Dock-visible window).
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    @StateObject private var client = MillfolioClient()
    @StateObject private var bootstrapper = Bootstrapper()

    var body: some Scene {
        MenuBarExtra {
            MenuContent(client: client, bootstrapper: bootstrapper, appDelegate: appDelegate)
        } label: {
            Image(nsImage: client.status == .online ? MenuBarIcon.active : MenuBarIcon.inactive)
        }
        .menuBarExtraStyle(.menu)
    }
}

struct MenuContent: View {
    @ObservedObject var client: MillfolioClient
    @ObservedObject var bootstrapper: Bootstrapper
    let appDelegate: AppDelegate

    private let engineRepoURL = "https://github.com/millfolio/engine"

    var body: some View {
        Text(client.status.title)

        if client.status == .online {
            if let version = client.version { Text("Engine v\(version)") }
            if let model = client.model { Text("Model: \(model)") }
        }

        Divider()

        // Bring the native millfolio window (the local web UI) to the front.
        Button("Open millfolio") { appDelegate.showMainWindow() }
            .keyboardShortcut("o")

        Divider()

        engineActions

        Divider()

        Button("Refresh") { client.refresh(); bootstrapper.refreshServerRunning() }
        if bootstrapper.hasLog {
            Button("Open Log") { bootstrapper.openLog() }
        }

        Divider()

        Button("Quit Millfolio") { NSApplication.shared.terminate(nil) }
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

    private var downloadLabel: String {
        if case .failed = bootstrapper.phase { return "Retry install server…" }
        return bootstrapper.isServerInstalled ? "Download model weights…" : "Install server…"
    }
}
