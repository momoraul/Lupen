//
//  ManageScanService.swift
//  Lupen
//
//  Created by jaden on 2026/06/20.
//

import Foundation

/// 스캔 취소 플래그. `Task.detached`는 부모 Task의 취소를 전파받지 않으므로,
/// 호출부(`ManageStore`)가 새 load를 시작할 때 이 플래그로 진행 중인 스캔을
/// 명시적으로 중단시킨다(빠른 provider 토글 시 버려질 스캔의 CPU 낭비 방지).
final class ScanCancellationFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var _cancelled = false
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return _cancelled }
    func cancel() { lock.lock(); _cancelled = true; lock.unlock() }
}

/// 세션영역/홈 디렉터리를 백그라운드(detached, utility QoS)에서 스캔한다.
/// 메인스레드 블로킹 0 (plan §3.1). 오래된 결과의 폐기는 호출부 `ManageStore`가
/// generation 토큰으로, 진행 중단은 `ScanCancellationFlag`로 처리한다.
struct ManageScanService: Sendable {

    /// 세션영역의 모든 `.jsonl` 인벤토리 — `ManageReconciler`의 diskFiles
    /// 입력(존재 확인 + 미추적 발견).
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

    /// 전체 디스크 탭 — provider 홈의 1-depth 점유물(읽기전용).
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
