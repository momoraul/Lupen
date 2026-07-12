//
//  VerificationSourceScope.swift
//  Lupen
//
//  Created by jaden on 2026/07/11.
//

import CryptoKit
import Foundation

/// Stable, path-private provenance for one verification run.
///
/// `rootHash` identifies the normalized source-root path without copying the
/// user's filesystem path into reports. It deliberately does not hash file
/// contents: verification already reads those files, and a second corpus walk
/// would add unnecessary I/O to every run.
struct VerificationSourceIdentity: Sendable, Equatable {
    let id: String
    let name: String
    let provider: ProviderKind
    let rootHash: String

    init(source: SessionSource) {
        self.id = source.id
        self.name = source.name
        self.provider = source.kind
        self.rootHash = Self.hash(normalizedRootPath: source.root.path)
    }

    private static func hash(normalizedRootPath: String) -> String {
        let digest = SHA256.hash(data: Data(normalizedRootPath.utf8))
        let hex = Array("0123456789abcdef".utf8)
        var bytes: [UInt8] = []
        bytes.reserveCapacity(64)
        for byte in digest {
            bytes.append(hex[Int(byte >> 4)])
            bytes.append(hex[Int(byte & 0x0f)])
        }
        return String(decoding: bytes, as: UTF8.self)
    }
}

/// Path-private file-generation marker for one source scan. It hashes only
/// normalized path, byte size, and modification time; file contents are not
/// read a second time. Keeping just the digest makes the post-verify stability
/// check O(1) retained memory and avoids exposing local paths in results.
struct VerificationSourceManifest: Sendable, Equatable {
    let fileCount: Int
    let digest: String

    init(files: [URL]) throws {
        var hasher = SHA256()
        for url in files.sorted(by: { $0.path < $1.path }) {
            let values = try url.resourceValues(forKeys: [
                .fileSizeKey,
                .contentModificationDateKey,
            ])
            let path = url.standardizedFileURL.path
            let byteSize = values.fileSize ?? -1
            let modifiedAtMilliseconds = values.contentModificationDate.map {
                Int64(($0.timeIntervalSince1970 * 1_000).rounded())
            } ?? -1
            let record = "\(path.utf8.count):\(path)\0\(byteSize)\0\(modifiedAtMilliseconds)\0"
            hasher.update(data: Data(record.utf8))
        }
        self.fileCount = files.count
        self.digest = Self.hex(hasher.finalize())
    }

    private static func hex(_ digest: SHA256.Digest) -> String {
        let hex = Array("0123456789abcdef".utf8)
        var bytes: [UInt8] = []
        bytes.reserveCapacity(64)
        for byte in digest {
            bytes.append(hex[Int(byte >> 4)])
            bytes.append(hex[Int(byte & 0x0f)])
        }
        return String(decoding: bytes, as: UTF8.self)
    }
}

/// Independent truth calculation plus the exact source metadata used to
/// produce it. The discovered URL list is intentionally not retained.
struct ProviderVerificationScan: Sendable, Equatable {
    let source: VerificationSourceIdentity
    let filesScanned: Int
    let report: GroundTruth.Report
    let sourceManifest: VerificationSourceManifest
}

enum VerificationSourceError: Error, LocalizedError, Sendable, Equatable {
    case providerMismatch(expected: ProviderKind, actual: ProviderKind)
    case rootMissing(VerificationSourceIdentity)
    case rootNotDirectory(VerificationSourceIdentity)
    case rootUnreadable(VerificationSourceIdentity)
    case discoveryIncomplete(VerificationSourceIdentity)
    case noLogs(VerificationSourceIdentity)
    case sourceChangedDuringVerification(VerificationSourceIdentity)

    var source: VerificationSourceIdentity? {
        switch self {
        case .providerMismatch:
            return nil
        case .rootMissing(let source),
             .rootNotDirectory(let source),
             .rootUnreadable(let source),
             .discoveryIncomplete(let source),
             .noLogs(let source),
             .sourceChangedDuringVerification(let source):
            return source
        }
    }

    var errorDescription: String? {
        switch self {
        case .providerMismatch(let expected, let actual):
            return "Verifier provider \(expected.rawValue) does not match source provider \(actual.rawValue)."
        case .rootMissing(let source):
            return "Verification source '\(source.name)' (\(source.id)) has no available root directory."
        case .rootNotDirectory(let source):
            return "Verification source '\(source.name)' (\(source.id)) does not point to a directory."
        case .rootUnreadable(let source):
            return "Verification source '\(source.name)' (\(source.id)) is not readable."
        case .discoveryIncomplete(let source):
            return "Verification source '\(source.name)' (\(source.id)) could not be scanned completely."
        case .noLogs(let source):
            return "Verification source '\(source.name)' (\(source.id)) contains no session logs."
        case .sourceChangedDuringVerification(let source):
            return "Verification source '\(source.name)' (\(source.id)) changed during verification. Run it again."
        }
    }
}

enum VerificationSourceScope {
    static func files(for source: SessionSource) throws -> [URL] {
        let identity = VerificationSourceIdentity(source: source)
        try validateRoot(source.root, identity: identity)

        switch source.kind {
        case .claudeCode:
            // FileDiscovery preserves filesystem enumeration order, so impose
            // the verifier's deterministic ordering exactly once here.
            let discovery = FileDiscovery()
                .discoverJSONLFilesWithDiagnostics(in: source.root)
            guard discovery.isComplete else {
                throw VerificationSourceError.discoveryIncomplete(identity)
            }
            return discovery.files
                .map(\.url)
                .sorted { $0.path < $1.path }
        case .codex:
            // SessionSource's Codex root contract is codexHome. The discovery
            // implementation performs its single deterministic path sort.
            let discovery = CodexSessionDiscovery(codexHome: source.root)
                .discoverRolloutFilesWithDiagnostics()
            guard discovery.isComplete else {
                throw VerificationSourceError.discoveryIncomplete(identity)
            }
            return discovery.files
        }
    }

    static func manifest(for source: SessionSource) throws -> VerificationSourceManifest {
        try VerificationSourceManifest(files: files(for: source))
    }

    private static func validateRoot(
        _ root: URL,
        identity: VerificationSourceIdentity
    ) throws {
        let fileManager = FileManager.default
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: root.path, isDirectory: &isDirectory) else {
            throw VerificationSourceError.rootMissing(identity)
        }
        guard isDirectory.boolValue else {
            throw VerificationSourceError.rootNotDirectory(identity)
        }
        guard fileManager.isReadableFile(atPath: root.path) else {
            throw VerificationSourceError.rootUnreadable(identity)
        }
    }
}
