import AppKit
import LocalAuthentication
import WebKit

/// The native main window: a `WKWebView` hosting the local millfolio web UI
/// (served by the app-server at `http://localhost:10000`), replacing the old
/// "open in the default browser" hand-off.
///
/// Design notes / the easy-to-miss bits, all handled here:
///
///   * **Not-ready state.** The web UI only exists once the app-server (:10000)
///     is up. We never show a raw WebKit "could not connect" page: a native
///     "Starting millfolio…" overlay is shown while we *poll* the URL, and the
///     page is loaded only once it responds. A navigation failure drops back to
///     the overlay + resumes polling.
///   * **`target="_blank"` links** (the doc viewer opens `/api/doc?alias=…` in a
///     new tab): `WKUIDelegate.createWebViewWith` opens same-origin URLs in a
///     child window (returning a fresh `WKWebView` per the WebKit contract) and
///     external URLs in the system default browser.
///   * **Downloads** (a PDF/CSV the UI serves via `/api/doc`): navigation-response
///     policy converts a non-displayable / attachment response into a
///     `WKDownload`, and `WKDownloadDelegate` shows a save panel.
///   * **Native-notification bridge**: a `window.webkit.messageHandlers.millfolio`
///     hook the web UI can later call (e.g. "backfill done") — plumbing wired
///     even though the web side doesn't call it yet.
///
/// The window remembers its size/position (frame autosave) and has a sensible
/// minimum size for the chat UI.

/// The local web UI origin. Overridable for testing via `MILLFOLIO_APP_URL`.
enum WebApp {
    static var url: URL {
        if let s = ProcessInfo.processInfo.environment["MILLFOLIO_APP_URL"],
           let u = URL(string: s) { return u }
        return URL(string: "http://localhost:10000")!
    }

    /// Same-origin as the web UI (localhost / loopback on the same port), so we
    /// keep such navigations inside the app instead of shelling out to a browser.
    static func isLocal(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        return host == "localhost" || host == "127.0.0.1" || host == "::1"
    }
}

// MARK: - Weak script-message-handler proxy

/// `WKUserContentController.add(_:name:)` retains its handler strongly; routing
/// through this weak proxy avoids the webView → configuration → controller →
/// handler → webView retain cycle.
private final class WeakScriptMessageHandler: NSObject, WKScriptMessageHandler {
    weak var target: WKScriptMessageHandler?
    init(_ target: WKScriptMessageHandler) { self.target = target }
    func userContentController(_ ucc: WKUserContentController, didReceive message: WKScriptMessage) {
        target?.userContentController(ucc, didReceive: message)
    }
}

// MARK: - WebController

/// Owns one `WKWebView` and is its navigation / UI / download delegate plus the
/// script-message bridge. Used for the main window and for child (`_blank`)
/// windows alike.
final class WebController: NSObject, WKNavigationDelegate, WKUIDelegate, WKDownloadDelegate,
                          WKScriptMessageHandler {
    let webView: WKWebView
    private let startURL: URL
    /// Only the main window polls for readiness + shows the overlay; child
    /// windows load their given request directly.
    private let pollsForReady: Bool

    private var overlay: LoadingOverlay?
    private var pollTimer: Timer?
    private var isProbing = false

    /// Child windows we spawned for `target="_blank"` — retained so they live
    /// past the delegate call that created them.
    private var childControllers: [WebController] = []

    /// The bridge channel name the web UI posts to:
    /// `window.webkit.messageHandlers.millfolio.postMessage({...})`.
    static let bridgeName = "millfolio"

    /// Designated init. Pass an existing `configuration` (with `startURL == nil`)
    /// for a child window created by WebKit's `createWebViewWith`.
    init(startURL: URL, pollsForReady: Bool, configuration: WKWebViewConfiguration? = nil) {
        self.startURL = startURL
        self.pollsForReady = pollsForReady

        let config = configuration ?? WKWebViewConfiguration()
        self.webView = WKWebView(frame: .zero, configuration: config)
        super.init()

        // Bridge: add on the (possibly shared) content controller. Guard against a
        // duplicate name on a configuration WebKit handed us.
        let ucc = config.userContentController
        ucc.removeScriptMessageHandler(forName: Self.bridgeName)
        ucc.add(WeakScriptMessageHandler(self), name: Self.bridgeName)

        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        webView.setValue(false, forKey: "drawsBackground")  // avoid white flash over the overlay
        webView.translatesAutoresizingMaskIntoConstraints = false
    }

    deinit {
        pollTimer?.invalidate()
        webView.configuration.userContentController.removeScriptMessageHandler(forName: Self.bridgeName)
    }

    // MARK: content view (webView + overlay)

    /// A container view hosting the webView with the loading overlay on top.
    func makeContentView() -> NSView {
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(webView)
        NSLayoutConstraint.activate([
            webView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            webView.topAnchor.constraint(equalTo: container.topAnchor),
            webView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        if pollsForReady {
            let ov = LoadingOverlay { [weak self] in self?.retryNow() }
            ov.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(ov)
            NSLayoutConstraint.activate([
                ov.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                ov.trailingAnchor.constraint(equalTo: container.trailingAnchor),
                ov.topAnchor.constraint(equalTo: container.topAnchor),
                ov.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            ])
            overlay = ov
        }
        return container
    }

    // MARK: readiness polling

    /// Begin: if we poll, show the overlay and probe until :10000 answers; else
    /// load immediately (child windows).
    func start() {
        guard pollsForReady else {
            webView.load(URLRequest(url: startURL))
            return
        }
        showOverlay(status: "Starting millfolio…", detail: "Waiting for the local server (\(startURL.host ?? "localhost")).", spinning: true)
        beginPolling()
    }

    private func beginPolling() {
        pollTimer?.invalidate()
        probe()  // fire one immediately
        pollTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            self?.probe()
        }
    }

    private func retryNow() {
        showOverlay(status: "Starting millfolio…", detail: "Reconnecting…", spinning: true)
        beginPolling()
    }

    /// One reachability probe. Any HTTP response (even a 4xx/5xx) means the
    /// server socket is up, so we load; only a transport error keeps us waiting.
    private func probe() {
        guard !isProbing else { return }
        isProbing = true
        var req = URLRequest(url: startURL)
        req.timeoutInterval = 2
        req.cachePolicy = .reloadIgnoringLocalCacheData
        URLSession.shared.dataTask(with: req) { [weak self] _, response, error in
            DispatchQueue.main.async {
                guard let self else { return }
                self.isProbing = false
                if response != nil, error == nil {
                    self.serverIsUp()
                } else if let err = error as NSError?, err.domain == NSURLErrorDomain,
                          // A response with a bad status still throws in some cases;
                          // treat only connection-level failures as "still down".
                          [NSURLErrorCannotConnectToHost, NSURLErrorNetworkConnectionLost,
                           NSURLErrorTimedOut, NSURLErrorCannotFindHost,
                           NSURLErrorNotConnectedToInternet].contains(err.code) {
                    // still starting — keep waiting
                } else {
                    // Any other outcome: give the load a chance.
                    self.serverIsUp()
                }
            }
        }.resume()
    }

    private func serverIsUp() {
        guard pollTimer != nil else { return }  // already loaded
        pollTimer?.invalidate()
        pollTimer = nil
        webView.load(URLRequest(url: startURL))
    }

    // MARK: overlay helpers

    private func showOverlay(status: String, detail: String, spinning: Bool) {
        overlay?.update(status: status, detail: detail, spinning: spinning)
        overlay?.isHidden = false
    }
    private func hideOverlay() { overlay?.isHidden = true }

    // MARK: reload (menu / Cmd-R)

    func reload() {
        if webView.url == nil {
            retryNow()
        } else {
            webView.reloadFromOrigin()
        }
    }

    // MARK: WKNavigationDelegate

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        hideOverlay()
        webView.setValue(true, forKey: "drawsBackground")
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        handleNavigationFailure(error)
    }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        handleNavigationFailure(error)
    }

    private func handleNavigationFailure(_ error: Error) {
        let ns = error as NSError
        // Cancelled loads (e.g. a redirect we handled) are not failures.
        if ns.domain == NSURLErrorDomain, ns.code == NSURLErrorCancelled { return }
        guard pollsForReady else { return }
        showOverlay(status: "Reconnecting to millfolio…",
                    detail: "The local server didn't respond. Retrying…", spinning: true)
        beginPolling()
    }

    /// Decide whether a response is displayable or should become a download.
    func webView(_ webView: WKWebView,
                 decidePolicyFor navigationResponse: WKNavigationResponse,
                 decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        let http = navigationResponse.response as? HTTPURLResponse
        let disposition = (http?.value(forHTTPHeaderField: "Content-Disposition") ?? "").lowercased()
        let isAttachment = disposition.contains("attachment")
        if isAttachment || !navigationResponse.canShowMIMEType {
            decisionHandler(.download)
        } else {
            decisionHandler(.allow)
        }
    }

    // A navigation / response that turned into a download → own it.
    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        download.delegate = self
    }
    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        download.delegate = self
    }

    // MARK: WKUIDelegate — target="_blank" / window.open

    func webView(_ webView: WKWebView,
                 createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction,
                 windowFeatures: WKWindowFeatures) -> WKWebView? {
        guard let url = navigationAction.request.url else { return nil }
        if WebApp.isLocal(url) {
            // Same-origin (e.g. the doc viewer /api/doc?alias=…): open a child
            // window. Per the WebKit contract we MUST build the new webView from
            // the passed `configuration` and return it; WebKit then loads the URL.
            let child = WebController(startURL: url, pollsForReady: false, configuration: configuration)
            childControllers.append(child)
            let win = ChildWindow.make(for: child, title: url.lastPathComponent.isEmpty ? "millfolio" : url.lastPathComponent)
            win.makeKeyAndOrderFront(nil)
            // If WebKit doesn't auto-load (some window.open forms), kick it.
            if navigationAction.request.url != nil, child.webView.url == nil {
                child.webView.load(navigationAction.request)
            }
            return child.webView
        } else {
            NSWorkspace.shared.open(url)  // external link → system default browser
            return nil
        }
    }

    /// A child window's JS asked to close it.
    func webViewDidClose(_ webView: WKWebView) {
        webView.window?.close()
        childControllers.removeAll { $0.webView === webView }
    }

    // MARK: WKDownloadDelegate

    func download(_ download: WKDownload,
                  decideDestinationUsing response: URLResponse,
                  suggestedFilename: String,
                  completionHandler: @escaping (URL?) -> Void) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = suggestedFilename.isEmpty ? "download" : suggestedFilename
        panel.canCreateDirectories = true
        let finish: (NSApplication.ModalResponse) -> Void = { resp in
            guard resp == .OK, let url = panel.url else { completionHandler(nil); return }
            // WKDownload fails if the destination already exists — clear it first.
            try? FileManager.default.removeItem(at: url)
            completionHandler(url)
        }
        if let window = webView.window {
            panel.beginSheetModal(for: window, completionHandler: finish)
        } else {
            finish(panel.runModal())
        }
    }

    func downloadDidFinish(_ download: WKDownload) {
        if let url = download.progress.fileURL {
            NSWorkspace.shared.activateFileViewerSelecting([url])  // reveal in Finder
        }
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        let alert = NSAlert()
        alert.messageText = "Download failed"
        alert.informativeText = (error as NSError).localizedDescription
        alert.alertStyle = .warning
        if let window = webView.window {
            alert.beginSheetModal(for: window, completionHandler: nil)
        } else {
            alert.runModal()
        }
    }

    // MARK: WKScriptMessageHandler — native-notification bridge

    /// Handles `window.webkit.messageHandlers.millfolio.postMessage(payload)`.
    /// Payload shapes:
    ///   * `{ "type": "notify", "title": "…", "body": "…" }` — native notification.
    ///   * `{ "type": "unlockAmounts" }` — run Touch ID, then hand the web UI a
    ///     reveal token (see `handleUnlockAmounts`).
    ///   * `{ "type": "pickPath", "mode": "folder"|"files" }` — open a native
    ///     NSOpenPanel and hand the chosen absolute path(s) back to the web UI
    ///     (`window.__millfolioPickedPath`) so it can POST them to `/api/index`.
    func userContentController(_ ucc: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == Self.bridgeName else { return }
        let payload = message.body as? [String: Any] ?? [:]
        let type = (payload["type"] as? String) ?? "notify"
        switch type {
        case "notify":
            NativeNotifier.post(title: (payload["title"] as? String) ?? "millfolio",
                                body: (payload["body"] as? String) ?? "")
        case "unlockAmounts":
            handleUnlockAmounts()
        case "pickPath":
            handlePickPath(mode: (payload["mode"] as? String) ?? "folder")
        default:
            NSLog("millfolio bridge: unhandled message type \"\(type)\"")
        }
    }

    // MARK: - Native file/folder picker (Vault/Files indexing)

    /// The web UI asked to pick something to index. Show an `NSOpenPanel` configured
    /// per `mode` ("folder" → choose a directory; "files" → choose one or more files),
    /// then hand each chosen ABSOLUTE path back to the web UI via
    /// `window.__millfolioPickedPath("<path>")` (or `window.__millfolioPickCancelled()`
    /// on cancel). The app is NOT sandboxed, so it can read any user folder the picker
    /// returns directly — no security-scoped bookmarks are needed.
    private func handlePickPath(mode: String) {
        let panel = NSOpenPanel()
        let wantFiles = (mode == "files")
        panel.canChooseDirectories = !wantFiles
        panel.canChooseFiles = wantFiles
        panel.allowsMultipleSelection = wantFiles
        panel.resolvesAliases = true
        panel.prompt = "Index"
        panel.message = wantFiles
            ? "Choose files to index (.csv, .pdf, .md)."
            : "Choose a folder to index."
        let finish: (NSApplication.ModalResponse) -> Void = { [weak self] resp in
            guard let self else { return }
            guard resp == .OK, !panel.urls.isEmpty else {
                self.pickCancelled()
                return
            }
            // Forward each chosen path; the web UI indexes them (folder mode returns
            // exactly one directory — the common case wired into the UI today).
            for url in panel.urls {
                self.pickedPath(url.path)
            }
        }
        if let window = webView.window {
            panel.beginSheetModal(for: window, completionHandler: finish)
        } else {
            finish(panel.runModal())
        }
    }

    private func pickedPath(_ path: String) {
        let js = "window.__millfolioPickedPath && window.__millfolioPickedPath(\"\(Self.jsEscape(path))\")"
        webView.evaluateJavaScript(js, completionHandler: nil)
    }

    private func pickCancelled() {
        webView.evaluateJavaScript("window.__millfolioPickCancelled && window.__millfolioPickCancelled()",
                                   completionHandler: nil)
    }

    // MARK: - Touch-ID amount unlock (native LocalAuthentication bridge)

    /// The on-device data dir holding `.reveal-secret` — mirrors the app-server's
    /// `_config_dir()`: `$MILLFOLIO_DATA_DIR` (if set) else
    /// `~/Library/Application Support/Millfolio/data`.
    private func revealSecretURL() -> URL {
        let env = ProcessInfo.processInfo.environment
        if let d = env["MILLFOLIO_DATA_DIR"],
           !d.trimmingCharacters(in: .whitespaces).isEmpty {
            return URL(fileURLWithPath: d).appendingPathComponent(".reveal-secret")
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Millfolio/data", isDirectory: true)
            .appendingPathComponent(".reveal-secret")
    }

    /// The web UI asked to unlock amounts via Touch ID. Run LocalAuthentication
    /// with `.deviceOwnerAuthentication` — Touch ID / Apple Watch, FALLING BACK to
    /// the Mac login password (NOT `.withBiometrics`), so it also works on a Mac
    /// mini with no biometric sensor. On success, exchange the local secret for a
    /// reveal token; on cancel/failure, call the web's failure callback so it can
    /// offer the passphrase instead.
    private func handleUnlockAmounts() {
        let context = LAContext()
        context.localizedCancelTitle = "Cancel"
        var authError: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &authError) else {
            revealFailed(authError?.localizedDescription ?? "Authentication isn't available on this Mac.")
            return
        }
        context.evaluatePolicy(.deviceOwnerAuthentication,
                               localizedReason: "Unlock your amounts") { [weak self] success, error in
            DispatchQueue.main.async {
                guard let self else { return }
                if success {
                    self.exchangeSecretForToken()
                } else {
                    self.revealFailed(error?.localizedDescription ?? "Touch ID was cancelled.")
                }
            }
        }
    }

    /// Read the local-capability secret and POST it to `/api/amounts/unlock-local`,
    /// which mints the SAME reveal token the passphrase path mints. On success,
    /// hand the token to the web UI via `window.__millfolioReveal(token)`.
    private func exchangeSecretForToken() {
        guard let raw = try? String(contentsOf: revealSecretURL(), encoding: .utf8) else {
            revealFailed("Couldn't read the local unlock secret. Is millfolio running?")
            return
        }
        let secret = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if secret.isEmpty {
            revealFailed("The local unlock secret is empty.")
            return
        }
        var req = URLRequest(url: WebApp.url.appendingPathComponent("api/amounts/unlock-local"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(secret, forHTTPHeaderField: "X-Millfolio-Reveal-Secret")
        req.timeoutInterval = 10
        URLSession.shared.dataTask(with: req) { [weak self] data, response, error in
            DispatchQueue.main.async {
                guard let self else { return }
                guard error == nil,
                      let http = response as? HTTPURLResponse, http.statusCode == 200,
                      let data,
                      let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let token = obj["token"] as? String, !token.isEmpty else {
                    self.revealFailed("The local server didn't return a token.")
                    return
                }
                self.revealSucceeded(token)
            }
        }.resume()
    }

    private func revealSucceeded(_ token: String) {
        let js = "window.__millfolioReveal && window.__millfolioReveal(\"\(Self.jsEscape(token))\")"
        webView.evaluateJavaScript(js, completionHandler: nil)
    }

    private func revealFailed(_ message: String) {
        let js = "window.__millfolioRevealFailed && window.__millfolioRevealFailed(\"\(Self.jsEscape(message))\")"
        webView.evaluateJavaScript(js, completionHandler: nil)
    }

    /// Minimal JS string-literal escaping for values injected into
    /// `evaluateJavaScript` (the token is server-minted hex, but escape defensively).
    private static func jsEscape(_ s: String) -> String {
        var out = ""
        for ch in s.unicodeScalars {
            switch ch {
            case "\\": out += "\\\\"
            case "\"": out += "\\\""
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            default: out.unicodeScalars.append(ch)
            }
        }
        return out
    }
}

// MARK: - Loading overlay

/// The native "Starting millfolio…" panel shown until the server responds.
private final class LoadingOverlay: NSView {
    private let statusLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(labelWithString: "")
    private let spinner = NSProgressIndicator()
    private let retryButton: NSButton
    private let onRetry: () -> Void

    init(onRetry: @escaping () -> Void) {
        self.onRetry = onRetry
        self.retryButton = NSButton(title: "Retry now", target: nil, action: nil)
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor

        spinner.style = .spinning
        spinner.controlSize = .regular
        spinner.startAnimation(nil)

        statusLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        statusLabel.alignment = .center
        detailLabel.font = .systemFont(ofSize: 12)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.alignment = .center
        detailLabel.maximumNumberOfLines = 3

        retryButton.target = self
        retryButton.action = #selector(retryTapped)
        retryButton.bezelStyle = .rounded

        let stack = NSStackView(views: [spinner, statusLabel, detailLabel, retryButton])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            stack.widthAnchor.constraint(lessThanOrEqualToConstant: 360),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    @objc private func retryTapped() { onRetry() }

    func update(status: String, detail: String, spinning: Bool) {
        statusLabel.stringValue = status
        detailLabel.stringValue = detail
        if spinning { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }
        spinner.isHidden = !spinning
    }
}

// MARK: - Child window for target="_blank"

private enum ChildWindow {
    static func make(for controller: WebController, title: String) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 700),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false)
        window.title = title
        window.isReleasedWhenClosed = false
        window.center()
        window.contentView = controller.makeContentView()
        return window
    }
}

// MARK: - Native notifications

/// Best-effort native notification via `NSUserNotification` (works for a plain
/// Developer-ID bundle without the UserNotifications entitlement/authorization
/// dance). If the web UI never posts, this is simply never called.
private enum NativeNotifier {
    static func post(title: String, body: String) {
        let n = NSUserNotification()
        n.title = title
        n.informativeText = body
        NSUserNotificationCenter.default.deliver(n)
    }
}
