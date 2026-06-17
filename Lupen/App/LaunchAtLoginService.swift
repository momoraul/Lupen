import Foundation
import ServiceManagement

/// Thin wrapper over `SMAppService.mainApp` so `AppSettings` doesn't
/// need to import ServiceManagement or know the registration ceremony.
///
/// `SMAppService.mainApp` registers a Login Item that points at the
/// currently-running app bundle. The system remembers it across
/// restarts; subsequent `register()` calls on the same bundle are
/// idempotent (documented behaviour).
///
/// We surface two entry points:
/// * `currentStatus()` — snapshot of the system's belief. Returns nil
///   when the API is unavailable on the running macOS version (defensive
///   fallback only — macOS 13+ always supports it).
/// * `setEnabled(_:)` — register / unregister. Errors are logged, not
///   thrown: a failed register is a non-fatal UX blip ("the toggle
///   didn't flip"), handled by the Preferences form re-reading the
///   status after any change.
@MainActor
enum LaunchAtLoginService {

    /// Reports whether macOS currently considers Lupen a login
    /// item. Maps `.enabled` → true; everything else (`.notRegistered`,
    /// `.notFound`, `.requiresApproval`) → false, because the app will
    /// not actually auto-launch in any of those states.
    ///
    /// Returns nil only if `SMAppService.mainApp` is unavailable (never
    /// in practice on macOS 13+, but we guard against future
    /// deprecation rather than trapping).
    static func currentStatus() -> Bool? {
        SMAppService.mainApp.status == .enabled
    }

    /// Register (true) or unregister (false) Lupen as a login
    /// item. Errors are logged via `LoggerService` and swallowed so a
    /// flaky first call doesn't crash the preferences window.
    static func setEnabled(_ enabled: Bool) {
        let service = SMAppService.mainApp
        do {
            if enabled {
                try service.register()
                LoggerService.shared.info(
                    "Registered Lupen as a login item",
                    context: "LaunchAtLogin"
                )
            } else {
                try service.unregister()
                LoggerService.shared.info(
                    "Unregistered Lupen as a login item",
                    context: "LaunchAtLogin"
                )
            }
        } catch {
            LoggerService.shared.error(
                "SMAppService.\(enabled ? "register" : "unregister")() failed: \(error.localizedDescription)",
                context: "LaunchAtLogin"
            )
        }
    }
}
