import SwiftUI
import AppKit

/// Millrace — a macOS menu-bar companion for the local millrace inference server.
/// Lives in the menu bar (no Dock icon when bundled with LSUIElement); shows
/// whether the server is up and which model it is serving.
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
            if let version = client.version {
                Text("Engine v\(version)")
            }
            if let model = client.model {
                Text("Model: \(model)")
            }
        } else if client.status == .offline {
            engineBootstrapSection
        }

        Divider()

        Button("Refresh") { client.refresh() }

        if client.status == .online {
            Button("Open server in browser") {
                if let url = URL(string: client.baseURL) {
                    NSWorkspace.shared.open(url)
                }
            }
        }

        Divider()

        Button("Quit Millrace") { NSApplication.shared.terminate(nil) }
            .keyboardShortcut("q")
    }

    /// Engine not answering on :8000 — drive the one-click download/build/launch
    /// bootstrap, or show its progress / error.
    @ViewBuilder
    private var engineBootstrapSection: some View {
        switch bootstrapper.phase {
        case .running(let msg):
            Text(msg)
        case .failed:
            Text(bootstrapper.phase.message ?? "Install failed")
            Button("Retry install") { bootstrapper.installAndLaunch() }
        case .idle, .done:
            Text("No engine detected on :8000")
            Button("Install & launch engine…") { bootstrapper.installAndLaunch() }
        }
        Button("View engine on GitHub") {
            if let url = URL(string: engineRepoURL) { NSWorkspace.shared.open(url) }
        }
    }
}
