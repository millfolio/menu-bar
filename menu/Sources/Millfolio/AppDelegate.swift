import AppKit
import WebKit

/// AppKit glue for the app shell: builds the native main menu, owns the main
/// `WKWebView` window, and manages the activation policy so the menu-bar agent
/// gains a Dock icon + a real app menu once its window is on screen.
///
/// The SwiftUI `MenuBarExtra` stays the control/status surface (start/stop the
/// server, etc.); this delegate adds the *window* — a native view onto the local
/// web UI running at :10000. The server lifecycle is unchanged (the servers are
/// LaunchAgents managed elsewhere); the window is purely a view.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    private var mainWindowController: MainWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // A SwiftUI MenuBarExtra-only app has no standard menu bar; supply one so
        // Cmd-C/V/Q/R and the window commands work once we show a window.
        NSApp.mainMenu = MenuBuilder.build()
        // Open the window on launch — this is a windowed app now, not a pure agent.
        showMainWindow()
    }

    /// Re-open the window when the app is activated with no visible window (Dock
    /// click, or the "Open millfolio" menu-bar action re-activating us).
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { showMainWindow() }
        return true
    }

    /// Bring the millfolio window to the front (creating it on first use). Called
    /// from the menu-bar "Open millfolio" item and on launch/reopen.
    func showMainWindow() {
        let controller: MainWindowController
        if let existing = mainWindowController {
            controller = existing
        } else {
            controller = MainWindowController()
            mainWindowController = controller
        }
        // Promote from accessory (menu-bar-only) to a regular, Dock-visible app so
        // the window can become key and the app menu is active.
        if NSApp.activationPolicy() != .regular {
            NSApp.setActivationPolicy(.regular)
        }
        NSApp.activate(ignoringOtherApps: true)
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
    }
}

// MARK: - Main window controller

/// The main window hosting the millfolio web UI. Remembers its frame across
/// launches (autosave), enforces a sensible minimum for the chat UI, and hosts a
/// `WebController` that manages loading/readiness.
@MainActor
final class MainWindowController: NSWindowController, NSWindowDelegate {
    private let web = WebController(startURL: WebApp.url, pollsForReady: true)

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1100, height: 760),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        window.title = "millfolio"
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 720, height: 520)
        window.titlebarAppearsTransparent = false
        window.tabbingMode = .disallowed
        super.init(window: window)

        window.delegate = self
        window.contentViewController = WebViewController(web: web)
        // Restore/persist size + position. setFrameUsingName after setting the
        // autosave name applies any saved frame; center on first ever run.
        window.setFrameAutosaveName("MillfolioMainWindow")
        if window.setFrameUsingName("MillfolioMainWindow") == false {
            window.center()
        }
        web.start()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// Closing the window returns the app to a menu-bar agent (no Dock icon); the
    /// menu-bar "Open millfolio" item brings it back.
    func windowWillClose(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }
}

/// Thin view controller so the `WebController` (and thus its reload action) is in
/// the window's responder chain for the View ▸ Reload (Cmd-R) menu item.
@MainActor
final class WebViewController: NSViewController {
    private let web: WebController
    init(web: WebController) {
        self.web = web
        super.init(nibName: nil, bundle: nil)
    }
    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() { view = web.makeContentView() }

    /// Wired to the View ▸ Reload menu item (Cmd-R) via the responder chain.
    @objc func reloadPage(_ sender: Any?) { web.reload() }
}

// MARK: - Main menu

/// Builds the app's native menu bar (App / Edit / View / Window). Edit uses the
/// standard first-responder selectors so copy/paste/select-all work inside the
/// WKWebView; View ▸ Reload targets the `WebViewController` through the responder
/// chain.
@MainActor
enum MenuBuilder {
    static func build() -> NSMenu {
        let main = NSMenu()

        // App menu
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About millfolio",
                        action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide millfolio",
                        action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let hideOthers = appMenu.addItem(withTitle: "Hide Others",
                        action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(withTitle: "Show All",
                        action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit millfolio",
                        action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)

        // Edit menu (standard responder-chain selectors → work in the webview)
        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu
        main.addItem(editItem)

        // View menu
        let viewItem = NSMenuItem()
        let viewMenu = NSMenu(title: "View")
        viewMenu.addItem(withTitle: "Reload", action: #selector(WebViewController.reloadPage(_:)), keyEquivalent: "r")
        viewItem.submenu = viewMenu
        main.addItem(viewItem)

        // Window menu
        let windowItem = NSMenuItem()
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        windowMenu.addItem(.separator())
        windowMenu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowItem.submenu = windowMenu
        main.addItem(windowItem)
        NSApp.windowsMenu = windowMenu

        return main
    }
}
