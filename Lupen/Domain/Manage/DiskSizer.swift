//
//  DiskSizer.swift
//  Lupen
//
//  Created by jaden on 2026/06/20.
//

import Foundation

/// A pure helper that computes the disk allocated size of a directory/file.
///
/// Because this is a heavy recursive scan, the caller (`ManageScanService`)
/// runs it in the background and cancels mid-way via `isCancelled`
/// (plan §3.1 — zero main-thread blocking).
/// Size prefers `totalFileAllocatedSize` (actual allocated size), falling back
/// to logical size.
enum DiskSizer {

    /// The sum of the allocated size of every regular file under `url`. Recurses
    /// for a directory; for a file, its own size. 0 if it does not exist.
    static func totalAllocatedSize(at url: URL, isCancelled: () -> Bool = { false }) -> Int64 {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { return 0 }
        if !isDir.boolValue {
            return fileAllocatedSize(url)
        }
        let keys: [URLResourceKey] = [.isRegularFileKey, .totalFileAllocatedSizeKey, .fileAllocatedSizeKey]
        guard let enumerator = fm.enumerator(
            at: url,
            includingPropertiesForKeys: keys,
            options: [],
            errorHandler: { _, _ in true }   // Skip items that fail to read and continue
        ) else { return 0 }

        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            if isCancelled() { break }
            total += fileAllocatedSize(fileURL)
        }
        return total
    }

    /// The allocated size of a single regular file. 0 for directories/symlinks/etc.
    static func fileAllocatedSize(_ url: URL) -> Int64 {
        guard let vals = try? url.resourceValues(
            forKeys: [.isRegularFileKey, .totalFileAllocatedSizeKey, .fileAllocatedSizeKey]
        ), vals.isRegularFile == true else { return 0 }
        if let s = vals.totalFileAllocatedSize { return Int64(s) }
        if let s = vals.fileAllocatedSize { return Int64(s) }
        return 0
    }

    /// The 1-depth child items of a directory (for the All Disk tab): each child's
    /// name, total size, and whether it is a directory. Sorting largest-allocated-first
    /// is done by the caller.
    struct Entry: Sendable, Equatable {
        let url: URL
        let name: String
        let sizeBytes: Int64
        let isDirectory: Bool
    }

    static func childEntries(of url: URL, isCancelled: () -> Bool = { false }) -> [Entry] {
        let fm = FileManager.default
        guard let children = try? fm.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: []   // Include hidden — large dot directories must show for cleanup to be meaningful
        ) else { return [] }

        var out: [Entry] = []
        for child in children {
            if isCancelled() { break }
            let isDir = (try? child.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
            let size = totalAllocatedSize(at: child, isCancelled: isCancelled)
            out.append(Entry(url: child, name: child.lastPathComponent, sizeBytes: size, isDirectory: isDir))
        }
        return out
    }
}
