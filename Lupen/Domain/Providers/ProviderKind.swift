import Foundation

/// User-visible data source mode. Raw values are persisted in
/// `app_settings.json`, so keep them stable.
enum ProviderKind: String, Codable, CaseIterable, Identifiable, Hashable, Sendable {
    case claudeCode = "claudeCode"
    case codex

    var id: String { rawValue }

    var descriptor: ProviderDescriptor {
        ProviderRegistry.descriptor(for: self)
    }

    var verificationMenuTitle: String {
        switch self {
        case .claudeCode: return "Verify Costs…"
        case .codex:      return "Verify Usage…"
        }
    }

    var verificationWindowTitle: String {
        switch self {
        case .claudeCode: return "Verify Costs"
        case .codex:      return "Verify Usage"
        }
    }

    /// CLI command prefix that resumes a session by id; `SessionResumer`
    /// appends the single-quoted session id. Claude resumes by flag
    /// (`claude --resume <id>`), Codex by subcommand (`codex resume <id>`).
    var resumeCommandPrefix: String {
        switch self {
        case .claudeCode: return "claude --resume"
        case .codex:      return "codex resume"
        }
    }
}
