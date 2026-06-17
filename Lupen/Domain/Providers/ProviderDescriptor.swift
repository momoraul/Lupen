import Foundation

struct ProviderDescriptor: Equatable, Identifiable, Sendable {
    let kind: ProviderKind
    let displayName: String
    let shortDisplayName: String
    let symbolName: String
    let emptySessionListTitle: String
    let emptySessionListMessage: String

    var id: ProviderKind { kind }
}
