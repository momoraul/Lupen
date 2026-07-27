//
//  FileAccessTrackView.swift
//  Lupen
//
//  Created by jaden on 2026/07/26.
//

import AppKit

/// One row of the file-access card's op-order axis: the aggregate sequence
/// strip, or a single file's marks.
///
/// Custom-drawn rather than built from subviews. A turn carries up to 79 ops,
/// each drawn twice — once on its file's row and once on the aggregate strip —
/// so a mark per subview would add ~160 views to a card that already holds ~75
/// for its labels. Drawing keeps that cost proportional to pixels instead.
/// The row's *text* stays in real `NSTextField`s next to this view, so the
/// filename and counts remain selectable and reachable by VoiceOver — only the
/// marks are drawn.
@MainActor
final class FileAccessTrackView: NSView {

    /// What one drawn mark represents.
    struct Mark: Equatable {
        let ordinal: Int
        /// `nil` renders the search treatment — searches have no file.
        let operation: TurnFileAccess.Operation?
        let isError: Bool
    }

    // MARK: - Geometry
    /// Narrowest a mark can be and still register as a mark rather than as
    /// texture, and the gap that has to survive beside it. Together they set
    /// how many shapes the track can hold before it starts bucketing.
    static let legibleMarkWidth: CGFloat = 3
    static let legibleGap: CGFloat = 1
    /// Widest a mark grows when a turn has only a few ops — a 13-op turn
    /// should not draw hairlines across 200pt of track.
    static let maxMarkWidth: CGFloat = 12
    static let markGap: CGFloat = 2
    /// Widest one operation's slot may get.
    ///
    /// The track fills the pane, and a pane is wide — without this a
    /// three-operation turn put its marks 187pt apart and the row read as
    /// three isolated dots instead of a sequence. Capping the pitch keeps a
    /// sparse turn tight at the left, the way a trace instrument leaves the
    /// rest of a lane empty rather than stretching three events across it.
    static let maxSlotWidth: CGFloat = maxMarkWidth + markGap
    /// One height for every mark.
    ///
    /// A write used to draw taller than a read or an edit, which put a second
    /// encoding channel on the track that nothing explained — the card has no
    /// legend by design, and height is static, so unlike colour it cannot be
    /// learned by hovering. Read-versus-change is what the track is for; which
    /// *kind* of change it was is on the row badge and in the hover readout.
    static let markHeight: CGFloat = 11
    /// Row height the track occupies. Kept as its own constant because the
    /// row's hit box and vertical centring are derived from it.
    static let trackHeight: CGFloat = 15

    /// Total ops in the turn — the axis extent every row shares, so a mark at
    /// ordinal 7 lines up across rows.
    private let totalOrdinals: Int
    private let marks: [Mark]

    var onSelect: ((Int) -> Void)?
    /// Ordinals that actually resolve to a step. The aggregate strip carries
    /// every mark in the turn, including searches and the ops of files folded
    /// past the row cap — none of which have a jump target, so neither the
    /// cursor nor a click should suggest otherwise.
    var selectableOrdinals: Set<Int>?
    /// Reports the shape under the pointer (nil when the pointer leaves). A
    /// shape may stand for a bucket of operations, which the readout says.
    var onHover: ((Segment?) -> Void)?

    private var trackingAreaRef: NSTrackingArea?
    private var hoveredOrdinal: Int?

    init(marks: [Mark], totalOrdinals: Int) {
        self.marks = marks
        self.totalOrdinals = max(1, totalOrdinals)
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: Self.trackHeight)
    }

    override var isFlipped: Bool { true }

    // MARK: - Layout maths

    /// Width one ordinal slot occupies, including its trailing gap.
    ///
    /// `width / totalOrdinals` with no floor — the axis has to stay inside the
    /// track, and positions stay proportional to the ordinal so a mark lines
    /// up with the same ordinal on every other row — and capped above, so a
    /// sparse turn on a wide pane clusters instead of scattering.
    var slotWidth: CGFloat {
        min(max(0, bounds.width) / CGFloat(totalOrdinals), Self.maxSlotWidth)
    }



    /// What a shape draws as. Coarser than `Operation` on purpose: `.edit` and
    /// `.write` paint identically, so treating them as distinct would split a
    /// band at a boundary that leaves no mark on screen.
    enum RenderKind: Equatable {
        case read
        case change
        case search

        init(_ operation: TurnFileAccess.Operation?) {
            switch operation {
            case .read:         self = .read
            case .edit, .write: self = .change
            case .none:         self = .search
            }
        }
    }

    /// One drawn shape. Stands for a single operation when there is room, and
    /// for a positional bucket of them when there is not.
    struct Segment: Equatable {
        var rect: NSRect
        var kind: RenderKind
        /// At least one operation in it failed.
        var isError: Bool
        var markCount: Int
        var errorCount: Int
        var firstOrdinal: Int
        var lastOrdinal: Int
        /// The ordinals it covers, so a click can land on a real one.
        var ordinals: [Int]
        /// More than one kind fell in here, so `kind` is the majority rather
        /// than the whole story.
        var isMixed: Bool
    }

    /// Drawn shapes, rebuilt when the width changes.
    private(set) var segments: [Segment] = []

    /// How many shapes fit while each keeps a visible width and a visible gap.
    var shapeCapacity: Int {
        let pitch = Self.legibleMarkWidth + Self.legibleGap
        return max(1, Int((max(0, bounds.width) + Self.legibleGap) / pitch))
    }

    /// Builds the shapes.
    ///
    /// Below capacity every operation gets its own mark at its own position —
    /// nothing is merged, because nothing needs to be. Above capacity the
    /// track is divided into as many buckets as fit and each bucket becomes one
    /// shape, which is the only way to guarantee a visible gap at any density.
    ///
    /// An earlier attempt merged runs of the same kind whenever their rects
    /// touched. That predicate turned out to be an identity — a mark's width
    /// was `slot - gap`, so the next mark always began exactly at
    /// `maxX + gap` — and it therefore merged from 15 operations upward,
    /// collapsing a third of all marks across the corpus and reducing 56 turns
    /// to a single band. It also failed to fix the case it was written for:
    /// widening marks to a legible 3pt while the slot was 1.55pt left every
    /// band boundary overlapping, so the strip stayed solid.
    private func rebuildSegments() {
        segments = []
        guard bounds.width > 0, !marks.isEmpty else { return }

        if totalOrdinals <= shapeCapacity {
            segments = marks.map { mark in
                Segment(
                    rect: markRect(forOrdinal: mark.ordinal),
                    kind: RenderKind(mark.operation),
                    isError: mark.isError,
                    markCount: 1,
                    errorCount: mark.isError ? 1 : 0,
                    firstOrdinal: mark.ordinal,
                    lastOrdinal: mark.ordinal,
                    ordinals: [mark.ordinal],
                    isMixed: false
                )
            }
            return
        }

        let capacity = shapeCapacity
        let bucketWidth = bounds.width / CGFloat(capacity)
        var buckets: [Int: [Mark]] = [:]
        for mark in marks {
            let position = CGFloat(mark.ordinal - 1) / CGFloat(totalOrdinals)
            let index = min(capacity - 1, max(0, Int(position * CGFloat(capacity))))
            buckets[index, default: []].append(mark)
        }

        for index in buckets.keys.sorted() {
            guard let bucket = buckets[index], !bucket.isEmpty else { continue }
            let kinds = bucket.map { RenderKind($0.operation) }
            // Majority, not deepest: at ~3 operations per bucket, letting a
            // single edit speak for two reads would over-report change.
            let dominant = kinds.reduce(into: [RenderKind: Int]()) { $0[$1, default: 0] += 1 }
                .max { left, right in
                    left.value == right.value
                        ? Self.tieBreak(left.key) < Self.tieBreak(right.key)
                        : left.value < right.value
                }?.key ?? .read
            let ordinals = bucket.map(\.ordinal).sorted()
            let errors = bucket.filter(\.isError).count
            segments.append(Segment(
                rect: NSRect(
                    x: CGFloat(index) * bucketWidth,
                    y: 0,
                    width: max(Self.legibleMarkWidth, bucketWidth - Self.legibleGap),
                    height: bounds.height
                ),
                kind: dominant,
                isError: errors > 0,
                markCount: bucket.count,
                errorCount: errors,
                firstOrdinal: ordinals.first ?? 0,
                lastOrdinal: ordinals.last ?? 0,
                ordinals: ordinals,
                isMixed: Set(kinds).count > 1
            ))
        }
    }

    /// Tie-break for a bucket with no majority: surface the change, because
    /// "something changed here" is the more useful thing to notice.
    private static func tieBreak(_ kind: RenderKind) -> Int {
        switch kind {
        case .change: return 3
        case .read:   return 2
        case .search: return 1
        }
    }

    /// Frame for one operation's mark when every operation has room.
    private func markRect(forOrdinal ordinal: Int) -> NSRect {
        let slot = slotWidth
        let gap = min(Self.markGap, slot * 0.3)
        let width = min(Self.maxMarkWidth, max(Self.legibleMarkWidth, slot - gap))
        return NSRect(x: CGFloat(ordinal - 1) * slot, y: 0, width: width, height: bounds.height)
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        rebuildSegments()
        needsDisplay = true
        // Shapes may have moved or re-bucketed under a stationary pointer, so
        // the ring and the readout have to be re-derived rather than left
        // describing a shape that no longer exists there.
        if hoveredOrdinal != nil, let window {
            let local = convert(window.mouseLocationOutsideOfEventStream, from: nil)
            // Forced: re-deriving to `nil` has to reach the readout too.
            // Clearing `hoveredOrdinal` first and relying on the ordinary
            // change check meant a pointer that ended up over no shape left
            // the readout naming an operation it had left — and pinned
            // `isShowingMarkReadout`, which then blocked every idle update.
            updateHover(at: bounds.contains(local) ? local : nil, force: true)
        }
    }

    /// The operation a click at `point` should act on.
    ///
    /// Proportional within the shape rather than always its first operation:
    /// a bucket can span a dozen operations, and sending every pixel of it to
    /// the same place breaks the direct-manipulation expectation the marks set.
    /// Snapped to an ordinal the shape actually holds, then to the nearest
    /// selectable one — a shape whose first operation belongs to a folded file
    /// otherwise went dead across its whole width.
    func ordinal(at point: NSPoint) -> Int? {
        guard let segment = segment(at: point) else { return nil }
        let candidates = selectableOrdinals.map { allowed in
            segment.ordinals.filter(allowed.contains)
        } ?? segment.ordinals
        guard !candidates.isEmpty else { return nil }
        guard segment.rect.width > 0 else { return candidates.first }
        let fraction = min(1, max(0, (point.x - segment.rect.minX) / segment.rect.width))
        let index = min(candidates.count - 1, Int(fraction * CGFloat(candidates.count)))
        return candidates[index]
    }

    /// The shape a hover should describe, regardless of whether it can be
    /// clicked.
    func hoverOrdinal(at point: NSPoint) -> Int? {
        segment(at: point)?.firstOrdinal
    }

    /// The shape under a point. The hit box is widened a little in both
    /// directions — an 11pt mark is an uncomfortable pointer target, and the
    /// gap beside it belongs to nobody else.
    func segment(at point: NSPoint) -> Segment? {
        segments.first { $0.rect.insetBy(dx: -1, dy: -3).contains(point) }
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        if segments.isEmpty { rebuildSegments() }

        // Baseline: a hairline the marks sit on, so a sparse row reads as an
        // intentional trace rather than as empty space.
        let baseline = NSRect(x: 0, y: (bounds.height / 2) - 0.25, width: bounds.width, height: 0.5)
        NSColor.separatorColor.withAlphaComponent(0.25).setFill()
        baseline.fill()

        for segment in segments { draw(segment: segment, in: paintBox(for: segment)) }
    }

    /// Where a segment is actually painted.
    ///
    /// Split out of `draw(_:)` so it can be asserted on. `Segment.rect` is the
    /// hit box and is full track height for every kind by construction, so a
    /// test over `segments` could never have caught a per-kind painted height —
    /// which is exactly the regression the one height rule exists to prevent.
    func paintBox(for segment: Segment) -> NSRect {
        let height = min(Self.markHeight, bounds.height)
        return NSRect(
            x: segment.rect.minX,
            y: (bounds.height - height) / 2,
            width: segment.rect.width,
            height: height
        )
    }

    private func draw(segment: Segment, in box: NSRect) {
        switch segment.kind {
        case _ where segment.isError:
            NSColor.systemRed.setFill()
            NSBezierPath(roundedRect: box, xRadius: 1.5, yRadius: 1.5).fill()
            drawFailureStrike(in: box)
        case .read:
            // Outline only: reading is the shallow touch, and the hollow fill
            // separates a read from a change without relying on hue.
            //
            // A stroke straddles its path, so the rect is inset by half the
            // line width — otherwise the outline spills past the box and a
            // read reads *wider* than an edit, the opposite of the intent.
            let lineWidth: CGFloat = min(1.2, box.width / 3)
            let inset = box.insetBy(dx: lineWidth / 2, dy: lineWidth / 2)
            let path = NSBezierPath(roundedRect: inset, xRadius: 1.5, yRadius: 1.5)
            path.lineWidth = lineWidth
            NSColor.secondaryLabelColor.setStroke()
            path.stroke()
        case .change:
            NSColor.controlAccentColor.setFill()
            NSBezierPath(roundedRect: box, xRadius: 1.5, yRadius: 1.5).fill()
        case .search:
            // Searches need to be legible, not invisible: quaternary label on
            // the near-white card fill lands around 1.2:1.
            NSColor.tertiaryLabelColor.setFill()
            NSBezierPath(roundedRect: box, xRadius: 1.5, yRadius: 1.5).fill()
        }

        // Drawn for every shape including failures — the one most worth
        // inspecting should not be the one without hover feedback.
        if segment.firstOrdinal == hoveredOrdinal { drawHoverRing(around: box) }
    }

    /// A user can set the system accent to red, which would make an edit mark
    /// and a failure mark identical, so the shape has to carry the meaning. On
    /// a hairline-wide mark a diagonal says nothing, so the treatment widens
    /// to a bracket that survives at 1.5pt.
    private func drawFailureStrike(in box: NSRect) {
        NSColor.white.withAlphaComponent(0.9).setStroke()
        let strike = NSBezierPath()
        if box.width >= 5 {
            strike.move(to: NSPoint(x: box.minX + 1, y: box.minY + 1))
            strike.line(to: NSPoint(x: box.maxX - 1, y: box.maxY - 1))
        } else {
            // Too narrow for a diagonal: a centre notch still breaks the fill.
            strike.move(to: NSPoint(x: box.midX, y: box.minY + 1))
            strike.line(to: NSPoint(x: box.midX, y: box.maxY - 1))
        }
        strike.lineWidth = 1
        strike.stroke()
    }

    private func drawHoverRing(around box: NSRect) {
        // Kept inside the slot so the ring cannot appear to belong to the
        // neighbouring mark when the track is dense.
        let outset = min(1.5, max(0.5, slotWidth * 0.2))
        let ring = NSBezierPath(
            roundedRect: box.insetBy(dx: -outset, dy: -1.5), xRadius: 2.5, yRadius: 2.5
        )
        ring.lineWidth = 1
        NSColor.labelColor.withAlphaComponent(0.55).setStroke()
        ring.stroke()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    // MARK: - Pointer

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        // Remove only our own area. AppKit's tooltip machinery keeps its
        // tracking areas in this same list, so clearing it wholesale silently
        // kills every `toolTip` registered on this view's siblings.
        if let existing = trackingAreaRef {
            removeTrackingArea(existing)
            trackingAreaRef = nil
        }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeInKeyWindow, .inVisibleRect],
            owner: self
        )
        addTrackingArea(area)
        trackingAreaRef = area
    }

    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        updateHover(at: point)
        updateCursor(forOrdinalAt: point)
    }

    override func mouseExited(with event: NSEvent) {
        updateHover(at: nil)
        updateCursor(forOrdinalAt: nil)
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard let ordinal = ordinal(at: point) else {
            super.mouseDown(with: event)
            return
        }
        onSelect?(ordinal)
    }

    /// Cursor is set from `mouseMoved` rather than through cursor rects: a
    /// dense card would register ~950 rects that AppKit re-derives on every
    /// scroll and resize, and — more importantly — a rect would promise a
    /// click on rows that have no jump target (the search lane never sets
    /// `onSelect`). The sibling `TurnTimelineView` sets the cursor the same
    /// way for the same reason.
    private func updateCursor(forOrdinalAt point: NSPoint?) {
        // `ordinal(at:)` already resolves to a selectable operation, so a nil
        // means the shape has none — exactly when the hand would be a lie.
        if onSelect != nil, point.flatMap({ ordinal(at: $0) }) != nil {
            NSCursor.pointingHand.set()
        } else {
            NSCursor.arrow.set()
        }
    }

    /// A hidden view gets no `mouseExited`, so folding the card while a mark is
    /// hovered would leave a stale ring behind for the next expand.
    override func viewDidHide() {
        super.viewDidHide()
        updateHover(at: nil)
    }

    var hoveredOrdinalForTesting: Int? { hoveredOrdinal }
    func updateHoverForTesting(at point: NSPoint?, force: Bool = false) {
        updateHover(at: point, force: force)
    }

    private func updateHover(at point: NSPoint?, force: Bool = false) {
        let ordinal = point.flatMap { self.hoverOrdinal(at: $0) }
        guard force || ordinal != hoveredOrdinal else { return }
        hoveredOrdinal = ordinal
        needsDisplay = true
        onHover?(segments.first { $0.firstOrdinal == ordinal })
    }


}
