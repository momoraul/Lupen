//
//  ProviderConfiguration.swift
//  Lupen
//
//  Created by jaden on 2026/05/28.
//

import Foundation

struct ProviderConfiguration: Codable, Equatable, Sendable {
    let providerID: ProviderID
    var sourceRoots: [URL]
    var options: [String: String]

    init(
        providerID: ProviderID,
        sourceRoots: [URL] = [],
        options: [String: String] = [:]
    ) {
        self.providerID = providerID
        self.sourceRoots = sourceRoots
        self.options = options
    }

    var fingerprint: String {
        let roots = sourceRoots
            .map { $0.standardizedFileURL.path }
            .sorted()
            .joined(separator: "|")
        let opts = options.keys
            .sorted()
            .map { "\($0)=\(options[$0] ?? "")" }
            .joined(separator: "|")
        return "\(providerID.rawValue)#roots=\(roots)#options=\(opts)"
    }

    static func legacy(provider: ProviderKind, sourceRoot: URL? = nil) -> ProviderConfiguration {
        ProviderConfiguration(
            providerID: provider.providerID,
            sourceRoots: sourceRoot.map { [$0] } ?? [],
            options: [:]
        )
    }

    func withProviderID(_ providerID: ProviderID) -> ProviderConfiguration {
        ProviderConfiguration(
            providerID: providerID,
            sourceRoots: sourceRoots,
            options: options
        )
    }
}

struct ProviderConfigurationStore: Codable, Equatable, Sendable {
    private(set) var values: [ProviderID: ProviderConfiguration]

    init(_ values: [ProviderID: ProviderConfiguration] = [:]) {
        self.values = values
    }

    subscript(providerID: ProviderID) -> ProviderConfiguration? {
        get { values[providerID] }
        set { values[providerID] = newValue }
    }

    var providerIDs: [ProviderID] {
        values.keys.sorted { $0.rawValue < $1.rawValue }
    }

    static func legacy(
        claudeCodeRootPath: String? = nil,
        codexRootPath: String? = nil
    ) -> ProviderConfigurationStore {
        var store = ProviderConfigurationStore()
        store.values[ProviderKind.claudeCode.providerID] = .legacy(
            provider: .claudeCode,
            sourceRoot: rootURL(from: claudeCodeRootPath)
        )
        store.values[ProviderKind.codex.providerID] = .legacy(
            provider: .codex,
            sourceRoot: rootURL(from: codexRootPath)
        )
        return store
    }

    func mergingLegacyRoots(
        claudeCodeRootPath: String?,
        codexRootPath: String?
    ) -> ProviderConfigurationStore {
        var copy = self
        copy.ensureBuiltIn(provider: .claudeCode, rootPath: claudeCodeRootPath)
        copy.ensureBuiltIn(provider: .codex, rootPath: codexRootPath)
        return copy
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: DynamicProviderConfigurationKey.self)
        var decoded: [ProviderID: ProviderConfiguration] = [:]
        for key in container.allKeys {
            guard let providerID = try? ProviderID(fromRawSettingsKey: key.stringValue),
                  let configuration = try? container.decode(ProviderConfiguration.self, forKey: key) else {
                continue
            }
            decoded[providerID] = configuration.withProviderID(providerID)
        }
        self.values = decoded
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: DynamicProviderConfigurationKey.self)
        for providerID in providerIDs {
            guard let key = DynamicProviderConfigurationKey(stringValue: providerID.rawValue),
                  let configuration = values[providerID] else {
                continue
            }
            try container.encode(configuration.withProviderID(providerID), forKey: key)
        }
    }

    private mutating func ensureBuiltIn(provider: ProviderKind, rootPath: String?) {
        let id = provider.providerID
        if let root = Self.rootURL(from: rootPath) {
            var existing = values[id] ?? .legacy(provider: provider)
            existing.sourceRoots = [root]
            values[id] = existing.withProviderID(id)
        } else if values[id] == nil {
            values[id] = .legacy(provider: provider)
        }
    }

    private static func rootURL(from path: String?) -> URL? {
        guard let path = path?.trimmingCharacters(in: .whitespacesAndNewlines),
              !path.isEmpty else {
            return nil
        }
        return URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
    }
}

private struct DynamicProviderConfigurationKey: CodingKey {
    let stringValue: String
    let intValue: Int? = nil

    init?(stringValue: String) {
        self.stringValue = stringValue
    }

    init?(intValue: Int) {
        return nil
    }
}

private extension ProviderID {
    init(fromRawSettingsKey value: String) throws {
        guard !value.isEmpty && !value.contains(ProviderScopedID.separator) else {
            throw DecodingError.dataCorrupted(
                .init(codingPath: [], debugDescription: "Invalid provider id: \(value)")
            )
        }
        self.init(rawValue: value)
    }
}
