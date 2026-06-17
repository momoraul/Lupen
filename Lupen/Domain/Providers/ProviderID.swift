//
//  ProviderID.swift
//  Lupen
//
//  Created by jaden on 2026/05/28.
//

import Foundation

struct ProviderID: RawRepresentable, Codable, Hashable, Identifiable, Sendable, ExpressibleByStringLiteral, CustomStringConvertible {
    let rawValue: String

    var id: String { rawValue }
    var description: String { rawValue }

    init(rawValue: String) {
        precondition(Self.isValid(rawValue), "ProviderID must be non-empty and must not contain ':'")
        self.rawValue = rawValue
    }

    init(stringLiteral value: StringLiteralType) {
        self.init(rawValue: value)
    }

    init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer().decode(String.self)
        guard Self.isValid(value) else {
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: "Invalid provider id: \(value)")
            )
        }
        self.rawValue = value
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    private static func isValid(_ value: String) -> Bool {
        !value.isEmpty && !value.contains(ProviderScopedID.separator)
    }
}

extension ProviderKind {
    var providerID: ProviderID {
        ProviderID(rawValue: rawValue)
    }

    init?(providerID: ProviderID) {
        self.init(rawValue: providerID.rawValue)
    }
}
