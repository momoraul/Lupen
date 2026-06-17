import Foundation

/// Single source of truth for the user-visible state of Lupen's statusline
/// integration. Every UI surface — Settings tab, dashboard banner,
/// menu-bar dropdown row, Reports footer — observes the same enum so
/// the app can never drift into a state where one surface says
/// "connected" while another says "broken".
///
/// The state is **derived**, not stored. `StatuslineConnectionService`
/// computes it from on-disk facts (settings.json contents, wrapper
/// script existence, last-sample timestamp) every time it's asked,
/// using `AppSettings.statuslinePrefs` as a stable corner of truth for
/// "did the user once choose to connect".
enum StatuslineConnectionState: Sendable, Equatable {
    /// `~/.claude/settings.json` does not point statusLine.command at
    /// our wrapper, and the user has never asked us to connect.
    case neverConnected

    /// settings.json + wrapper are in place, and we received at least
    /// one sample within the last 24 hours.
    case connectedActive

    /// settings.json + wrapper are in place, but no sample has arrived
    /// yet (Pro/Max gating: the field only appears after the first API
    /// response in the session).
    case connectedAwaitingFirst

    /// settings.json + wrapper are in place, and the most recent sample
    /// is > 24 hours old. Usually means the user hasn't been using
    /// Claude Code; sometimes means Pro/Max plan was downgraded.
    case connectedStale

    /// User has connected, but Lupen.app moved or the wrapper's LUPEN_BIN
    /// path no longer resolves. The health check tries to auto-update
    /// the wrapper; on success the state flashes as `.drifted` for one
    /// observation cycle, then transitions to `.connectedActive`.
    case drifted

    /// settings.json or the wrapper is in a state we cannot recognise
    /// — most often because the user edited settings.json by hand. We
    /// don't auto-heal these; the user has to confirm via the
    /// Disconnect → Reconnect path so we don't clobber a deliberate
    /// override.
    case broken(reason: BrokenReason)

    enum BrokenReason: Sendable, Equatable {
        case wrapperMissing
        case wrapperUnexecutable
        case settingsNotPointingToWrapper
        case settingsFileMissing
        case settingsMalformed
    }

    /// True when the user has at least once gone through Connect and
    /// we still see *some* trace of that on disk. Differentiates
    /// `.neverConnected` from every other state for the dashboard
    /// banner's display rules.
    var isUserConfigured: Bool {
        switch self {
        case .neverConnected: return false
        default: return true
        }
    }

    /// True when samples are flowing or recently were. Drives the
    /// "use authoritative data" path in aggregation.
    var isReceivingSamples: Bool {
        switch self {
        case .connectedActive, .drifted: return true
        default: return false
        }
    }

    /// Short label for the menu-bar dropdown's status row.
    var shortLabel: String {
        switch self {
        case .neverConnected: return "Statusline not connected"
        case .connectedActive: return "Statusline connected"
        case .connectedAwaitingFirst: return "Statusline connected · waiting"
        case .connectedStale: return "Statusline connected · stale"
        case .drifted: return "Statusline reconnected"
        case .broken: return "Statusline broken"
        }
    }
}
