//
//  CompositionDetailView.swift
//  Lupen
//
//  Created by jaden on 2026/07/05.
//

import AppKit
import SwiftUI

/// Detail-pane host for the SwiftUI `CompositionView` (C-25). Wraps it in an
/// `NSHostingView` so the conversation Detail view can show a per-turn or
/// per-session cost/token composition alongside its AppKit tabs. Rebuilt on
/// each selection via `configure(result:scopeLabel:)`.
final class CompositionDetailView: NSView {

    private let hosting: NSHostingView<AnyView>
    /// Persisted lens choice — survives selection changes (each new
    /// `CompositionView` starts at this mode; the callback keeps it current).
    private var mode: CompositionView.Mode = .cost

    override init(frame: NSRect) {
        hosting = NSHostingView(rootView: AnyView(EmptyView()))
        super.init(frame: frame)
        hosting.translatesAutoresizingMaskIntoConstraints = false
        addSubview(hosting)
        NSLayoutConstraint.activate([
            hosting.topAnchor.constraint(equalTo: topAnchor),
            hosting.leadingAnchor.constraint(equalTo: leadingAnchor),
            hosting.trailingAnchor.constraint(equalTo: trailingAnchor),
            hosting.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        configure(result: nil, scopeLabel: "this session")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// Swap in a composition breakdown, or an empty placeholder when the
    /// scope has no billable activity (or a nil result while a lazy load is
    /// still parked).
    func configure(
        result: ContextComposition.Result?,
        scopeLabel: String,
        topToolOutputs: [ToolOutputCost] = []
    ) {
        if let result, result.hasData {
            hosting.rootView = AnyView(CompositionView(
                result: result,
                scopeLabel: scopeLabel,
                topToolOutputs: topToolOutputs,
                initialMode: mode,
                onModeChange: { [weak self] in self?.mode = $0 }
            ))
        } else {
            hosting.rootView = AnyView(CompositionEmptyView())
        }
    }
}

private struct CompositionEmptyView: View {
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "chart.bar.xaxis")
                .font(.system(size: 26))
                .foregroundStyle(.secondary.opacity(0.6))
            Text("No composition data")
                .font(.system(size: 13, weight: .medium))
            Text("Select a turn or session with billable activity.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .multilineTextAlignment(.center)
        .padding()
    }
}
