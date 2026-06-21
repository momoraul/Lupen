//
//  ManageRowFilter.swift
//  Lupen
//
//  Created by jaden on 2026/06/20.
//

import Foundation

/// Column sort keys — a 1:1 mapping to NSTableView header clicks.
enum ManageRowSort: String, Sendable {
    case status
    case project
    case session
    case created
    case updated
    case size
    case files
}

/// A pure transform that applies search/sort to a row list (test target). Sorting
/// is on raw values rather than display values — to avoid broken lexicographic
/// ordering (research §B-4).
enum ManageRowFilter {
    static func apply(_ rows: [ManageRowModel], search: String, sort: ManageRowSort, ascending: Bool) -> [ManageRowModel] {
        var result = rows
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if !query.isEmpty {
            result = result.filter { row in
                row.displayTitle.lowercased().contains(query)
                    || (row.projectPath?.lowercased().contains(query) ?? false)
                    || (row.branch?.lowercased().contains(query) ?? false)
            }
        }
        result.sort { lhs, rhs in
            let ascendingOrder: Bool
            switch sort {
            case .status:
                ascendingOrder = lhs.status.sortOrder < rhs.status.sortOrder
            case .project:
                ascendingOrder = lhs.projectName.localizedCaseInsensitiveCompare(rhs.projectName) == .orderedAscending
            case .session:
                ascendingOrder = lhs.displayTitle.localizedCaseInsensitiveCompare(rhs.displayTitle) == .orderedAscending
            case .created:
                ascendingOrder = (lhs.createdAt ?? .distantPast) < (rhs.createdAt ?? .distantPast)
            case .updated:
                ascendingOrder = (lhs.lastActivity ?? .distantPast) < (rhs.lastActivity ?? .distantPast)
            case .size:
                ascendingOrder = lhs.sizeBytes < rhs.sizeBytes
            case .files:
                ascendingOrder = lhs.fileCount < rhs.fileCount
            }
            return ascending ? ascendingOrder : !ascendingOrder
        }
        return result
    }
}
