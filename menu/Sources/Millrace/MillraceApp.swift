import SwiftUI
import AppKit

/// Millrace — a macOS menu-bar companion for the local millrace inference server.
/// Lives in the menu bar (no Dock icon when bundled with LSUIElement); shows
/// whether the server is up and which model it is serving.
@main
struct MillraceApp: App {
    @StateObject private var client = MillraceClient()

    var body: some Scene {
        MenuBarExtra {
            MenuContent(client: client)
        } label: {
            Image(systemName: client.status.symbol)
        }
        .menuBarExtraStyle(.menu)
    }
}

struct MenuContent: View {
    @ObservedObject var client: MillraceClient

    /// Where the packaged inference engine is published.
    private let engineReleasesURL = "https://github.com/millrace/mojo-backend/releases/latest"

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
            // Bootstrap affordance: no engine answering on :8000. Offer to get it.
            // (Auto download + launch comes once the engine ships a bundled artifact.)
            Text("No engine detected on :8000")
            Button("Get the inference engine…") {
                if let url = URL(string: engineReleasesURL) {
                    NSWorkspace.shared.open(url)
                }
            }
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
}
