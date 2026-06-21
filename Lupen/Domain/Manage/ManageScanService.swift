//
//  ManageScanService.swift
//  Lupen
//
//  Created by jaden on 2026/06/20.
//

import Foundation

/// Scan cancellation flag. Because `Task.detached` does not inherit the parent
/// Task's cancellation, the caller (`ManageStore`) uses this flag to explicitly
/// stop an in-progress scan when it starts a new load (avoiding wasted CPU on
/// scans that will be discarded during rapid provider toggling).
final class ScanCancellationFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var _cancelled = false
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return _cancelled }
    func cancel() { lock.lock(); _cancelled = true; lock.unlock() }
}

/// Scans the session area / home directory in the background (detached, utility
/// QoS). Zero main-thread blocking (plan §3.1). Discarding stale results is
/// handled by the caller `ManageStore` via a generation token; mid-way
/// cancellation is handled by `ScanCancellationFlag`.
struct ManageScanService: Sendable {

    /// An inventory of every `.jsonl` in the session area — the diskFiles input
    /// to `ManageReconciler` (existence check + untracked discovery).
    func scanSessionArea(roots: [URL], isCancelled: @escaping @Sendable () -> Bool = { false }) async -> [ManageReconciler.DiskFile] {
        await Task.detached(priority: .utility) {
            var out: [ManageReconciler.DiskFile] = []
            for root in roots {
                if isCancelled() { break }
                Self.collectJSONLFiles(in: root, into: &out, isCancelled: isCancelled)
            }
            return out
        }.value
    }

    /// The All Disk tab — the 1-depth allocated-size items of the provider home (read-only).
    func scanDiskItems(home: URL, isCancelled: @escaping @Sendable () -> Bool = { false }) async -> [DiskSizer.Entry] {
        await Task.detached(priority: .utility) {
            DiskSizer.childEntries(of: home, isCancelled: isCancelled)
        }.value
    }

    // MARK: - Internal

    static func collectJSONLFiles(in root: URL, into out: inout [ManageReconciler.DiskFile], isCancelled: () -> Bool = { false }) {
        let keys: Set<URLResourceKey> = [
            .isRegularFileKey, .totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .contentModificationDateKey,
        ]
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: Array(keys),
            options: [],
            errorHandler: { _, _ in true }
        ) else { return }

        for case let url as URL in enumerator {
            if isCancelled() { return }
            guard url.pathExtension == "jsonl",
                  let vals = try? url.resourceValues(forKeys: keys),
                  vals.isRegularFile == true else { continue }
            let size = Int64(vals.totalFileAllocatedSize ?? vals.fileAllocatedSize ?? 0)
            out.append(ManageReconciler.DiskFile(
                path: url.path,
                sizeBytes: size,
                modifiedAt: vals.contentModificationDate
            ))
        }
    }
}
