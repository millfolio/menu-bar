import SwiftUI
import Sparkle

/// Sparkle auto-update glue.
///
/// The app ships as a Developer-ID-signed, notarized `.pkg` for first install, but
/// in-place updates come through Sparkle: the running app periodically fetches
/// `SUFeedURL` (https://millfolio.app/appcast.xml), and each update item points at a
/// zipped, EdDSA-signed `Millfolio.app`. All the feed/interval/public-key config
/// lives in Info.plist (`SUFeedURL`, `SUPublicEDKey`, `SUEnableAutomaticChecks`,
/// `SUScheduledCheckInterval`); this type just owns the controller and surfaces a
/// "Check for Updates…" action for the menu.
///
/// `SPUStandardUpdaterController` is started automatically (`startingUpdater: true`),
/// which begins the scheduled background checks per the Info.plist defaults. The
/// user can still toggle automatic checks / change the interval through Sparkle's
/// built-in update UI.
@MainActor
final class UpdaterController: ObservableObject {
    private let controller: SPUStandardUpdaterController

    /// Mirrors `SPUUpdater.canCheckForUpdates` so a SwiftUI menu item can disable the
    /// "Check for Updates…" command while a check is already in flight.
    @Published var canCheckForUpdates = false

    init() {
        // startingUpdater:true kicks off the updater immediately (scheduled checks
        // begin per Info.plist). No custom delegates — the standard user driver
        // presents Sparkle's own update/prefs UI.
        controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        controller.updater.publisher(for: \.canCheckForUpdates)
            .receive(on: RunLoop.main)
            .assign(to: &$canCheckForUpdates)
    }

    /// User-initiated update check (shows UI even when up to date). Wired to the
    /// "Check for Updates…" menu items.
    func checkForUpdates() {
        controller.updater.checkForUpdates()
    }
}
