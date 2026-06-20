//
//  ManageTrashService.swift
//  Lupen
//
//  Created by jaden on 2026/06/20.
//

import Foundation

/// 휴지통 이동과 복원(Undo)을 담당. 영구 삭제(`removeItem`)는 제공하지 않는다
/// — 안전 최우선(plan §13). 사용자가 영구 삭제를 원하면 Finder 휴지통을
/// 비운다. 백그라운드(detached)에서 실행해 메인스레드 블로킹 0.
struct ManageTrashService: Sendable {

    /// 한 번 휴지통 작업의 결과.
    struct Outcome: Sendable, Equatable {
        var trashedPaths: [String] = []
        var failedPaths: [String] = []
        /// Undo용 (원래 경로 → 휴지통 안 URL).
        var restore: [RestoreEntry] = []
    }

    struct RestoreEntry: Sendable, Equatable {
        let originalPath: String
        let trashedURL: URL
    }

    /// `paths`를 휴지통으로 이동. 이미 없는 경로는 조용히 건너뛴다(성공 취급
    /// 아님 — trashed에 안 넣음). 대량 시 Put Back 보존을 위해 한 항목씩 처리.
    func trash(_ paths: [String]) async -> Outcome {
        await Task.detached(priority: .userInitiated) {
            var outcome = Outcome()
            let fm = FileManager.default
            for path in paths {
                guard fm.fileExists(atPath: path) else { continue }
                let url = URL(fileURLWithPath: path)
                var resulting: NSURL?
                do {
                    try fm.trashItem(at: url, resultingItemURL: &resulting)
                    outcome.trashedPaths.append(path)
                    if let resultingURL = resulting as URL? {
                        outcome.restore.append(RestoreEntry(originalPath: path, trashedURL: resultingURL))
                    }
                } catch {
                    outcome.failedPaths.append(path)
                }
            }
            return outcome
        }.value
    }

    /// Undo — 휴지통의 항목을 원래 경로로 되돌린다. 원래 경로에 이미 무언가
    /// 있으면(재생성) 건너뛴다.
    func restore(_ entries: [RestoreEntry]) async {
        await Task.detached(priority: .userInitiated) {
            let fm = FileManager.default
            for entry in entries {
                let original = URL(fileURLWithPath: entry.originalPath)
                guard !fm.fileExists(atPath: entry.originalPath) else { continue }
                try? fm.moveItem(at: entry.trashedURL, to: original)
            }
        }.value
    }
}
