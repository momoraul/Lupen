//
//  TurnFileAccessView.swift
//  Lupen
//
//  Created by jaden on 2026/07/26.
//

import AppKit

/// C-22 — the file-access card body: an aggregate op-sequence strip over
/// per-file rows, all sharing one op-order axis.
///
/// Rows are in first-touch order, so the marks descend like a staircase and
/// the shape of the work is visible without reading a word: a long run on one
/// row is time spent on one file, a hollow mark after a filled one is a
/// re-read after a change, a struck mark is a failure. None of it is labelled
/// — see `TurnFileAccess` for why judging it would be wrong.
///
/// **The strip sits in the same column grid as the rows.** Sharing one axis is
/// the whole premise, and it only holds if a given ordinal lands at the same x
/// everywhere, so the strip is laid out as a row whose name column carries the
/// axis caption rather than as a full-width band above them.
///
/// Text lives in real `NSTextField`s and only the marks are drawn, so
/// filenames stay selectable, copyable, and reachable by VoiceOver.
@MainActor
final class TurnFileAccessView: NSView {

    // MARK: - Metrics

    /// Columns are sized to what the card actually has to show, then packed
    /// against the leading edge.
    ///
    /// The card is not 500pt wide in practice — the conversation stack takes
    /// the whole detail pane, which can be 1,900pt. Neither of the obvious
    /// ways to spend that width works: letting the name column absorb it puts
    /// an empty band between a short filename and its marks, and letting the
    /// track absorb it moves the same band to between the last mark and the
    /// counts, because 90% of turns run 18 operations or fewer and 18
    /// operations need 252pt. Either way the row has a hole in the middle.
    ///
    /// So each column asks for what it needs — the name for its widest text,
    /// the track for one slot per operation — and the surplus is left as a
    /// trailing margin. A row that ends early reads as a compact table; a row
    /// with a gap in it reads as broken.
    struct ColumnMetrics: Equatable {
        /// Widest name text in the card. Shared, not per row: the axis only
        /// lines up if every track starts at the same x.
        var nameContentWidth: CGFloat
        /// Operations on the axis. The track needs no more than this many
        /// slots, and at `FileAccessTrackView.maxSlotWidth` each one draws at
        /// full size.
        var opCount: Int
    }

    static let minTrackWidth: CGFloat = 90
    static let badgeWidth: CGFloat = 15
    static let countsWidth: CGFloat = 74
    /// A small floor so a card of one-word names still reads as a column.
    /// It stays low on purpose: the column is content-sized now, so anything
    /// above what the text needs is whitespace between the name and its marks.
    static let minNameWidth: CGFloat = 80
    /// Ceiling for one pathological path, not a target. Content sizing means a
    /// card of short names never pays for this, so it is set where a full
    /// `…/dir/dir/name.ext` fits rather than where the old absorb-the-slack
    /// column stopped being useful.
    static let maxNameWidth: CGFloat = 420
    static let rowHeight: CGFloat = 21
    static let columnGap: CGFloat = 8

    /// Column widths for a given row width. Pure so the arithmetic is testable
    /// without a window.
    static func columnWidths(
        forRowWidth width: CGFloat, metrics: ColumnMetrics
    ) -> (name: CGFloat, track: CGFloat) {
        let fixed = badgeWidth + countsWidth + columnGap * 3
        let flexible = max(0, width - fixed)
        let wantedName = min(maxNameWidth, max(minNameWidth, metrics.nameContentWidth.rounded(.up)))
        let wantedTrack = max(
            minTrackWidth,
            CGFloat(max(1, metrics.opCount)) * FileAccessTrackView.maxSlotWidth
        )
        guard wantedName + wantedTrack > flexible else { return (wantedName, wantedTrack) }

        // Too narrow for both. The name yields first — a truncated path is
        // still readable, whereas a track under its floor stops being a lane
        // the pointer can follow — and the track then takes what is left.
        let name = max(0, min(wantedName, flexible - min(wantedTrack, minTrackWidth)))
        return (name, max(0, min(wantedTrack, flexible - name)))
    }

    private let model: TurnFileAccess.Model
    private let readoutField = NSTextField(labelWithString: "")
    private let rowsStack = NSStackView()
    private var strip: FileAccessTrackView?
    private var stepByOrdinal: [Int: String] = [:]
    private var readoutByOrdinal: [Int: String] = [:]
    /// Counts label per path, so the line deltas can replace the placeholder
    /// once the raw read lands.
    private var countsFieldByPath: [String: NSTextField] = [:]
    private var rowViewByPath: [String: NSView] = [:]
    private var accessibilityBaseByPath: [String: String] = [:]
    private var diffTask: Task<Void, Never>?
    /// The "N more files" row, replaced in place when the user opens it.
    private var foldedRow: NSView?
    /// Kept so rows created *after* the read lands still get their numbers —
    /// `apply` runs once, but expanding the folded tail adds counts fields
    /// afterwards, and without this whether they filled in came down to
    /// whether the user clicked before or after the disk read finished.
    private var loadedDeltas: TurnFileDiffStats?
    private var foldedRowsExpanded = false
    private var expandedRowViews: [NSView] = []
    /// The placeholder's own label and badge, so both can follow the state.
    private var foldedNameField: NSTextField?
    private var foldedBadgeView: NSImageView?
    /// Restored when the pointer leaves, so the line is never blank — a blank
    /// line gives no hint that the marks respond to hovering at all.
    private var idleReadout: String
    /// The idle text without any appended notice, so the notice can be
    /// recomputed instead of accumulated.
    private let baseIdleReadout: String
    /// Whether the readout is currently describing a hovered mark.
    private var isShowingMarkReadout = false
    /// Shared column sizing, recomputed whenever the set of rows changes.
    private var columnMetrics = ColumnMetrics(nameContentWidth: 0, opCount: 1)
    /// How many times the card has re-measured its rows. Each pass forces an
    /// `intrinsicContentSize` on every name field, so the count is the contract
    /// a test pins — three helpers used to run it once each per fold toggle.
    private var columnMetricsPasses = 0

    var onJumpToStep: ((String) -> Void)?
    var onRevealInFinder: ((URL) -> Void)?
    /// Open a file in its default application — the row's primary menu action.
    var onOpenFile: ((URL) -> Void)?
    /// Reports the folded tail being opened or closed, so the choice survives
    /// the card being rebuilt on the next step selection.
    var onFoldedRowsExpandedChange: ((Bool) -> Void)?

    init(model: TurnFileAccess.Model) {
        self.model = model
        let hint = Self.idleHint(model)
        self.baseIdleReadout = hint
        self.idleReadout = hint
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        indexModel()
        setup()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func indexModel() {
        // Readouts for *every* row, folded or not: hovering a mark on the
        // aggregate strip should name the file whether or not its row is on
        // screen, and a folded file's mark otherwise announced itself as a
        // search. Only jump targets are gated — a click needs a row to land on.
        for row in model.rows + model.foldedRows {
            for op in row.ops {
                readoutByOrdinal[op.ordinal] = Self.readout(for: op, path: row.path)
            }
        }
        index(rows: model.rows)
    }

    private func index(rows: [TurnFileAccess.FileRow]) {
        for row in rows {
            for op in row.ops { stepByOrdinal[op.ordinal] = op.stepUuid }
        }
    }

    // MARK: - Build

    private func setup() {
        readoutField.stringValue = idleReadout
        readoutField.font = .monospacedSystemFont(ofSize: 10.5, weight: .regular)
        readoutField.textColor = .secondaryLabelColor
        readoutField.lineBreakMode = .byTruncatingMiddle
        readoutField.maximumNumberOfLines = 1
        readoutField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        rowsStack.orientation = .vertical
        rowsStack.alignment = .leading
        rowsStack.spacing = 0
        rowsStack.translatesAutoresizingMaskIntoConstraints = false

        var rows: [NSView] = [makeStripRow()]
        rows.append(contentsOf: model.rows.map(makeRow))
        rows.append(contentsOf: makeSupplementaryRows())
        for row in rows {
            rowsStack.addArrangedSubview(row)
            // Vertical stacks with `.leading` alignment do not stretch their
            // children, so without this each row would settle at its own
            // intrinsic width and every row's track would start at a
            // different x — the staircase would not line up at all.
            row.widthAnchor.constraint(equalTo: rowsStack.widthAnchor).isActive = true
        }
        refreshColumnMetrics()

        let outer = NSStackView(views: [rowsStack, readoutField])
        outer.orientation = .vertical
        outer.alignment = .leading
        outer.spacing = 6
        outer.translatesAutoresizingMaskIntoConstraints = false
        addSubview(outer)
        NSLayoutConstraint.activate([
            outer.leadingAnchor.constraint(equalTo: leadingAnchor),
            outer.trailingAnchor.constraint(equalTo: trailingAnchor),
            outer.topAnchor.constraint(equalTo: topAnchor),
            outer.bottomAnchor.constraint(equalTo: bottomAnchor),
            rowsStack.widthAnchor.constraint(equalTo: outer.widthAnchor),
            readoutField.widthAnchor.constraint(equalTo: outer.widthAnchor),
        ])

        // `setAccessibilityElement(true)` is load-bearing, not decoration: a
        // role and a label alone leave the view ignored, so the label was
        // exposed nowhere and `pinAccessibilityOrder` was posting its
        // layout-changed notification to an element assistive technology
        // cannot observe. Every other `.group` in this file, and the sibling
        // timeline view, set it too.
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("File access")
    }

    /// The aggregate strip, laid out as a row so its marks share the file
    /// rows' x positions. The name column names the axis — parked right next
    /// to the marks it describes, which also keeps the sibling timeline card's
    /// wall-clock reading from being applied here by mistake.
    private func makeStripRow() -> NSView {
        let marks = model.sequence.map {
            FileAccessTrackView.Mark(
                ordinal: $0.ordinal, operation: $0.operation, isError: $0.isError
            )
        }
        let track = FileAccessTrackView(marks: marks, totalOrdinals: model.sequence.count)
        track.onSelect = { [weak self] ordinal in self?.jump(to: ordinal) }
        track.onHover = { [weak self] mark in self?.showReadout(for: mark) }
        // The strip carries every mark in the turn, including searches and the
        // ops of files folded past the row cap — `stepByOrdinal` only indexes
        // the rows that are shown, so the rest must not offer a click.
        track.selectableOrdinals = Set(stepByOrdinal.keys)
        strip = track

        let name = Self.label("op order →", size: 11, color: .tertiaryLabelColor)
        let counts = Self.monospacedLabel("\(model.sequence.count) ops", color: .tertiaryLabelColor)
        let row = Self.assemble(
            row: FileAccessRowView(path: nil),
            badge: Self.badgeView(symbol: nil, description: nil),
            name: name,
            track: track,
            counts: counts
        )
        row.setAccessibilityElement(true)
        row.setAccessibilityRole(.group)
        row.setAccessibilityLabel("Operation sequence")
        row.setAccessibilityValue(Self.sequenceDescription(model))
        row.setAccessibilityChildren([])
        return row
    }

    private func makeRow(_ row: TurnFileAccess.FileRow) -> NSView {
        let badgeSpec = Self.badge(for: row)
        let badge = Self.badgeView(symbol: badgeSpec.symbol, description: badgeSpec.label)

        let name = Self.label(Self.displayPath(row.path), size: 11.5, color: .labelColor)
        name.lineBreakMode = .byTruncatingMiddle
        // On the label, not the row. A tooltip is registered as a tracking area
        // on its own view and is resolved by geometry, so it survives the row
        // claiming `hitTest` — and a row-wide area would also cover the track,
        // popping a tooltip over the marks for anyone holding still to read the
        // hover readout.
        name.toolTip = row.path
        // Deliberately *not* selectable. A selectable `NSTextField` swallows
        // `mouseDown` and enters its own tracking loop, so the filename — the
        // most obvious thing to click — was the one place in the row that did
        // not jump. Copying the path stays available on the context menu.
        name.isSelectable = false

        let marks = row.ops.map {
            FileAccessTrackView.Mark(
                ordinal: $0.ordinal, operation: $0.operation, isError: $0.isError
            )
        }
        let track = FileAccessTrackView(marks: marks, totalOrdinals: model.sequence.count)
        track.onSelect = { [weak self] ordinal in self?.jump(to: ordinal) }
        track.onHover = { [weak self] mark in self?.showReadout(for: mark) }

        let counts = Self.monospacedLabel(Self.counts(for: row), color: .secondaryLabelColor)
        countsFieldByPath[row.path] = counts

        let rowView = FileAccessRowView(path: row.path)
        rowView.onReveal = { [weak self] url in self?.onRevealInFinder?(url) }
        rowView.onOpen = { [weak self] url in self?.onOpenFile?(url) }
        // Clicking a 3pt mark is not how anyone reaches for a file. The row
        // jumps to that file's first operation, which is what the marks on it
        // already do individually.
        if let first = row.ops.first {
            rowView.onActivate = { [weak self] in self?.jump(to: first.ordinal) }
        }

        let assembled = Self.assemble(
            row: rowView, badge: badge, name: name, track: track, counts: counts
        )
        assembled.setAccessibilityElement(true)
        // `.group`, not `.row`: there is no enclosing table or outline role,
        // so a row role would be an orphan that table navigation cannot reach.
        assembled.setAccessibilityRole(.group)
        assembled.setAccessibilityLabel(row.path)
        let baseValue = Self.accessibilityValue(for: row)
        assembled.setAccessibilityValue(baseValue)
        rowViewByPath[row.path] = assembled
        accessibilityBaseByPath[row.path] = baseValue
        // The badge, name and counts are already summarised in the value; left
        // exposed they would be read again, three times over.
        assembled.setAccessibilityChildren([])
        return assembled
    }

    /// The lanes that are not files: search, the folded tail, and the shell
    /// group. Each is plainly labelled so nothing inferred is mistaken for a
    /// ranked file.
    private func makeSupplementaryRows() -> [NSView] {
        // Order matters: the folded tail goes first so the file rows it
        // opens into stay adjacent to the other file rows. Dropping them
        // below the search lane would break the first-touch staircase the
        // card is built around.
        var views: [NSView] = []

        if model.foldedFileCount > 0 {
            let row = Self.labelledRow(
                symbol: "chevron.right",
                description: "More files",
                text: "\(model.foldedFileCount) more files — click to show",
                track: nil,
                counts: "\(model.foldedOpCount) ops",
                accessibilityValue: "\(model.foldedFileCount) more files, "
                    + "\(model.foldedOpCount) operations. Click to show them."
            )
            row.onActivate = { [weak self] in
                guard let self else { return }
                self.setFoldedRowsExpanded(!self.foldedRowsExpanded)
            }
            foldedRow = row
            foldedNameField = row.subviews.compactMap { $0 as? NSTextField }.first
            foldedBadgeView = row.subviews.compactMap { $0 as? NSImageView }.first
            views.append(row)
        }

        if model.searchOpCount > 0 {
            let marks = model.sequence
                .filter { $0.operation == nil }
                .map {
                    FileAccessTrackView.Mark(
                        ordinal: $0.ordinal, operation: nil, isError: $0.isError
                    )
                }
            let track = FileAccessTrackView(marks: marks, totalOrdinals: model.sequence.count)
            track.onHover = { [weak self] mark in self?.showReadout(for: mark) }
            views.append(Self.labelledRow(
                symbol: "magnifyingglass",
                description: "Searches",
                text: "Search (no path)",
                track: track,
                counts: "\(model.searchOpCount)",
                accessibilityValue: "\(model.searchOpCount) searches, no file path recorded"
            ))
        }

        if model.heuristicOpCount > 0 {
            // Measured 14.9% accurate, so these never sit in the ranked rows
            // and never claim an axis position.
            let text = model.heuristicPaths.isEmpty
                ? "\(model.heuristicOpCount) shell commands"
                : "\(model.heuristicPaths.count) paths from shell (approximate)"
            views.append(Self.labelledRow(
                symbol: "terminal",
                description: "Shell",
                text: text,
                track: nil,
                counts: "",
                accessibilityValue: text
            ))
        }

        return views
    }

    // MARK: - Line deltas

    /// Starts the raw read that fills in `+N −M`.
    ///
    /// The counts column keeps its width from the first layout pass, so the
    /// numbers appear in place without reflowing the card — a jump here would
    /// move the scroll position under the user.
    func loadLineDeltas(
        key: String, using load: @escaping @Sendable () -> TurnFileDiffStats
    ) {
        // Nothing to find: line deltas only exist where a file was written or
        // edited, and 70% of turns that read a file changed nothing. Folded
        // rows count — they can be opened, so a turn whose only change is past
        // the row cap still has numbers worth reading.
        let anyChange = (model.rows + model.foldedRows).contains { $0.deepest != .read }
        guard anyChange else { return }

        lastDeltaKeyForTesting = key
        diffTask?.cancel()
        diffTask = Task { [weak self] in
            let stats = await TurnFileDiffCache.shared.stats(for: key, load: load)
            guard !Task.isCancelled else { return }
            self?.apply(stats)
        }
    }

    private func apply(_ stats: TurnFileDiffStats) {
        loadedDeltas = stats
        for (path, field) in countsFieldByPath {
            guard let delta = stats.byPath[path], delta.added > 0 || delta.removed > 0 else {
                // `+0` would replace the informative tallies with nothing —
                // an empty file deleted, for instance.
                continue
            }
            field.stringValue = Self.deltaText(delta)
            // The row hides its children so VoiceOver reads the row value, not
            // the label — so the value has to be refreshed too, or the numbers
            // stay visual-only.
            if let row = rowViewByPath[path], let base = accessibilityBaseByPath[path] {
                row.setAccessibilityValue("\(base), \(Self.deltaSpokenText(delta))")
            }
        }
        // Folded into the idle text, not written straight to the field:
        // `showReadout(for: nil)` restores the idle text when the pointer
        // leaves, so a notice written directly would vanish on the first hover
        // and never come back.
        //
        // Recomputed from the base rather than appended — `apply` runs again
        // when the folded tail opens, and appending grew the notice by one copy
        // each time.
        idleReadout = stats.missingLineCount > 0
            ? "\(baseIdleReadout) · \(stats.missingLineCount) steps unreadable"
            : baseIdleReadout
        // Only refresh the line when it is showing the idle text; overwriting
        // it would wipe the readout the pointer is currently on.
        if !isShowingMarkReadout { readoutField.stringValue = idleReadout }
    }

    /// `+31 −5` replaces the read/change tallies once known: the tallies are
    /// already legible as marks, while the line counts are the only thing on
    /// the row that says what the turn actually did to the file.
    static func deltaText(_ delta: TurnFileDiffStats.Delta) -> String {
        if delta.isNewFile && delta.removed == 0 { return "new +\(delta.added)" }
        if delta.removed == 0 { return "+\(delta.added)" }
        if delta.added == 0 { return "−\(delta.removed)" }
        return "+\(delta.added) −\(delta.removed)"
    }

    /// Spoken form — `+31 −5` reads as punctuation to a screen reader.
    static func deltaSpokenText(_ delta: TurnFileDiffStats.Delta) -> String {
        var parts: [String] = []
        if delta.isNewFile { parts.append("new file") }
        if delta.added > 0 { parts.append("\(delta.added) added") }
        if delta.removed > 0 { parts.append("\(delta.removed) removed") }
        return parts.joined(separator: ", ")
    }

    /// A hidden or discarded card must not keep a file read alive; the card is
    /// rebuilt on every turn selection and every highlight change.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { diffTask?.cancel() }
    }

    // MARK: - Interaction

    /// Opens or closes the folded tail.
    ///
    /// The card grows and the conversation's own scroll view absorbs it — no
    /// nested scrolling, which is why the cap folds rather than scrolls. The
    /// placeholder row stays put so the action is reversible; only the extra
    /// file rows come and go.
    func setFoldedRowsExpanded(_ expanded: Bool, notify: Bool = true) {
        guard expanded != foldedRowsExpanded, !model.foldedRows.isEmpty else { return }
        foldedRowsExpanded = expanded
        if expanded { insertFoldedRows() } else { removeFoldedRows() }
        updateFoldedPlaceholder()
        // Once, here, rather than at the end of each of the three helpers
        // above: they run in sequence on every toggle, and each pass re-measures
        // every row's text for the same answer.
        refreshColumnMetrics()
        if notify { onFoldedRowsExpandedChange?(expanded) }
    }

    /// Re-pins the announced order and tells assistive technology the rows
    /// changed.
    ///
    /// `insertArrangedSubview` appends to `subviews` while placing correctly in
    /// `arrangedSubviews`, and accessibility follows `subviews` — so the new
    /// rows would be announced after the shell lane instead of where they are.
    ///
    /// The notification goes to `self`, not to `rowsStack`: a default
    /// `NSStackView` is an ignored element with an unknown role, so assistive
    /// technology cannot register an observer on it and a post there is
    /// unlikely to be delivered. `self` carries a role and a label.
    private func pinAccessibilityOrder(announcing added: [NSView]?) {
        rowsStack.setAccessibilityChildren(rowsStack.arrangedSubviews)
        var info: [NSAccessibility.NotificationUserInfoKey: Any] = [:]
        if let added, !added.isEmpty { info[.uiElements] = added }
        NSAccessibility.post(
            element: self, notification: .layoutChanged, userInfo: info.isEmpty ? nil : info
        )
    }

    /// Keeps the placeholder's wording honest about which way the click goes.
    private func updateFoldedPlaceholder() {
        foldedBadgeView?.image = NSImage(
            systemSymbolName: foldedRowsExpanded ? "chevron.down" : "chevron.right",
            accessibilityDescription: nil
        )
        foldedNameField?.stringValue = foldedRowsExpanded
            ? "\(model.foldedFileCount) more files — click to hide"
            : "\(model.foldedFileCount) more files — click to show"
        (foldedRow as? FileAccessRowView)?.setAccessibilityValue(
            foldedRowsExpanded
                ? "\(model.foldedFileCount) more files shown. Click to hide them."
                : "\(model.foldedFileCount) more files hidden. Click to show them."
        )
    }

    private func removeFoldedRows() {
        for view in expandedRowViews { rowsStack.removeView(view) }
        expandedRowViews = []
        for row in model.foldedRows {
            rowViewByPath[row.path] = nil
            countsFieldByPath[row.path] = nil
            accessibilityBaseByPath[row.path] = nil
            // Readouts stay: they are display text, and a strip mark should
            // still name its file. Only the jump target goes, because there is
            // no longer a row for the click to land on.
            for op in row.ops { stepByOrdinal[op.ordinal] = nil }
        }
        strip?.selectableOrdinals = Set(stepByOrdinal.keys)
        pinAccessibilityOrder(announcing: nil)
    }

    private func insertFoldedRows() {
        guard let placeholder = foldedRow,
              let insertionIndex = rowsStack.arrangedSubviews.firstIndex(of: placeholder)
        else { return }

        // These ops are left out of the index while their files are folded
        // away — a mark with no visible row has nowhere to send a click. Now
        // that they have rows, they become jump targets, and the strip's marks
        // for them stop being inert.
        index(rows: model.foldedRows)
        strip?.selectableOrdinals = Set(stepByOrdinal.keys)

        for (offset, row) in model.foldedRows.enumerated() {
            let view = makeRow(row)
            rowsStack.insertArrangedSubview(view, at: insertionIndex + 1 + offset)
            view.widthAnchor.constraint(equalTo: rowsStack.widthAnchor).isActive = true
            expandedRowViews.append(view)
        }

        // If the read already landed, these rows missed it.
        if let loadedDeltas { apply(loadedDeltas) }
        // `insertArrangedSubview` appends to `subviews` while placing correctly
        // in `arrangedSubviews`, and accessibility follows `subviews` — so
        // VoiceOver would read the new rows after the shell lane instead of
        // where they are. Pin the order to what is on screen.
        pinAccessibilityOrder(announcing: expandedRowViews)
    }

    /// Measures the widest name in the card and hands the result to every row.
    ///
    /// Measuring here rather than in the rows is what keeps the tracks aligned:
    /// a row sizing its own name column to its own text would start its track
    /// at a different x from its neighbour.
    ///
    /// Call after anything that adds, removes, or relabels a row: the tail can
    /// hold a longer path than anything already on screen, closing it can take
    /// the widest name away, and the placeholder's two wordings are different
    /// widths. `setFoldedRowsExpanded` does all three in sequence and calls
    /// this once at the end.
    private func refreshColumnMetrics() {
        columnMetricsPasses += 1
        let rows = rowsStack.arrangedSubviews.compactMap { $0 as? FileAccessRowView }
        let widest = rows.map(\.nameContentWidth).max() ?? 0
        columnMetrics = ColumnMetrics(nameContentWidth: widest, opCount: model.sequence.count)
        // Pushed to every row unconditionally, including when the shared value
        // did not move: a row inserted with the folded tail starts on the
        // default metrics, and skipping the push when its name happened to be
        // shorter than the widest already on screen left it laying out against
        // an axis of its own. The row's own setter is what drops the no-ops.
        for row in rows { row.metrics = columnMetrics }
    }

    private func jump(to ordinal: Int) {
        guard let uuid = stepByOrdinal[ordinal] else { return }
        onJumpToStep?(uuid)
    }

    private func showReadout(for segment: FileAccessTrackView.Segment?) {
        guard let segment else {
            isShowingMarkReadout = false
            readoutField.stringValue = idleReadout
            return
        }
        isShowingMarkReadout = true
        readoutField.stringValue = Self.readout(for: segment, singles: readoutByOrdinal)
    }

    // MARK: - Text

    private static func idleHint(_ model: TurnFileAccess.Model) -> String {
        model.sequence.isEmpty ? "" : "Hover a mark for detail · click to jump"
    }

    /// A merged run says how much it stands for; a lone mark keeps the
    /// per-operation wording. Without the count a dense turn would look like it
    /// had a handful of operations rather than a hundred.
    static func readout(
        for segment: FileAccessTrackView.Segment, singles: [Int: String]
    ) -> String {
        guard segment.markCount > 1 else {
            return singles[segment.firstOrdinal] ?? "op \(segment.firstOrdinal) · search"
        }
        let noun: String
        switch segment.kind {
        case .read:   noun = segment.isMixed ? "operations, mostly reads" : "reads"
        case .change: noun = segment.isMixed ? "operations, mostly changes" : "changes"
        case .search: noun = segment.isMixed ? "operations, mostly searches" : "searches"
        }
        // Count first, then the span: "op 32–58 · 18 searches" invited reading
        // the range as the count when a bucket holds only some of what it
        // spans.
        var text = "\(segment.markCount) \(noun) · op \(segment.firstOrdinal)"
        if segment.lastOrdinal != segment.firstOrdinal {
            text += "–\(segment.lastOrdinal)"
        }
        if segment.errorCount > 0 { text += " · \(segment.errorCount) failed" }
        return text
    }

    private static func readout(for op: TurnFileAccess.Op, path: String) -> String {
        let verb: String
        switch op.operation {
        case .read:  verb = "read"
        case .edit:  verb = "edit"
        case .write: verb = "write"
        }
        let name = (path as NSString).lastPathComponent
        let tool = op.toolName.isEmpty ? "" : " · \(op.toolName)"
        return "op \(op.ordinal) · \(verb) \(name)\(tool)\(op.isError ? " · failed" : "")"
    }

    /// The card's unique information is the *order*, and it is otherwise
    /// visual only — so the sequence is spelled out for VoiceOver rather than
    /// repeating the counts that the counts column already reads.
    static func sequenceDescription(_ model: TurnFileAccess.Model) -> String {
        guard !model.sequence.isEmpty else { return "no operations" }
        let parts = model.sequence.map { mark -> String in
            let verb: String
            switch mark.operation {
            case .read:  verb = "read"
            case .edit:  verb = "edit"
            case .write: verb = "write"
            case .none:  verb = "search"
            }
            return "op \(mark.ordinal) \(verb)\(mark.isError ? " failed" : "")"
        }
        return parts.joined(separator: ", ")
    }

    private struct BadgeSpec {
        let symbol: String
        let label: String
    }

    private static func badge(for row: TurnFileAccess.FileRow) -> BadgeSpec {
        if row.errorCount > 0 && !row.hasSucceededChange {
            return BadgeSpec(symbol: "xmark", label: "Failed")
        }
        switch row.deepest {
        case .read:  return BadgeSpec(symbol: "doc", label: "Read")
        case .edit:  return BadgeSpec(symbol: "pencil", label: "Edited")
        case .write: return BadgeSpec(symbol: "plus", label: "Written")
        }
    }

    private static func counts(for row: TurnFileAccess.FileRow) -> String {
        var parts: [String] = []
        let reads = row.ops.filter { $0.operation == .read }.count
        let changes = row.ops.filter { $0.operation != .read }.count
        if reads > 0 { parts.append("R\(reads)") }
        if changes > 0 { parts.append("E\(changes)") }
        if row.errorCount > 0 { parts.append("!\(row.errorCount)") }
        return parts.joined(separator: " ")
    }

    private static func accessibilityValue(for row: TurnFileAccess.FileRow) -> String {
        let reads = row.ops.filter { $0.operation == .read }.count
        let changes = row.ops.filter { $0.operation != .read }.count
        var parts: [String] = []
        if reads > 0 { parts.append("read \(reads) times") }
        if changes > 0 { parts.append("changed \(changes) times") }
        if row.errorCount > 0 { parts.append("\(row.errorCount) failed") }
        if row.hasReadAfterChange { parts.append("read again after a change") }
        let ordinals = row.ops.map(\.ordinal).map(String.init).joined(separator: ", ")
        parts.append("at ops \(ordinals)")
        return parts.joined(separator: ", ")
    }

    /// Keeps the basename intact and abbreviates the directory — which file it
    /// is matters most, but two files can share a basename so the directory
    /// cannot simply be dropped. The leading `…/` marks the elision so an
    /// abbreviated path is not mistaken for a genuine relative one.
    private static func displayPath(_ path: String) -> String {
        let ns = path as NSString
        let name = ns.lastPathComponent
        let dir = ns.deletingLastPathComponent
        guard !dir.isEmpty, dir != "/" else { return name }
        let components = dir.split(separator: "/").map(String.init)
        guard components.count > 2 else { return "\(dir)/\(name)" }
        let tail = components.suffix(2).joined(separator: "/")
        return "…/\(tail)/\(name)"
    }

    // MARK: - View plumbing

    private static func label(_ text: String, size: CGFloat, color: NSColor) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = .systemFont(ofSize: size)
        field.textColor = color
        field.lineBreakMode = .byTruncatingTail
        field.maximumNumberOfLines = 1
        return field
    }

    private static func monospacedLabel(_ text: String, color: NSColor) -> NSTextField {
        let field = label(text, size: 10.5, color: color)
        field.font = .monospacedDigitSystemFont(ofSize: 10.5, weight: .regular)
        field.alignment = .right
        return field
    }

    /// SF Symbols rather than raw glyphs: `＋` (U+FF0B) renders with CJK
    /// metrics next to `◻`, `⌁` has thin font coverage, and a symbol image
    /// carries its own VoiceOver description.
    private static func badgeView(symbol: String?, description: String?) -> NSView {
        let view = NSImageView()
        view.imageScaling = .scaleProportionallyDown
        view.contentTintColor = .secondaryLabelColor
        if let symbol {
            view.image = NSImage(systemSymbolName: symbol, accessibilityDescription: description)
        }
        view.setAccessibilityElement(false)
        return view
    }

    private static func labelledRow(
        symbol: String,
        description: String,
        text: String,
        track: FileAccessTrackView?,
        counts: String,
        accessibilityValue: String
    ) -> FileAccessRowView {
        let row = assemble(
            row: FileAccessRowView(path: nil),
            badge: badgeView(symbol: symbol, description: description),
            name: label(text, size: 11.5, color: .tertiaryLabelColor),
            track: track,
            counts: monospacedLabel(counts, color: .tertiaryLabelColor)
        )
        row.setAccessibilityElement(true)
        row.setAccessibilityRole(.group)
        row.setAccessibilityLabel(description)
        row.setAccessibilityValue(accessibilityValue)
        row.setAccessibilityChildren([])
        return row
    }

    private static func assemble(
        row: FileAccessRowView,
        badge: NSView,
        name: NSTextField,
        track: FileAccessTrackView?,
        counts: NSTextField
    ) -> FileAccessRowView {
        row.translatesAutoresizingMaskIntoConstraints = false
        let spacer = NSView()
        let trackOrSpacer: NSView = track ?? spacer

        for view in [badge, name, trackOrSpacer, counts] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = true
            row.addSubview(view)
        }
        row.heightAnchor.constraint(equalToConstant: rowHeight).isActive = true
        row.columns = (badge: badge, name: name, track: trackOrSpacer, counts: counts)
        return row
    }


    // MARK: - Testing seams

    var rowCountForTesting: Int { rowsStack.arrangedSubviews.count }
    var readoutForTesting: String { readoutField.stringValue }
    var stripForTesting: FileAccessTrackView? { strip }
    var rowViewsForTesting: [NSView] { rowsStack.arrangedSubviews }
    func stepUuidForTesting(ordinal: Int) -> String? { stepByOrdinal[ordinal] }
    func countsTextForTesting(path: String) -> String? { countsFieldByPath[path]?.stringValue }
    func applyDeltasForTesting(_ stats: TurnFileDiffStats) { apply(stats) }
    func showReadoutForTesting(_ segment: FileAccessTrackView.Segment?) {
        showReadout(for: segment)
    }
    /// The key the card actually handed the cache. The renderer passes
    /// `block.diffCacheKey`, and passing `block.id` instead would silently
    /// disable the freshness the key exists for, so it is worth observing.
    private(set) var lastDeltaKeyForTesting: String?
    var deltaTaskIsCancelledForTesting: Bool? { diffTask?.isCancelled }
    var columnMetricsForTesting: ColumnMetrics { columnMetrics }
    var columnMetricsPassesForTesting: Int { columnMetricsPasses }
    var hasFoldedRowForTesting: Bool { foldedRow != nil }
    var isFoldedRowsExpandedForTesting: Bool { foldedRowsExpanded }

    /// Awaits the in-flight delta read, so a test can assert on its effect
    /// without racing the actor hop.
    func awaitDeltaLoadForTesting() async {
        await diffTask?.value
    }
    var nameFieldsAreSelectableForTesting: Bool {
        rowViewByPath.values.contains { row in
            row.subviews.compactMap { $0 as? NSTextField }.contains(where: \.isSelectable)
        }
    }

    /// Returns whether a row was found and activated, so a test can assert the
    /// row exists rather than silently passing on a miss.
    @discardableResult
    func activateRowForTesting(index: Int) -> Bool {
        guard let row = rowsStack.arrangedSubviews[index] as? FileAccessRowView else {
            return false
        }
        return row.activateForTesting()
    }

    @discardableResult
    func activateRowForTesting(path: String) -> Bool {
        guard let row = rowViewByPath[path] as? FileAccessRowView else { return false }
        return row.activateForTesting()
    }

    @discardableResult
    func activateFoldedRowForTesting() -> Bool {
        guard let row = foldedRow as? FileAccessRowView else { return false }
        return row.activateForTesting()
    }

    static func displayPathForTesting(_ path: String) -> String { displayPath(path) }
    static func badgeSymbolForTesting(_ row: TurnFileAccess.FileRow) -> String {
        badge(for: row).symbol
    }
    static func accessibilityValueForTesting(_ row: TurnFileAccess.FileRow) -> String {
        accessibilityValue(for: row)
    }
}

/// A row of the card. Owns the click target and the context menu, so the whole
/// row — and the filename inside it — answer the same way.
///
/// Clicking a 3pt mark is not how anyone reaches for a file, so the row is the
/// affordance and the marks are the precision instrument.
@MainActor
private final class FileAccessRowView: NSView {
    private let path: String?
    /// The four columns, positioned in `layout()`.
    var columns: (badge: NSView, name: NSTextField, track: NSView, counts: NSTextField)?
    /// Shared across the card, so every row's track starts at the same x.
    var metrics = TurnFileAccessView.ColumnMetrics(nameContentWidth: 0, opCount: 1) {
        didSet { if metrics != oldValue { needsLayout = true } }
    }
    /// Width this row's name text wants, before the card clamps it.
    var nameContentWidth: CGFloat { columns?.name.intrinsicContentSize.width ?? 0 }
    var onReveal: ((URL) -> Void)?
    var onOpen: ((URL) -> Void)?
    /// Primary click. `nil` leaves the row inert, which is what the operation
    /// strip and the shell summary want.
    var onActivate: (() -> Void)?

    init(path: String?) {
        self.path = path
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// Children are positioned here rather than by constraints.
    ///
    /// Every row runs the same function on the same width, so the columns are
    /// identical by construction — which is what the shared axis needs. Doing
    /// it with constraint constants meant updating them from a layout callback,
    /// and the update either arrived a pass late or not at all depending on
    /// which callback it was hung from.
    override func layout() {
        super.layout()
        guard let columns else { return }
        let widths = TurnFileAccessView.columnWidths(forRowWidth: bounds.width, metrics: metrics)
        let gap = TurnFileAccessView.columnGap

        func centre(_ view: NSView, x: CGFloat, width: CGFloat, height: CGFloat) {
            view.frame = NSRect(
                x: x, y: ((bounds.height - height) / 2).rounded(), width: width, height: height
            )
        }

        var x: CGFloat = 0
        centre(columns.badge, x: x, width: TurnFileAccessView.badgeWidth,
               height: TurnFileAccessView.badgeWidth)
        x += TurnFileAccessView.badgeWidth + gap
        centre(columns.name, x: x, width: widths.name, height: columns.name.intrinsicContentSize.height)
        x += widths.name + gap
        centre(columns.track, x: x, width: widths.track, height: FileAccessTrackView.trackHeight)
        x += widths.track + gap
        // Immediately after the track, not pinned to the trailing edge: on a
        // wide pane that pin is what opened the gap this layout exists to
        // close. The surplus becomes a trailing margin instead.
        centre(columns.counts, x: x, width: TurnFileAccessView.countsWidth,
               height: columns.counts.intrinsicContentSize.height)

        // The cursor rects below are cut around the track's frame, which just
        // moved; without this the hand keeps the pre-resize boundary.
        window?.invalidateCursorRects(for: self)
    }

    /// Claims the row's own clicks back from its children.
    ///
    /// `NSTextField` and `NSImageView` are `NSControl`s, and `NSControl`
    /// overrides `mouseDown` to run the cell's tracking rather than passing the
    /// event to `nextResponder`. Between them the badge, the filename and the
    /// counts cover most of the row, so a left-click on any of them was
    /// swallowed — while right-click worked, because the label had been handed
    /// the row's menu explicitly. Making the name non-selectable stopped it
    /// opening a text-selection loop but did not give the event back.
    ///
    /// The track is left to itself: it distinguishes a mark from the gap beside
    /// it, which the row cannot. That exemption is keyed on the view's *type*,
    /// not on identity with `columns.track` — a row built without a track (the
    /// folded placeholder, the shell lane) carries a plain spacer in that slot,
    /// and handing a click to a spacer is the opposite of the intent here.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let hit = super.hitTest(point) else { return nil }
        if hit is FileAccessTrackView || hit.isDescendant(ofTrackIn: self) { return hit }
        return self
    }

    override func mouseDown(with event: NSEvent) {
        guard let onActivate else {
            super.mouseDown(with: event)
            return
        }
        onActivate()
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        guard onActivate != nil else { return }
        // Only where the click does something — a hand over an inert row is a
        // promise the card cannot keep.
        //
        // Two rects either side of the track, not one per subview: the gaps
        // between columns are ~6pt and the rows are taller than their labels,
        // so per-subview rects left bands where the hand flickered back to an
        // arrow while still over a clickable row (the labels' alignment rects
        // give back only ~2pt of the 8pt `columnGap`).
        //
        // The track is excluded on purpose. It sets its cursor directly from
        // `mouseMoved`, because it has to distinguish a mark from the gap
        // beside it; a rect over it would be applied only on entry, so once the
        // track switched to an arrow the pointer would keep it for the whole
        // traverse.
        guard let track = subviews.first(where: { $0 is FileAccessTrackView }) else {
            addCursorRect(bounds, cursor: .pointingHand)
            return
        }
        let left = NSRect(x: 0, y: 0, width: max(0, track.frame.minX), height: bounds.height)
        let right = NSRect(
            x: track.frame.maxX, y: 0,
            width: max(0, bounds.maxX - track.frame.maxX), height: bounds.height
        )
        if left.width > 0 { addCursorRect(left, cursor: .pointingHand) }
        if right.width > 0 { addCursorRect(right, cursor: .pointingHand) }
    }

    override func accessibilityPerformPress() -> Bool {
        guard let onActivate else { return false }
        onActivate()
        return true
    }

    /// Drives the real `mouseDown(with:)` rather than re-implementing its
    /// guard, so a regression in that method — losing the handler, always
    /// falling through to `super` — fails the tests that assert on the effect.
    /// Returns whether the row was clickable at all, which is what callers
    /// assert to prove they found a live row rather than an inert one.
    @discardableResult
    func activateForTesting() -> Bool {
        guard let event = NSEvent.mouseEvent(
            with: .leftMouseDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1
        ) else { return false }
        let clickable = onActivate != nil
        mouseDown(with: event)
        return clickable
    }

    func rowMenu() -> NSMenu {
        let menu = NSMenu()
        // Explicit enabling: the default would enable every item whose target
        // responds to its action, which would leave "Open" live on a file that
        // is no longer there.
        menu.autoenablesItems = false

        // First, and so the primary action — the same order Finder uses.
        let open = menu.addItem(withTitle: "Open", action: #selector(openFile), keyEquivalent: "")
        open.target = self
        open.isEnabled = path.map { FileManager.default.fileExists(atPath: $0) } ?? false
        menu.addItem(.separator())

        // Left enabled even when the file is gone: revealing falls back to the
        // parent directory, which is still where the file was.
        menu.addItem(
            withTitle: "Reveal in Finder", action: #selector(reveal), keyEquivalent: ""
        ).target = self
        menu.addItem(
            withTitle: "Copy Path", action: #selector(copyPath), keyEquivalent: ""
        ).target = self
        for item in menu.items where item !== open && !item.isSeparatorItem {
            item.isEnabled = true
        }
        return menu
    }

    override func menu(for event: NSEvent) -> NSMenu? { path == nil ? nil : rowMenu() }

    /// VoiceOver reaches a context menu through the show-menu action, which
    /// consults `menu` rather than `menu(for:)`.
    override func accessibilityPerformShowMenu() -> Bool {
        // Same guard as `menu(for:)`: a row with no file has no Reveal or Copy
        // to offer, and offering them anyway gave VoiceOver two dead items.
        guard path != nil else { return false }
        menu = rowMenu()
        return super.accessibilityPerformShowMenu()
    }

    @objc private func openFile() {
        guard let path else { return }
        onOpen?(URL(fileURLWithPath: path))
    }

    @objc private func reveal() {
        guard let path else { return }
        onReveal?(URL(fileURLWithPath: path))
    }

    @objc private func copyPath() {
        guard let path else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(path, forType: .string)
    }
}

private extension NSView {
    /// Whether this view sits inside a `FileAccessTrackView` under `root`.
    ///
    /// The track owns subviews of its own in no current configuration, but a
    /// click landing on one would still belong to the track rather than to the
    /// row around it.
    func isDescendant(ofTrackIn root: NSView) -> Bool {
        var view: NSView? = superview
        while let current = view, current !== root {
            if current is FileAccessTrackView { return true }
            view = current.superview
        }
        return false
    }
}
