//
//  ManageDeletionPlanner.swift
//  Lupen
//
//  Created by jaden on 2026/06/20.
//

import Foundation

/// 삭제 확인 마찰 단계 (GitLab Pajamas 3단계, research §B-5).
enum DeletionFriction: Sendable, Equatable {
    case low     // 단건·가역·안전 → 모달 없이 휴지통 + Undo 스낵바
    case medium  // 여러 개 또는 주의 → 확인 모달
    case high    // 대량 또는 미추적 → 모달 + 타이핑 확인
}

/// 삭제 흐름의 순수 결정 로직(테스트 대상). 실제 휴지통/인덱스 조작은
/// `ManageTrashService`/`ManageStore`가 담당.
enum ManageDeletionPlanner {
    static let bulkCountThreshold = 20
    static let bulkByteThreshold: Int64 = 1_000_000_000   // 1 GB

    /// 후보가 모두 휴지통 가능한가. blocked/locked가 하나라도 섞이면 false
    /// (allowlist — 미분류·차단은 삭제 불가).
    static func allDeletable(_ rows: [ManageRowModel]) -> Bool {
        !rows.isEmpty && rows.allSatisfy { $0.protection == .deletable }
    }

    static func totalBytes(_ rows: [ManageRowModel]) -> Int64 {
        rows.reduce(0) { $0 + $1.sizeBytes }
    }

    static func friction(rows: [ManageRowModel]) -> DeletionFriction {
        let count = rows.count
        let hasUntracked = rows.contains { !$0.isIndexed }
        if hasUntracked || count >= bulkCountThreshold || totalBytes(rows) >= bulkByteThreshold {
            return .high
        }
        if count > 1 || rows.contains(where: { $0.classification == .caution }) {
            return .medium
        }
        return .low
    }

    struct ConfirmCopy: Equatable {
        let title: String
        let body: String
        let confirmButton: String
        let requiresTyping: Bool
        let typingToken: String
    }

    static func confirmCopy(rows: [ManageRowModel]) -> ConfirmCopy {
        let count = rows.count
        let size = ByteCountFormatter.string(fromByteCount: totalBytes(rows), countStyle: .file)
        let hasUntracked = rows.contains { !$0.isIndexed }
        let noun = "\(count) \(hasUntracked ? "item" : "session")\(count == 1 ? "" : "s")"
        let lead = hasUntracked
            ? "These files are not tracked by Lupen."
            : "Conversation history and attached logs will be removed."
        return ConfirmCopy(
            title: "Move \(noun) to Trash?",
            body: "\(lead) Reclaims \(size).\nYou can restore from Trash for 30 days.",
            confirmButton: "Delete \(noun)",
            requiresTyping: friction(rows: rows) == .high,
            typingToken: "DELETE"
        )
    }
}
