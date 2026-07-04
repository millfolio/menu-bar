import AppKit
import Combine
import MillfolioCore

/// The native **first-run provisioning window** — the "no terminal" install.
///
/// On first launch (nothing provisioned yet) the app shows THIS window instead of
/// the `WebWindow`. It drives `MillfolioCore.Bootstrapper.installVault()` — the
/// exact same provision path the `mill` CLI runs (fetch the Mojo toolchain, unpack
/// the versioned bundle, place the prebuilt binaries + FFI shims, set up the
/// launchd agents, prime the vault compile cache) — and reflects its live progress
/// as a clean native step label + spinner, with a "Show details" disclosure for the
/// full step log. On success it starts the local servers (WITHOUT opening the system
/// browser — the app is the browser) and hands off to the `WebWindow`, whose own
/// first-run UI then handles data + model choice. On failure it shows the error with
/// Retry + "Copy diagnostics" + Open Log.
///
/// Design notes / the easy-to-miss bits:
///
///   * **Provisioning runs on `Bootstrapper`'s `@MainActor`.** Its network fetches
///     are `async` (they suspend, so the label + spinner update live), but the
///     on-device `mojo build` steps are synchronous `Process.waitUntilExit()` calls
///     that briefly block the main thread (~1–2 min total across the run). The
///     spinner uses `usesThreadedAnimation = true` so it keeps animating even then;
///     the step label may lag by one step across a long synchronous build. A fuller
///     fix (moving subprocess exec off the main actor in `MillfolioCore`) is
///     follow-up work — noted rather than reimplementing provisioning here.
///   * **No browser flash on handoff.** We start the app server with
///     `openBrowser: false`, and only *after* `startVaultChat` returns (which waits
///     until :10000 serves a static asset) do we hand off — so the `WebWindow`'s
///     poll overlay loads the page promptly instead of flashing a connect error.
///   * **Idempotent.** Every `installVault` sub-step fast-paths what's already
///     present, so Retry (or a re-run) resumes a partial install cheaply.

@MainActor
final class OnboardingWindowController: NSWindowController {
    private let bootstrapper: Bootstrapper
    private let onComplete: () -> Void

    init(bootstrapper: Bootstrapper, onComplete: @escaping () -> Void) {
        self.bootstrapper = bootstrapper
        self.onComplete = onComplete
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 460),
            styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        window.title = "Welcome to millfolio"
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        window.center()
        super.init(window: window)
        window.contentViewController = OnboardingViewController(
            bootstrapper: bootstrapper, onComplete: onComplete)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }
}

// MARK: - View controller

@MainActor
final class OnboardingViewController: NSViewController {
    private enum UIState { case intro, running, failed }

    private let bootstrapper: Bootstrapper
    private let onComplete: () -> Void
    private var cancellable: AnyCancellable?

    // Header
    private let iconView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "Welcome to millfolio")
    private let bodyLabel = NSTextField(wrappingLabelWithString: "")

    // Progress
    private let spinner = NSProgressIndicator()
    private let statusLabel = NSTextField(labelWithString: "")

    // Details disclosure
    private let detailsToggle = NSButton()
    private let detailsScroll = NSScrollView()
    private let detailsText = NSTextView()

    // Actions
    private let primaryButton = NSButton()
    private let copyButton = NSButton()
    private let openLogButton = NSButton()

    private var state: UIState = .intro

    init(bootstrapper: Bootstrapper, onComplete: @escaping () -> Void) {
        self.bootstrapper = bootstrapper
        self.onComplete = onComplete
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let root = NSView()
        root.translatesAutoresizingMaskIntoConstraints = false

        // Header icon = the app icon.
        iconView.image = NSApp.applicationIconImage
        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.widthAnchor.constraint(equalToConstant: 72).isActive = true
        iconView.heightAnchor.constraint(equalToConstant: 72).isActive = true

        titleLabel.font = .systemFont(ofSize: 22, weight: .semibold)
        titleLabel.alignment = .center

        bodyLabel.font = .systemFont(ofSize: 13)
        bodyLabel.textColor = .secondaryLabelColor
        bodyLabel.alignment = .center
        bodyLabel.maximumNumberOfLines = 0        // never truncate — height follows the text
        bodyLabel.preferredMaxLayoutWidth = 480   // matches the pinned stack width below

        spinner.style = .spinning
        spinner.controlSize = .regular
        spinner.isDisplayedWhenStopped = false
        // Keep animating even while the main thread is busy in a synchronous
        // `mojo build` step (see the class note).
        spinner.usesThreadedAnimation = true
        spinner.translatesAutoresizingMaskIntoConstraints = false

        statusLabel.font = .systemFont(ofSize: 13, weight: .medium)
        statusLabel.alignment = .center
        statusLabel.maximumNumberOfLines = 3
        statusLabel.lineBreakMode = .byWordWrapping
        statusLabel.preferredMaxLayoutWidth = 480
        (statusLabel.cell as? NSTextFieldCell)?.wraps = true

        detailsToggle.title = "Show details"
        detailsToggle.setButtonType(.pushOnPushOff)
        detailsToggle.bezelStyle = .disclosure
        detailsToggle.imagePosition = .imageLeading
        detailsToggle.target = self
        detailsToggle.action = #selector(toggleDetails)

        // Details step log — monospaced, read-only, scrollable.
        detailsText.isEditable = false
        detailsText.isSelectable = true
        detailsText.drawsBackground = true
        detailsText.backgroundColor = .textBackgroundColor
        detailsText.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        detailsText.textContainerInset = NSSize(width: 6, height: 6)
        detailsScroll.documentView = detailsText
        detailsScroll.hasVerticalScroller = true
        detailsScroll.borderType = .lineBorder
        detailsScroll.translatesAutoresizingMaskIntoConstraints = false
        detailsScroll.isHidden = true
        detailsScroll.heightAnchor.constraint(equalToConstant: 150).isActive = true

        primaryButton.bezelStyle = .rounded
        primaryButton.controlSize = .large
        primaryButton.keyEquivalent = "\r"   // default button (Return)
        primaryButton.target = self
        primaryButton.action = #selector(primaryTapped)

        copyButton.title = "Copy diagnostics"
        copyButton.bezelStyle = .rounded
        copyButton.target = self
        copyButton.action = #selector(copyDiagnostics)
        copyButton.isHidden = true

        openLogButton.title = "Open Log"
        openLogButton.bezelStyle = .rounded
        openLogButton.target = self
        openLogButton.action = #selector(openLog)
        openLogButton.isHidden = true

        let secondaryRow = NSStackView(views: [copyButton, openLogButton])
        secondaryRow.orientation = .horizontal
        secondaryRow.spacing = 10

        let stack = NSStackView(views: [
            iconView, titleLabel, bodyLabel, spinner, statusLabel,
            primaryButton, secondaryRow, detailsToggle, detailsScroll,
        ])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.setCustomSpacing(6, after: titleLabel)
        stack.setCustomSpacing(22, after: bodyLabel)
        stack.setCustomSpacing(20, after: statusLabel)
        root.addSubview(stack)
        NSLayoutConstraint.activate([
            // Fixed content width so the window doesn't resize as each state's text
            // changes length (480 + 40+40 padding = a stable 560-pt window).
            stack.widthAnchor.constraint(equalToConstant: 480),
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 40),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -40),
            stack.topAnchor.constraint(equalTo: root.topAnchor, constant: 36),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: root.bottomAnchor, constant: -28),
            // Pin the wrapping text labels to the full stack width (centerX alignment
            // otherwise leaves them at intrinsic width → narrow wrap + truncation).
            bodyLabel.leadingAnchor.constraint(equalTo: stack.leadingAnchor),
            bodyLabel.trailingAnchor.constraint(equalTo: stack.trailingAnchor),
            statusLabel.leadingAnchor.constraint(equalTo: stack.leadingAnchor),
            statusLabel.trailingAnchor.constraint(equalTo: stack.trailingAnchor),
            detailsScroll.leadingAnchor.constraint(equalTo: stack.leadingAnchor),
            detailsScroll.trailingAnchor.constraint(equalTo: stack.trailingAnchor),
        ])
        self.view = root
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        // Live status label ← the Bootstrapper's @Published phase.
        cancellable = bootstrapper.$phase
            .receive(on: RunLoop.main)
            .sink { [weak self] phase in self?.render(phase: phase) }
        applyState(.intro)
    }

    // MARK: state rendering

    private func applyState(_ s: UIState) {
        state = s
        switch s {
        case .intro:
            titleLabel.stringValue = "Welcome to millfolio"
            bodyLabel.stringValue =
                "millfolio runs entirely on your Mac. The first-time setup downloads "
                + "the toolchain and app, then builds the local engine — this can take "
                + "a few minutes and only happens once. No terminal required."
            spinner.stopAnimation(nil)
            statusLabel.stringValue = ""
            statusLabel.isHidden = true
            primaryButton.title = "Set Up millfolio"
            primaryButton.isHidden = false
            copyButton.isHidden = true
            openLogButton.isHidden = true
            detailsToggle.isHidden = true
        case .running:
            titleLabel.stringValue = "Setting up millfolio…"
            bodyLabel.stringValue = "This runs once and can take a few minutes. You can leave it running."
            spinner.startAnimation(nil)
            statusLabel.isHidden = false
            primaryButton.isHidden = true
            copyButton.isHidden = true
            openLogButton.isHidden = true
            detailsToggle.isHidden = false
        case .failed:
            titleLabel.stringValue = "Setup didn't finish"
            bodyLabel.stringValue = "Something went wrong during setup. You can retry, or copy the diagnostics to share."
            spinner.stopAnimation(nil)
            statusLabel.isHidden = false
            statusLabel.textColor = .systemRed
            primaryButton.title = "Retry"
            primaryButton.isHidden = false
            copyButton.isHidden = false
            openLogButton.isHidden = !bootstrapper.hasLog
            detailsToggle.isHidden = false
            // On failure, reveal the step log so the failure context is visible.
            if detailsScroll.isHidden { toggleDetails() }
        }
    }

    /// Update the big status label from the Bootstrapper phase (only meaningful while
    /// running / on failure — intro clears it).
    private func render(phase: Bootstrapper.Phase) {
        switch phase {
        case .running(let msg):
            statusLabel.textColor = .labelColor
            statusLabel.stringValue = msg
        case .failed(let msg):
            statusLabel.textColor = .systemRed
            statusLabel.stringValue = msg
        case .idle, .done:
            break
        }
    }

    private func appendDetail(_ line: String) {
        let text = line.hasSuffix("\n") ? line : line + "\n"
        detailsText.textStorage?.append(NSAttributedString(
            string: text,
            attributes: [
                .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .regular),
                .foregroundColor: NSColor.labelColor,
            ]))
        detailsText.scrollToEndOfDocument(nil)
    }

    // MARK: actions

    @objc private func primaryTapped() {
        // Both "Set Up" (intro) and "Retry" (failed) start provisioning.
        statusLabel.textColor = .labelColor
        applyState(.running)
        beginProvisioning()
    }

    @objc private func toggleDetails() {
        detailsScroll.isHidden.toggle()
        detailsToggle.title = detailsScroll.isHidden ? "Show details" : "Hide details"
        detailsToggle.state = detailsScroll.isHidden ? .off : .on
    }

    @objc private func openLog() { bootstrapper.openLog() }

    @objc private func copyDiagnostics() {
        var report = "millfolio setup diagnostics\n"
        report += "phase: \(bootstrapper.phase.message ?? "?")\n\n"
        report += "--- step log ---\n"
        report += detailsText.string
        // Append the tail of the install log if present.
        if bootstrapper.hasLog,
           let log = try? String(contentsOf: bootstrapper.logFileURL, encoding: .utf8) {
            report += "\n--- \(bootstrapper.logFileURL.lastPathComponent) (tail) ---\n"
            report += String(log.suffix(8000))
        }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(report, forType: .string)
        copyButton.title = "Copied ✓"
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { [weak self] in
            self?.copyButton.title = "Copy diagnostics"
        }
    }

    // MARK: provisioning

    private func beginProvisioning() {
        // Stream every step message into the details log (fires for every phase set,
        // so it's the complete step-by-step trace).
        bootstrapper.onProgress = { [weak self] line in
            Task { @MainActor in self?.appendDetail(line) }
        }
        appendDetail("Starting setup…")

        Task { @MainActor in
            do {
                // The SAME path `mill install` runs — do not reimplement it.
                try await bootstrapper.installVault()
                let dir = bootstrapper.ensureVaultDir()
                appendDetail("Starting the local servers…")
                statusLabel.stringValue = "Starting the local servers…"
                // openBrowser:false — the app renders :10000 in its own WKWebView, so
                // it must NOT spawn the system browser. This waits until :10000 serves
                // a static asset, so the WebWindow handoff is smooth (no error flash).
                try await bootstrapper.startVaultChat(vaultDir: dir, openBrowser: false)
                appendDetail("Setup complete.")
                onComplete()
            } catch {
                let msg = Self.message(for: error)
                appendDetail("ERROR: \(msg)")
                bootstrapper.phase = .failed(msg)
                applyState(.failed)
            }
        }
    }

    private static func message(for error: Error) -> String {
        if let b = error as? BootstrapError { return b.description }
        return (error as NSError).localizedDescription
    }
}
