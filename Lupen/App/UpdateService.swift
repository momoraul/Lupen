import AppKit
import Sparkle

/// Thin wrapper around `SPUStandardUpdaterController` so the rest of
/// the app interacts with a small, single-purpose surface instead of
/// reaching into Sparkle directly. Two reasons:
///
///   1. **Selector targets are objects, not enums** — the menu item
///      "Check for Updates…" needs an `@objc` target. Sparkle's own
///      controller can be that target directly, but routing through
///      this wrapper lets us pre-process the action (logging,
///      analytics-free gating, future channel-switching).
///   2. **Preferences read/write SwiftUI bindings** — `AppSettings`-
///      shaped getters/setters here keep the Settings sheet free of
///      `@_implementationOnly import Sparkle` plumbing.
///
/// Lifecycle: instantiated once by `AppDelegate.applicationDidFinishLaunching`
/// (alongside the rest of the app's services). `startingUpdater: true`
/// kicks off the scheduled-check timer immediately so the first check
/// fires per the user's preference without a separate boot step.
///
/// **Public key embedding** — `SUPublicEDKey` is *not* in xcconfig.
/// CI injects it into the built `.app`'s Info.plist at release time
/// via PlistBuddy (see `Tools/derive-sparkle-public-key.swift`). On a
/// local dev build, the key is absent — Sparkle still installs as a
/// dependency and the menu item still works, but any actual update
/// fails signature verification. That's the intended dev-loop
/// behaviour: you can exercise the UI without holding the private
/// key, and only release builds can apply updates.
@MainActor
final class UpdateService: NSObject {

    static let shared = UpdateService()

    private let controller: SPUStandardUpdaterController

    private override init() {
        // `startingUpdater: true` — start the scheduled-check timer
        // right away. Setting `userDriverDelegate: nil` keeps us on
        // Sparkle's default UI for v1 (alerts + progress windows).
        // cmux's custom `SPUUserDriver` is excellent but ~13 files of
        // UI scope that we don't need before the first public
        // release; revisit when there's user feedback that the
        // default alerts feel wrong.
        self.controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        super.init()
    }

    /// Underlying Sparkle updater — exposed for Preferences UI so the
    /// SwiftUI form can bind to its `automaticallyChecksForUpdates`,
    /// `lastUpdateCheckDate`, etc. directly.
    var updater: SPUUpdater { controller.updater }

    /// Menu item action target. Use `target: UpdateService.shared`
    /// and `action: #selector(UpdateService.checkForUpdates(_:))` on
    /// the "Check for Updates…" menu item.
    @objc func checkForUpdates(_ sender: Any?) {
        controller.checkForUpdates(sender)
    }
}
