//
//  DiskSizer.swift
//  Lupen
//
//  Created by jaden on 2026/06/20.
//

import Foundation

/// 디렉터리/파일의 디스크 점유 크기를 계산하는 순수 헬퍼.
///
/// 무거운 재귀 스캔이므로 호출부(`ManageScanService`)가 백그라운드에서
/// 돌리고, `isCancelled`로 중도 취소한다(plan §3.1 — 메인스레드 블로킹 0).
/// 크기는 `totalFileAllocatedSize`(실제 점유) 우선, 없으면 논리 크기.
enum DiskSizer {

    /// `url` 아래 모든 정규 파일의 allocated size 합. 디렉터리면 재귀,
    /// 파일이면 자신의 크기. 존재하지 않으면 0.
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
            errorHandler: { _, _ in true }   // 읽기 실패한 항목은 건너뛰고 계속
        ) else { return 0 }

        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            if isCancelled() { break }
            total += fileAllocatedSize(fileURL)
        }
        return total
    }

    /// 정규 파일 한 개의 allocated size. 디렉터리/심볼릭 등은 0.
    static func fileAllocatedSize(_ url: URL) -> Int64 {
        guard let vals = try? url.resourceValues(
            forKeys: [.isRegularFileKey, .totalFileAllocatedSizeKey, .fileAllocatedSizeKey]
        ), vals.isRegularFile == true else { return 0 }
        if let s = vals.totalFileAllocatedSize { return Int64(s) }
        if let s = vals.fileAllocatedSize { return Int64(s) }
        return 0
    }

    /// 한 디렉터리의 1-depth 자식 항목(전체 디스크 탭용): 각 자식의
    /// 이름·총 크기·디렉터리 여부. 큰 점유물부터 정렬은 호출부에서.
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
            options: []   // 숨김 포함 — 큰 dot 디렉터리도 보여줘야 정리에 의미
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
