//
//  ManageModels.swift
//  Lupen
//
//  Created by jaden on 2026/06/20.
//

import Foundation

/// "Manage Sessions & Storage" 윈도우의 상단 탭(스코프).
///
/// `sessions`/`projects`/`cache`는 기본 뷰(세션영역 내부)로 정리(휴지통)가
/// 가능하고, `allDisk`는 provider 홈 전체를 보는 읽기전용 보조 뷰다
/// (research-ccmgr.md §1.6 — 2단계 표시 결정).
enum ManageScope: String, CaseIterable, Sendable, Identifiable {
    case sessions
    case cache
    case allDisk

    var id: String { rawValue }

    var title: String {
        switch self {
        case .sessions: return "Sessions"
        case .cache:    return "Lupen Cache"
        case .allDisk:  return "All Disk"
        }
    }
}

/// 한 행이 나타내는 항목의 종류.
enum ManageItemKind: String, Sendable, Equatable {
    /// 인덱스가 아는 세션 (추적).
    case session
    /// 세션영역 내부지만 인덱스가 모르는 `.jsonl` (미추적).
    case orphanFile
    /// provider 홈 루트의 큰 점유물 (읽기전용 보조 뷰).
    case diskItem
    /// 인덱스에는 있으나 디스크에 원본 파일이 없는 잔재 (prune 대상).
    case indexRemnant
}

/// 삭제 안전 분류 — 시각 언어(색·아이콘)로 사용자에게 신뢰감을 준다.
/// (research §B-5: 색 단독 의존 금지, 배지/툴팁 텍스트와 병행)
enum StorageClassification: String, Sendable, Equatable {
    case safe          // 🟢 재생성 가능·완료 세션
    case caution       // 🟡 최근/미추적/큰 파일
    case danger        // 🔴 위험 (동작 가능 여부는 protection이 결정)
    case unclassified  // ⚪ 분류 규칙 밖
}

/// 앱 안에서 허용되는 동작. allowlist 모델 — `deletable`만 휴지통 가능.
enum StorageProtection: String, Sendable, Equatable {
    /// 휴지통 이동 가능 (확인 마찰은 별도 calibration).
    case deletable
    /// 앱 내 삭제 차단 — Reveal in Finder만 (auth/config/앱상태 DB/세션영역 밖/인덱싱 중).
    case blocked
    /// 미분류 — 삭제 잠김 (미분류=삭제불가 원칙).
    case locked

    /// 휴지통 이동을 허용하는 유일한 상태.
    var canTrash: Bool { self == .deletable }
}

/// 행 상태 — 이모지 컬럼으로 표시(사용자 요구). 분류(deletable 여부)와 별개로
/// "왜 주의해야 하는지"를 한눈에 보여준다.
enum ManageStatus: String, Sendable, Equatable {
    case normal
    case recentlyActive
    case untracked
    case indexing
    case blocked
    case error

    var emoji: String {
        switch self {
        case .normal:         return ""
        case .recentlyActive: return "🕐"
        case .untracked:      return "❓"
        case .indexing:       return "⏳"
        case .blocked:        return "🔒"
        case .error:          return "⚠️"
        }
    }
    var label: String {
        switch self {
        case .normal:         return "Normal"
        case .recentlyActive: return "Recently active"
        case .untracked:      return "Untracked"
        case .indexing:       return "Indexing"
        case .blocked:        return "Blocked"
        case .error:          return "Error"
        }
    }
    /// 디테일 패널에 보여줄 상태 설명(정상이면 빈 문자열).
    var detailDescription: String {
        switch self {
        case .normal:         return ""
        case .recentlyActive: return "Active within the last ~10 minutes. It may be in use — confirm before deleting."
        case .untracked:      return "Not tracked by the Lupen index. Only path and size are known; delete with extra care."
        case .indexing:       return "Indexing is in progress. The status updates automatically when it finishes."
        case .blocked:        return "auth/config, app-state DB, or outside the session area — can't be deleted in-app. Use Reveal in Finder."
        case .error:          return "The original file is missing on disk (index remnant) or failed to parse."
        }
    }
    /// 상태 컬럼 정렬 순서(우선순위가 높은 상태가 위로).
    var sortOrder: Int {
        switch self {
        case .blocked:        return 0
        case .error:          return 1
        case .indexing:       return 2
        case .untracked:      return 3
        case .recentlyActive: return 4
        case .normal:         return 5
        }
    }
}

/// 관리 리스트의 한 행. 인덱스(즉시) + FS 실측(보정)을 대조한 결과.
/// 순수 값 타입 — UI/동시성 의존 없음(P1 토대, 테스트 대상).
struct ManageRowModel: Sendable, Equatable, Identifiable {
    /// provider-scoped 세션 id, 또는 미추적/디스크 항목의 대표 경로.
    let id: String
    let provider: ProviderKind
    let kind: ManageItemKind

    var displayTitle: String
    /// 원본 세션 id(Resume용). orphan/디스크 항목은 nil.
    var rawSessionId: String? = nil
    /// 디코드된 실제 프로젝트 경로(표시·Reveal용).
    var projectPath: String? = nil
    /// `~/.claude/projects` 아래 인코딩된 디렉터리명(원본).
    var encodedProject: String? = nil
    var branch: String? = nil
    var firstPrompt: String? = nil
    /// 세션 시작(생성) 시각 — Created 컬럼.
    var createdAt: Date? = nil
    /// 마지막 활동(업데이트) 시각 — Updated 컬럼.
    var lastActivity: Date? = nil

    /// 디스크 점유 byte. 표시는 `ByteCountFormatter`, **정렬은 이 Int64**.
    var sizeBytes: Int64 = 0
    /// true면 인덱스 근사값(실측 전) — UI에서 옅은 색/`~`로 표시.
    var isEstimatedSize: Bool = false
    var fileCount: Int = 0

    /// 삭제 대상 파일 경로들(세션의 모든 source 파일).
    var filePaths: [String] = []
    /// 세션 동반 디렉터리 `<sessionId>/`(있으면 함께 휴지통).
    var companionDirectory: String? = nil

    var parseState: StoreParseState? = nil
    var status: ManageStatus = .normal
    var classification: StorageClassification = .unclassified
    var protection: StorageProtection = .locked
    var isIndexed: Bool = false
    var existsOnDisk: Bool = true

    /// 컬럼 표시용 짧은 프로젝트명(경로의 마지막 컴포넌트).
    var projectName: String {
        guard let projectPath, !projectPath.isEmpty else { return "—" }
        let name = (projectPath as NSString).lastPathComponent
        return name.isEmpty ? projectPath : name
    }

    /// 휴지통 이동 시 실제로 옮길 경로(파일 + 동반 디렉터리).
    var trashTargets: [String] {
        var targets = filePaths
        if let companionDirectory { targets.append(companionDirectory) }
        return targets
    }
}
