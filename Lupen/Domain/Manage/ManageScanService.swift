//
//  ManageScanService.swift
//  Lupen
//
//  Created by jaden on 2026/06/20.
//

import Foundation

/// 세션영역/홈 디렉터리를 백그라운드(detached, utility QoS)에서 스캔한다.
/// 메인스레드 블로킹 0 (plan §3.1). 오래된 결과의 폐기(취소)는 호출부
/// `ManageStore`가 generation 토큰으로 처리한다.
struct ManageScanService: Sendable {

    /// 세션영역의 모든 `.jsonl` 인벤토리 — `ManageReconciler`의 diskFiles
    /// 입력(존재 확인 + 미추적 발견).
    func scanSessionArea(roots: [URL]) async -> [ManageReconciler.DiskFile] {
        await Task.detached(priority: .utility) {
            var out: [ManageReconciler.DiskFile] = []
            for root in roots {
                Self.collectJSONLFiles(in: root, into: &out)
            }
            return out
        }.value
    }

    /// 전체 디스크 탭 — provider 홈의 1-depth 점유물(읽기전용).
    func scanDiskItems(home: URL) async -> [DiskSizer.Entry] {
        await Task.detached(priority: .utility) {
            DiskSizer.childEntries(of: home)
        }.value
    }

    // MARK: - Internal

    static func collectJSONLFiles(in root: URL, into out: inout [ManageReconciler.DiskFile]) {
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
