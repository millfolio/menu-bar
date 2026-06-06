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

    var body: some View {
        Text(client.status.title)

        if let model = client.model {
            Text("Model: \(model)")
        }

        Divider()

        Button("Refresh") { client.refresh() }

        Button("Open server in browser") {
            if let url = URL(string: client.baseURL) {
                NSWorkspace.shared.open(url)
            }
        }

        Divider()

        Button("Quit Millrace") { NSApplication.shared.terminate(nil) }
            .keyboardShortcut("q")
    }
}
