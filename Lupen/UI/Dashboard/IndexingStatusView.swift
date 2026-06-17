//
//  IndexingStatusView.swift
//  Lupen
//
//  Created by jaden on 2026/06/16.
//

import SwiftUI
import AppKit

/// Always-visible index-progress indicator.
///
/// `launchProgress` already tracks the scan/import phases, but the only place
/// it surfaced was the empty-state overlay in the Turn outline — hidden the
/// moment a session is selected. A full rebuild (schema bump → wipe-and-
/// reindex) then ran invisibly: the sidebar kept showing browsable sessions
/// while the totals were silently partial, and Verify Costs flagged the gap
/// as hard mismatches. This view puts the state where it stays visible.
///
/// Two presentations off the same `AppStateStore.isIndexing` state:
///  - `.footer` pinned to the bottom of the sidebar (selection-independent).
///  - `.banner` a "preliminary results" strip atop Verify Costs.
///
/// Renders nothing (zero intrinsic height) when no scan/import is in flight,
/// so the host layout collapses it away automatically.
struct IndexingStatusView: View {

    enum Style { case footer, banner }

    let store: AppStateStore
    let style: Style

    var body: some View {
        if store.isIndexing {
            switch style {
            case .footer: footer
            case .banner: banner
            }
        }
    }

    // MARK: - Shared text

    private var headline: String {
        if store.launchProgress.phase == .scanningFiles {
            return "Scanning session files…"
        }
        return (store.didRebuildThisLaunch && !store.hasCompletedInitialIndex)
            ? "Rebuilding index"
            : "Indexing sessions"
    }

    /// "processed/pending" once we have a denominator; nil during the
    /// indeterminate scan phase.
    private var countText: String? {
        let p = store.launchProgress
        guard p.phase == .indexing, p.pendingUnits > 0 else { return nil }
        return "\(p.processedUnits)/\(p.pendingUnits)"
    }

    // MARK: - Footer (sidebar)

    private var footer: some View {
        let p = store.launchProgress
        return VStack(spacing: 5) {
            Divider()
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(0.7)
                    .frame(width: 12, height: 12)
                Text(headline)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 4)
                if let countText {
                    Text(countText)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
            .padding(.horizontal, 12)
            if p.phase == .indexing, p.pendingUnits > 0 {
                ProgressView(value: p.fraction)
                    .progressViewStyle(.linear)
                    .controlSize(.small)
                    .padding(.horizontal, 12)
            }
        }
        .padding(.bottom, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Banner (Verify Costs)

    private var banner: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .font(.system(size: 12))
            Text(bannerText)
                .font(.system(size: 12))
                .foregroundStyle(.primary)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.12))
    }

    private var bannerText: String {
        if let countText {
            return "Index still building (\(countText)) — results are preliminary"
        }
        return "Index still building — results are preliminary"
    }
}

/// AppKit drop-in for the SwiftUI status view. Intrinsic-content sizing lets
/// the host pin it and have it collapse to zero height when idle.
@MainActor
final class IndexingStatusHostingView: NSHostingView<IndexingStatusView> {
    init(store: AppStateStore, style: IndexingStatusView.Style) {
        super.init(rootView: IndexingStatusView(store: store, style: style))
        sizingOptions = [.intrinsicContentSize]
        translatesAutoresizingMaskIntoConstraints = false
    }

    @MainActor required init(rootView: IndexingStatusView) {
        super.init(rootView: rootView)
        sizingOptions = [.intrinsicContentSize]
        translatesAutoresizingMaskIntoConstraints = false
    }

    required init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) unused — IndexingStatusHostingView is code-only")
    }
}
