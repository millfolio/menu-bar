import SwiftUI
import AppKit
import MillfolioCore

/// Millfolio — a macOS menu-bar companion for the local millfolio runtime.
/// Lives in the menu bar and owns the app window(s): the first-run onboarding
/// window (native provisioning) and the main `WKWebView` onto the local web UI at
/// :10000. The server lifecycle is driven through `MillfolioCore.Bootstrapper` — the
/// same Swift lib the `mill` CLI uses.
@main
struct MillfolioApp: App {
    // The AppKit delegate owns the native windows + the app menu, manages the
    // activation policy, AND owns the ONE shared Bootstrapper (so the menu controls,
    // the onboarding window, and the provisioned check all observe the same object).
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    @StateObject private var client = MillfolioClient()

    var body: some Scene {
        MenuBarExtra {
            MenuContent(client: client, bootstrapper: appDelegate.bootstrapper, updater: appDelegate.updater, appDelegate: appDelegate)
        } label: {
            Image(nsImage: client.status == .online ? MenuBarIcon.active : MenuBarIcon.inactive)
        }
        .menuBarExtraStyle(.menu)
    }
}

struct MenuContent: View {
    @ObservedObject var client: MillfolioClient
    @ObservedObject var bootstrapper: Bootstrapper
    @ObservedObject var updater: UpdaterController
    let appDelegate: AppDelegate

    private let repoURL = "https://github.com/millfolio/vault"

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

        vaultActions

        Divider()

        Button("Refresh") { client.refresh(); bootstrapper.refreshServerRunningInBackground() }
        if bootstrapper.hasLog {
            Button("Open Log") { bootstrapper.openLog() }
        }

        Divider()

        // One button, both layers: Sparkle updates the app shell AND the prod bundle
        // is refreshed (features shipped on the bundle line). Routed through
        // AppDelegate.checkForUpdates so the menu, App menu, and toolbar all match.
        Button("Check for Updates…") { appDelegate.checkForUpdates(nil) }
            .disabled(!updater.canCheckForUpdates)

        Divider()

        Button("Quit Millfolio") { NSApplication.shared.terminate(nil) }
            .keyboardShortcut("q")
    }

    /// Vault lifecycle actions, gated on whether the runtime is provisioned.
    @ViewBuilder
    private var vaultActions: some View {
        if bootstrapper.isBusy {
            Text(bootstrapper.phase.message ?? "Working…")
        } else if case .failed(let msg) = bootstrapper.phase {
            Text("Failed: \(msg.split(separator: "\n").first.map(String.init) ?? msg)")
                .lineLimit(1)
            Button("Open setup…") { appDelegate.showOnboarding() }
        } else if !bootstrapper.isProvisioned {
            // First run (or a partial install): open the native provisioning window.
            Button("Set up millfolio…") { appDelegate.showOnboarding() }
        } else {
            // Provisioned: start / stop the local servers.
            if bootstrapper.serverRunning || client.status == .online {
                Button("Stop millfolio") {
                    Task { @MainActor in
                        _ = await bootstrapper.stopAppServer()
                        bootstrapper.tryStopServer()
                    }
                }
            } else {
                Button("Start millfolio") {
                    Task { @MainActor in
                        let dir = bootstrapper.ensureVaultDir()
                        // The app is the browser (WKWebView), so openBrowser:false.
                        try? await bootstrapper.startVaultChat(vaultDir: dir, openBrowser: false)
                        appDelegate.showMainWindow()
                    }
                }
            }
        }

        Button("View project on GitHub") {
            if let url = URL(string: repoURL) { NSWorkspace.shared.open(url) }
        }
    }
}
