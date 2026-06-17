import Foundation

enum ProviderRegistry {
    static let all: [ProviderDescriptor] = ProviderKind.allCases.map {
        descriptor(for: $0)
    }

    static func descriptor(for kind: ProviderKind) -> ProviderDescriptor {
        switch kind {
        case .claudeCode:
            return ProviderDescriptor(
                kind: kind,
                displayName: "Claude Code",
                shortDisplayName: "Claude",
                symbolName: "sparkles",
                emptySessionListTitle: "No Claude Code Sessions",
                emptySessionListMessage: "Start using Claude Code to see\nyour sessions here."
            )
        case .codex:
            return ProviderDescriptor(
                kind: kind,
                displayName: "Codex",
                shortDisplayName: "Codex",
                symbolName: "terminal",
                emptySessionListTitle: "No Codex Sessions",
                emptySessionListMessage: "Start using Codex to see\nyour sessions here."
            )
        }
    }
}
