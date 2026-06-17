//
//  RawPayloadLocator.swift
//  Lupen
//
//  Created by jaden on 2026/05/28.
//

import Foundation

struct RawPayloadLocator: Codable, Equatable, Sendable {
    enum Kind: String, Codable, Equatable, Sendable {
        case stepLine
        case requestTokenCount
        case diagnosticLine
    }

    struct SourceFingerprint: Codable, Equatable, Sendable {
        let fileSize: UInt64
        let modificationTime: Date?
    }

    let provider: ProviderKind
    let kind: Kind
    let sourceURL: URL
    let byteOffset: UInt64?
    let lineOrdinal: Int?
    let lineByteCount: Int?
    let lineChecksum: UInt64?
    let fingerprint: SourceFingerprint?

    init(
        provider: ProviderKind,
        kind: Kind,
        sourceURL: URL,
        byteOffset: UInt64?,
        lineOrdinal: Int?,
        lineByteCount: Int? = nil,
        lineChecksum: UInt64? = nil,
        fingerprint: SourceFingerprint? = nil
    ) {
        self.provider = provider
        self.kind = kind
        self.sourceURL = sourceURL.standardizedFileURL
        self.byteOffset = byteOffset
        self.lineOrdinal = lineOrdinal
        self.lineByteCount = lineByteCount
        self.lineChecksum = lineChecksum
        self.fingerprint = fingerprint
    }

    static func checksum(for data: Data) -> UInt64 {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in data {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return hash
    }

    static func fingerprint(for url: URL) -> SourceFingerprint {
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.standardizedFileURL.path)
        let size = (attrs?[.size] as? NSNumber)?.uint64Value ?? 0
        return SourceFingerprint(
            fileSize: size,
            modificationTime: attrs?[.modificationDate] as? Date
        )
    }

    func withKind(_ kind: Kind) -> RawPayloadLocator {
        RawPayloadLocator(
            provider: provider,
            kind: kind,
            sourceURL: sourceURL,
            byteOffset: byteOffset,
            lineOrdinal: lineOrdinal,
            lineByteCount: lineByteCount,
            lineChecksum: lineChecksum,
            fingerprint: fingerprint
        )
    }

    var cacheKey: String {
        [
            provider.rawValue,
            kind.rawValue,
            sourceURL.standardizedFileURL.path,
            byteOffset.map(String.init) ?? "offset:nil",
            lineOrdinal.map(String.init) ?? "line:nil",
            lineChecksum.map(String.init) ?? "checksum:nil"
        ].joined(separator: "|")
    }
}
