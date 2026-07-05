import AppKit
import WebKit
import MillfolioCore

/// AppKit glue for the app shell: builds the native main menu, owns the main
/// `WKWebView` window + the first-run onboarding window, and manages the activation
/// policy so the menu-bar agent gains a Dock icon + a real app menu once a window is
/// on screen.
///
/// The SwiftUI `MenuBarExtra` stays the control/status surface (start/stop, etc.);
/// this delegate owns the *windows*. On launch it decides between two flows:
///
///   * **not provisioned** → the native **onboarding window** runs
///     `Bootstrapper.installVault()` (the same provision path as `mill install`) and,
///     on success, hands off to the main window.
///   * **already provisioned** → straight to the main `WKWebView` window onto the
///     local web UI at :10000 (the existing flow — unchanged).
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    /// The ONE shared Bootstrapper for the whole app (the menu-bar controls, the
    /// onboarding window, and the launch-time provisioned check all observe it). It
    /// installs into the shared ~/Library/Application Support/Millfolio tree the
    /// `mill` CLI uses, so both interoperate on one set of launchd agents.
    let bootstrapper: Bootstrapper = {
        let b = Bootstrapper()
        // The app has its own release cadence and must NOT provision whatever `mill`
        // version is brew-installed (that fetched the stale v0.4.36 bundle → missing
        // vault.mojoc). Always pin to the latest PROD bundle instead.
        b.forceLatestBundle = true
        return b
    }()

    /// Owns Sparkle's updater controller (auto-update). Started automatically; the
    /// menu's "Check for Updates…" items drive it. See Updater.swift.
    let updater = UpdaterController()

    private var mainWindowController: MainWindowController?
    private var onboardingController: OnboardingWindowController?

    /// App-menu "Check for Updates…" target. Routed through the responder chain so it
    /// works from the native App menu (MenuBuilder) when a window is on screen.
    @objc func checkForUpdates(_ sender: Any?) {
        updater.checkForUpdates()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // A SwiftUI MenuBarExtra-only app has no standard menu bar; supply one so
        // Cmd-C/V/Q/R and the window commands work once we show a window.
        NSApp.mainMenu = MenuBuilder.build()
        // First-run routing: onboard if the runtime isn't provisioned yet, else go
        // straight to the web window (the existing flow). On launch we also START the
        // servers when already provisioned — `mill install` provisions but doesn't
        // start, so a provisioned launch would otherwise sit on "Waiting for local
        // server". (Not on reopen — the servers are already up by then.)
        routeInitialWindow(startServers: true)
    }

    /// Show onboarding on first run, otherwise the main web window. When `startServers`
    /// (launch only), bring the local servers up for the already-provisioned case.
    private func routeInitialWindow(startServers: Bool = false) {
        if bootstrapper.isProvisioned {
            showMainWindow()
            if startServers {
                // On launch, ALSO check whether a newer PROD bundle has shipped and, if
                // so, re-provision against it BEFORE starting the servers — the app has no
                // Homebrew `mill update` path, so this is how it picks up features shipped
                // on the prod bundle line. Background + idempotent: up-to-date or offline
                // → just starts :8000/:10000 (no-ops if already serving). openBrowser:false
                // — the WebWindow renders :10000; its poll overlay covers the (possibly
                // couple-minute) refresh + startup wait, and refresh progress streams via
                // the shared Bootstrapper's phase (the menu-bar status line).
                bootstrapper.refreshBundleThenStartFireAndForget(openBrowser: false)
            }
        } else {
            showOnboarding()
        }
    }

    /// Re-open the appropriate window when the app is activated with no visible
    /// window (Dock click, or a menu-bar action re-activating us).
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { routeInitialWindow() }
        return true
    }

    // MARK: - Onboarding (first-run provisioning)

    /// Present the native first-run provisioning window. On success it hands off to
    /// the main web window (the servers are already up by then).
    func showOnboarding() {
        let controller: OnboardingWindowController
        if let existing = onboardingController {
            controller = existing
        } else {
            controller = OnboardingWindowController(bootstrapper: bootstrapper) { [weak self] in
                self?.finishOnboarding()
            }
            onboardingController = controller
        }
        if NSApp.activationPolicy() != .regular {
            NSApp.setActivationPolicy(.regular)
        }
        NSApp.activate(ignoringOtherApps: true)
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
    }

    /// Onboarding succeeded: close it and show the main web window. The app server is
    /// already listening on :10000 (onboarding started it with openBrowser:false), so
    /// the WebWindow's poll overlay loads the page promptly — no connect-error flash.
    private func finishOnboarding() {
        onboardingController?.close()
        onboardingController = nil
        showMainWindow()
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
final class MainWindowController: NSWindowController, NSWindowDelegate, NSToolbarDelegate {
    private let web = WebController(startURL: WebApp.url, pollsForReady: true)
    private static let reloadItemID = NSToolbarItem.Identifier("Reload")
    private static let updatesItemID = NSToolbarItem.Identifier("CheckForUpdates")
    private static let discordItemID = NSToolbarItem.Identifier("Discord")
    private static let discordURL = URL(string: "https://discord.gg/ZrWcStMtE4")!
    private var keyMonitor: Any?

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
        // A visible Reload button + a Cmd-R monitor. The AppKit main menu is
        // unreliable in a MenuBarExtra/LSUIElement app, so refresh must not depend on it.
        let toolbar = NSToolbar(identifier: "MillfolioMainToolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        window.toolbar = toolbar
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self, weak window] event in
            guard let self, let window, window.isKeyWindow,
                event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
                event.charactersIgnoringModifiers?.lowercased() == "r"
            else { return event }
            self.web.reload()
            return nil   // consume ⌘R
        }

        web.start()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    @objc private func reloadTapped(_ sender: Any?) { web.reload() }
    @objc private func checkUpdatesTapped(_ sender: Any?) {
        (NSApp.delegate as? AppDelegate)?.checkForUpdates(sender)
    }

    // MARK: NSToolbarDelegate — Reload + Check for Updates (menu-independent, since the
    // AppKit main menu is unreliable in a MenuBarExtra/LSUIElement app).
    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        if id == Self.reloadItemID {
            let item = NSToolbarItem(itemIdentifier: id)
            item.label = "Reload"
            item.toolTip = "Reload the page (⌘R)"
            item.image = NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: "Reload")
            item.isBordered = true
            item.target = self
            item.action = #selector(reloadTapped(_:))
            return item
        }
        if id == Self.updatesItemID {
            let item = NSToolbarItem(itemIdentifier: id)
            item.label = "Check for Updates"
            item.toolTip = "Check for Updates…"
            item.image = NSImage(systemSymbolName: "arrow.down.circle", accessibilityDescription: "Check for Updates")
            item.isBordered = true
            item.target = self
            item.action = #selector(checkUpdatesTapped(_:))
            return item
        }
        if id == Self.discordItemID {
            let item = NSToolbarItem(itemIdentifier: id)
            item.label = "Discord"
            item.toolTip = "Join the millfolio Discord"
            item.image = NSImage(systemSymbolName: "bubble.left.and.bubble.right", accessibilityDescription: "Discord")
            item.isBordered = true
            item.target = self
            item.action = #selector(discordTapped(_:))
            return item
        }
        return nil
    }
    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [Self.reloadItemID, .flexibleSpace, Self.discordItemID, Self.updatesItemID]
    }
    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [Self.reloadItemID, Self.updatesItemID, Self.discordItemID, .flexibleSpace]
    }
    @objc private func discordTapped(_ sender: Any?) { NSWorkspace.shared.open(Self.discordURL) }

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
        // Sparkle auto-update. Target nil → routed through the responder chain to the
        // AppDelegate's checkForUpdates(_:), which drives the shared UpdaterController.
        appMenu.addItem(withTitle: "Check for Updates…",
                        action: #selector(AppDelegate.checkForUpdates(_:)), keyEquivalent: "")
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
