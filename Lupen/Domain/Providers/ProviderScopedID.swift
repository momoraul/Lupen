import Foundation

struct ProviderScopedID: Codable, Equatable, Hashable, Sendable, CustomStringConvertible {
    static let separator = ":"

    let provider: ProviderKind
    let rawSessionId: String

    var value: String {
        "\(provider.rawValue)\(Self.separator)\(rawSessionId)"
    }

    var description: String { value }

    init(provider: ProviderKind, rawSessionId: String) {
        self.provider = provider
        self.rawSessionId = rawSessionId
    }

    static func normalize(_ id: String, defaultProvider: ProviderKind) -> String {
        if ProviderScopedID(value: id) != nil {
            return id
        }
        if ProviderKind.allCases.contains(where: { id.hasPrefix("\($0.rawValue)\(Self.separator)") }) {
            return id
        }
        return ProviderScopedID(provider: defaultProvider, rawSessionId: id).value
    }

    static func rawID(from id: String) -> String {
        ProviderScopedID(value: id)?.rawSessionId ?? id
    }

    init?(value: String) {
        guard let separatorRange = value.range(of: Self.separator) else {
            return nil
        }
        let providerRaw = String(value[..<separatorRange.lowerBound])
        let rawSessionId = String(value[separatorRange.upperBound...])
        guard let provider = ProviderKind(rawValue: providerRaw),
              !rawSessionId.isEmpty else {
            return nil
        }
        self.provider = provider
        self.rawSessionId = rawSessionId
    }
}
