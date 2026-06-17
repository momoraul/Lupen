import AppKit
import SwiftUI

/// Sidebar filter popover — anchored to the filter button to the right
/// of the search field in `SessionListViewController`.
///
/// ## Why SwiftUI `Form` instead of hand-rolled AppKit
///
/// The first iteration of this screen was a stack of `NSStackView`s
/// with custom section labels. It never quite looked native — labels
/// misaligned, spacing inconsistent, and the overall metric drifted
/// every time macOS updated its form chrome. The correct 2026 pattern
/// (per WWDC22 *Use SwiftUI with AppKit* and the macOS 26 System
/// Settings source) is to embed a SwiftUI `Form.formStyle(.grouped)`
/// inside an `NSHostingController` and let the system draw the
/// section cards, label column, and spacing for us. That's what Mail's
/// rules editor, System Settings, and Reminders' smart-list editor all
/// do on Tahoe — the same grouped-form chrome, the same "Liquid Glass"
/// section backgrounds.
///
/// This VC is now a thin AppKit wrapper: `SessionListViewController`
/// still instantiates a plain `NSViewController` subclass and hands it
/// to `NSPopover.contentViewController`, so none of the popover setup
/// in the sidebar code changes. All the layout lives in
/// `FilterPopoverForm` below.
///
/// ## What the popover contains
///
/// - **Project** section: `Picker` with "All Projects" as the clear
///   row plus one row per distinct project key, label + session
///   count.
/// - **Date Range** section: segmented `Picker` with 5 presets
///   (All / Today / 24h / Week / 30d). Custom ranges are a deliberate
///   cut from Iter 2 — presets cover the "yesterday", "this week",
///   "this month" cases that actually come up.
/// - **Models** section: one `Toggle` per distinct model id, labelled
///   with session count. Only present when there are models to show.
///
/// A **Clear All** link button in the popover's bottom safe-area
/// inset resets project, dateRange, and models back to their defaults
/// (the search field's `query` is intentionally preserved — that
/// text belongs to the search field, not the popover).
///
/// Changes are committed **live** through `onFilterChanged` on every
/// control toggle. No "Apply" button — matches the instant-narrow
/// feel of Mail's filter popover and Finder's tag filter.
@MainActor
final class FilterPopoverViewController: NSViewController {

    // MARK: - Inputs

    /// Hand-off closure the VC fires every time a SwiftUI binding
    /// commits. Callers are expected to drop the emitted filter into
    /// their `currentFilter` and trigger a reload.
    var onFilterChanged: ((SessionFilter) -> Void)?

    private let initialFilter: SessionFilter
    private let projectOptions: [FilterOptionsBuilder.ProjectOption]
    private let modelOptions: [FilterOptionsBuilder.ModelOption]
    private var hosting: NSHostingController<FilterPopoverForm>!

    // MARK: - Init

    init(
        initialFilter: SessionFilter,
        projectOptions: [FilterOptionsBuilder.ProjectOption],
        modelOptions: [FilterOptionsBuilder.ModelOption]
    ) {
        self.initialFilter = initialFilter
        self.projectOptions = projectOptions
        self.modelOptions = modelOptions
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    // MARK: - View lifecycle

    override func loadView() {
        // Capture `onFilterChanged` through a weak-self bridge so the
        // SwiftUI view's closure doesn't outlive the VC. The
        // `NSHostingController` holds the closure via its rootView's
        // state, so a strong-self capture would form a retain cycle
        // with the popover's contentViewController.
        let root = FilterPopoverForm(
            initialFilter: initialFilter,
            projectOptions: projectOptions,
            modelOptions: modelOptions,
            onChange: { [weak self] newFilter in
                self?.onFilterChanged?(newFilter)
            }
        )
        hosting = NSHostingController(rootView: root)
        // Auto-size the popover to the SwiftUI content's fitting
        // size. `.preferredContentSize` propagates the SwiftUI
        // intrinsic size up through `preferredContentSize`, which
        // NSPopover then uses to size itself. No manual
        // `preferredContentSize = NSSize(width: ..., height: ...)`
        // needed — which also means the popover doesn't fight the
        // grouped-form's own internal spacing.
        hosting.sizingOptions = [.preferredContentSize]
        addChild(hosting)
        view = hosting.view
    }
}

// MARK: - SwiftUI content

/// Grouped-form content that renders inside the popover's
/// `NSHostingController`. Kept as a `private`-ish `fileprivate` struct
/// so the AppKit wrapper is still the only public surface — callers
/// don't need to know this popover is SwiftUI under the hood.
///
/// Binding semantics: every control writes into the `working` state
/// and then immediately fires `onChange(working)`. That keeps the UI
/// responsive (state mutation drives the visible toggle) while still
/// pushing the update to `SessionListViewController` live. No debounce
/// is needed because the filter layer itself is cheap (see
/// `AppStateStore.filteredSessions`).
fileprivate struct FilterPopoverForm: View {

    let projectOptions: [FilterOptionsBuilder.ProjectOption]
    let modelOptions: [FilterOptionsBuilder.ModelOption]
    let onChange: (SessionFilter) -> Void

    /// Working copy of the filter. Seeded from the `initialFilter`
    /// constructor argument so the popover "remembers" what was set
    /// the last time it opened, and then mutated in-place by each
    /// control. The constructor argument itself isn't stored on the
    /// struct — `@State` only honors the initial value on first
    /// creation, so there's no reason to keep it around.
    @State private var working: SessionFilter
    /// Local mirror of `working.dateRange` as a preset enum so the
    /// segmented `Picker` has a first-class `CaseIterable` binding.
    /// Derived from `initialFilter.dateRange` on construction and
    /// re-synced on every user toggle.
    @State private var datePreset: DatePreset
    /// From/To pickers for the `.custom` preset. Seeded from an existing
    /// custom range, else a sensible default (the last 7 days).
    @State private var customFrom: Date
    @State private var customTo: Date

    init(
        initialFilter: SessionFilter,
        projectOptions: [FilterOptionsBuilder.ProjectOption],
        modelOptions: [FilterOptionsBuilder.ModelOption],
        onChange: @escaping (SessionFilter) -> Void
    ) {
        self.projectOptions = projectOptions
        self.modelOptions = modelOptions
        self.onChange = onChange
        _working = State(initialValue: initialFilter)
        _datePreset = State(initialValue: DatePreset(from: initialFilter.dateRange))
        if case .custom(let from, let to) = initialFilter.dateRange {
            _customFrom = State(initialValue: from)
            _customTo = State(initialValue: to)
        } else {
            let now = Date()
            _customFrom = State(initialValue:
                Calendar.current.date(byAdding: .day, value: -7, to: now) ?? now)
            _customTo = State(initialValue: now)
        }
    }

    /// Preset date ranges surfaced as a proper `CaseIterable` for the
    /// segmented picker. `.all` maps to `SessionFilter.DateRange == nil`
    /// so the Picker's "All" segment is the clear row. Custom ranges
    /// (`.custom(from:to:)`) are not addressable from the popover —
    /// if the upstream filter happens to hold one we collapse it to
    /// `.all` for the picker's sake and leave the filter itself alone
    /// unless the user actively changes the segment.
    enum DatePreset: String, CaseIterable, Identifiable {
        case all, today, last24h, week, last30d, custom

        var id: Self { self }

        var label: String {
            switch self {
            case .all:      return "All"
            case .today:    return "Today"
            case .last24h:  return "24h"
            case .week:     return "Week"
            case .last30d:  return "30d"
            case .custom:   return "Custom"
            }
        }

        init(from range: SessionFilter.DateRange?) {
            switch range {
            case .none:       self = .all
            case .today:      self = .today
            case .yesterday:  self = .all   // popover doesn't surface "yesterday"
            case .last24h:    self = .last24h
            case .thisWeek:   self = .week
            case .last30days: self = .last30d
            case .custom:     self = .custom
            }
        }

        /// Non-custom presets resolve to a fixed window; `.custom` returns
        /// nil here because its bounds come from the user's From/To pickers
        /// (handled in `applyCustomRange`), not a preset rule.
        var asDateRange: SessionFilter.DateRange? {
            switch self {
            case .all:      return nil
            case .today:    return .today
            case .last24h:  return .last24h
            case .week:     return .thisWeek
            case .last30d:  return .last30days
            case .custom:   return nil
            }
        }
    }

    var body: some View {
        Form {
            Section("Search in") {
                Picker("Search in", selection: $working.searchScope) {
                    Text("Sessions").tag(SessionFilter.SearchScope.sessions)
                    Text("Everything").tag(SessionFilter.SearchScope.everything)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .onChange(of: working.searchScope) { _, _ in
                    onChange(working)
                }
            }

            Section("Project") {
                Picker("Project", selection: projectBinding) {
                    Text("All Projects").tag(String?.none)
                    ForEach(projectOptions, id: \.key) { option in
                        Text("\(option.label) (\(option.count))")
                            .tag(String?.some(option.key))
                    }
                }
                .labelsHidden()
            }

            Section("Date Range") {
                Picker("Date Range", selection: $datePreset) {
                    ForEach(DatePreset.allCases) { preset in
                        Text(preset.label).tag(preset)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .onChange(of: datePreset) { _, new in applyDatePreset(new) }

                if datePreset == .custom {
                    DatePicker("From", selection: $customFrom, displayedComponents: .date)
                        .onChange(of: customFrom) { _, _ in applyCustomRange() }
                    DatePicker("To", selection: $customTo, displayedComponents: .date)
                        .onChange(of: customTo) { _, _ in applyCustomRange() }
                }
            }

            if !modelOptions.isEmpty {
                Section("Models") {
                    ForEach(modelOptions, id: \.id) { option in
                        Toggle(isOn: modelBinding(for: option.id)) {
                            Text("\(option.id) (\(option.count))")
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        // Intrinsic width constraint — `Form.grouped` doesn't auto-size
        // horizontally inside a popover's `sizingOptions`, so we pin a
        // sensible band. 320 is wide enough that long project labels
        // like "compound-engineering-workflows" don't truncate; the
        // min is 280 so tight installs still look contained.
        .frame(minWidth: 280, idealWidth: 320)
        .safeAreaInset(edge: .bottom) {
            HStack {
                Spacer()
                Button("Clear All") {
                    working.projectFilter = nil
                    working.dateRange = nil
                    working.models.removeAll()
                    working.searchScope = .everything
                    // Mirror the reset into the local preset state so
                    // the segmented control's visible selection
                    // snaps back to "All" alongside the filter's own
                    // reset — without this the segmented picker
                    // would lag until the next render cycle.
                    datePreset = .all
                    onChange(working)
                }
                .buttonStyle(.link)
                .disabled(!working.hasStructuredFilters)
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 10)
        }
    }

    // MARK: - Bindings

    /// Bridge between the SwiftUI `Picker(selection:)` contract
    /// (`String?`) and our `working.projectFilter` field. Writes
    /// immediately propagate through `onChange` so the sidebar
    /// rebuilds on the same run-loop tick the user clicked.
    private var projectBinding: Binding<String?> {
        Binding(
            get: { working.projectFilter },
            set: { newValue in
                working.projectFilter = newValue
                onChange(working)
            }
        )
    }

    /// Checkbox binding for one model id. Getter returns whether this
    /// id is currently in `working.models`, setter inserts or removes
    /// as needed. Inline `Set` mutation avoids reconstructing the set
    /// on every toggle.
    private func modelBinding(for id: String) -> Binding<Bool> {
        Binding(
            get: { working.models.contains(id) },
            set: { isOn in
                if isOn {
                    working.models.insert(id)
                } else {
                    working.models.remove(id)
                }
                onChange(working)
            }
        )
    }

    // MARK: - Date preset application

    /// Segmented-control handler. Non-custom presets resolve to a fixed
    /// window; `.custom` defers to the From/To pickers.
    private func applyDatePreset(_ preset: DatePreset) {
        if preset == .custom {
            applyCustomRange()
        } else {
            working.dateRange = preset.asDateRange
            onChange(working)
        }
    }

    /// Commit the current From/To pickers as a `.custom` range (inclusive
    /// day span, reversed picks tolerated — see `customSpanning`).
    private func applyCustomRange() {
        working.dateRange = SessionFilter.DateRange.customSpanning(customFrom, customTo)
        onChange(working)
    }
}
