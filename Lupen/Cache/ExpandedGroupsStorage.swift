import Foundation

/// Tiny JSON persistence utility for the sidebar's expanded project-group keys.
///
/// Stores a `Set<String>` of provider-scoped project keys (as used in
/// `SessionListViewController.expandedProjectKeys`) at the app's
/// expanded-projects location.
///
/// Shape: the on-disk representation is a plain **sorted JSON array of
/// strings**, not a dictionary. Sorting is deterministic so repeated saves of
/// the same set produce identical bytes (nicer to eyeball, diff, and reason
/// about than dictionary-hash-order).
///
/// The load/save methods are intentionally synchronous and free-standing —
/// debouncing is the caller's responsibility (see
/// `SessionListViewController.scheduleSaveExpandedState`). Keeping it that way
/// leaves this type trivially testable and avoids introducing a MainActor
/// dependency in a pure I/O helper.
struct ExpandedGroupsStorage: Sendable {
    let fileURL: URL

    init(fileURL: URL? = nil) {
        if let url = fileURL {
            self.fileURL = url
        } else {
            let base: URL
            if let configDir = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"] {
                base = URL(fileURLWithPath: configDir)
            } else {
                base = FileManager.default.homeDirectoryForCurrentUser
                    .appendingPathComponent(".claude")
            }
            self.fileURL = base
                .appendingPathComponent("lupen")
                .appendingPathComponent("expanded_projects.json")
        }
    }

    /// Reads the persisted set of expanded project keys. Returns an empty set
    /// on missing / unreadable / corrupt files — first launch and file rot
    /// both degrade gracefully to "everything collapsed", which matches the
    /// VC's default.
    func load() -> Set<String> {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        guard let array = try? JSONDecoder().decode([String].self, from: data) else {
            LoggerService.shared.logFromAnyThread(
                .warning,
                "Failed to decode expanded_projects.json — treating as empty",
                context: "Cache"
            )
            return []
        }
        return Set(array.map(Self.normalizeKey))
    }

    /// Writes the given set to disk atomically. Creates the parent directory
    /// if missing. Failures are logged, never thrown — persistence of UI
    /// expansion state is best-effort and should never crash the app.
    func save(_ keys: Set<String>) {
        do {
            let dir = fileURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            // Sort for deterministic file contents — same input always
            // produces the same bytes, which is handy when diffing by hand.
            let sorted = keys.map(Self.normalizeKey).sorted()
            let data = try JSONEncoder().encode(sorted)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            LoggerService.shared.logFromAnyThread(
                .error,
                "Failed to save expanded groups: \(error.localizedDescription)",
                context: "Cache"
            )
        }
    }

    private static func normalizeKey(_ key: String) -> String {
        if key.hasPrefix("\(ProviderKind.claudeCode.rawValue):")
            || key.hasPrefix("\(ProviderKind.codex.rawValue):") {
            return key
        }
        return "\(ProviderKind.claudeCode.rawValue):\(key)"
    }
}
