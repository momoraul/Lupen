//
//  TurnTimelineView.swift
//  Lupen
//
//  Created by jaden on 2026/07/03.
//

import AppKit

/// C-24 — swimlane waterfall for one turn. Fixed-height lanes (Thinking /
/// top tools / Other / Reply); each segment is one step's span. Hover swaps
/// the readout line for the segment's detail (the Reports hero-readout
/// pattern — no tooltip latency); click jumps to the covering card.
///
/// Drawing is a single custom `draw(_:)` pass over rects computed in
/// `layout()`. Segments below the minimum pixel width are widened to stay
/// visible, and neighbours that then overlap merge into one cluster whose
/// readout reports the count and combined time ("Read ×12 · 3.4s") — the
/// standard dense-trace treatment.
@MainActor
final class TurnTimelineView: NSView {

    var onJumpToStep: ((String) -> Void)?

    private let model: TurnTimeline.Model
    private let readout = NSTextField(labelWithString: "")

    /// One hoverable bar: a segment, a merged cluster, or (non-clickable,
    /// `stepUuid == nil`) a compressed-idle break marker.
    private struct DrawnSegment {
        let rect: NSRect
        let stepUuid: String?
        let readout: String
        let isError: Bool
        var isBreak: Bool = false
        /// Short duration label drawn in the axis row under a break marker.
        var axisLabel: String?
        /// Dwell tooltip (Xcode-timeline style) — full content the one-line
        /// readout can't fit; clusters list their members.
        var tooltip: String = ""
    }

    private var drawn: [DrawnSegment] = []
    private var hoveredIndex: Int? {
        didSet {
            if hoveredIndex != oldValue {
                updateReadout()
                updateTooltip()
                needsDisplay = true
            }
        }
    }

    // MARK: - Metrics

    private static let labelWidth: CGFloat = 96
    private static let laneHeight: CGFloat = 14
    private static let laneGap: CGFloat = 3
    private static let readoutHeight: CGFloat = 16
    private static let axisHeight: CGFloat = 15
    private static let plotTrailing: CGFloat = 4
    private static let minSegmentWidth: CGFloat = 2

    // MARK: - Init

    init(model: TurnTimeline.Model) {
        self.model = model
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        readout.font = .monospacedDigitSystemFont(ofSize: 10, weight: .regular)
        readout.textColor = .secondaryLabelColor
        readout.lineBreakMode = .byTruncatingTail
        readout.maximumNumberOfLines = 1
        addSubview(readout)
        updateReadout()

        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Turn timeline")
        setAccessibilityValue(model.summaryText)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    override var intrinsicContentSize: NSSize {
        let lanes = CGFloat(model.lanes.count)
        let height = Self.readoutHeight + 6
            + lanes * Self.laneHeight + max(0, lanes - 1) * Self.laneGap
            + Self.axisHeight
        return NSSize(width: NSView.noIntrinsicMetric, height: height)
    }

    // MARK: - Layout / geometry

    override func layout() {
        super.layout()
        readout.frame = NSRect(
            x: 0, y: 0, width: bounds.width, height: Self.readoutHeight
        )
        rebuildDrawnSegments()
    }

    private var plotX: CGFloat { Self.labelWidth + 8 }
    private var plotWidth: CGFloat { max(1, bounds.width - plotX - Self.plotTrailing) }

    private func laneY(_ index: Int) -> CGFloat {
        Self.readoutHeight + 6 + CGFloat(index) * (Self.laneHeight + Self.laneGap)
    }

    /// Compute bar rects; widen sub-pixel segments to `minSegmentWidth` and
    /// merge neighbours that end up overlapping into clusters.
    private func rebuildDrawnSegments() {
        drawn.removeAll()
        guard model.displayDuration > 0 else { return }
        let scale = plotWidth / CGFloat(model.displayDuration)

        // Compressed-idle break markers: one hoverable column spanning all
        // lanes; hover explains how much real time the cut hides.
        let lanesBottom = laneY(model.lanes.count - 1) + Self.laneHeight
        for marker in model.breaks {
            let x = plotX + CGFloat(marker.displayStart) * scale
            let width = max(4, CGFloat(marker.displayWidth) * scale)
            drawn.append(DrawnSegment(
                rect: NSRect(x: x, y: laneY(0), width: width, height: lanesBottom - laneY(0)),
                stepUuid: nil,
                readout: "⋯ idle \(TurnTimeline.formatDuration(marker.hiddenDuration)) (axis compressed)",
                isError: false,
                isBreak: true,
                axisLabel: "⋯\(TurnTimeline.formatDuration(marker.hiddenDuration))",
                tooltip: "Idle \(TurnTimeline.formatDuration(marker.hiddenDuration)) — compressed out of the axis"
            ))
        }

        for (laneIndex, lane) in model.lanes.enumerated() {
            let y = laneY(laneIndex) + 2
            let height = Self.laneHeight - 4

            struct Pending {
                var minX: CGFloat
                var maxX: CGFloat
                var count: Int
                var totalDuration: TimeInterval
                var stepUuid: String
                var detail: String
                var isError: Bool
                var firstTooltip: String
                var memberDetails: [String]
            }
            var pending: Pending?

            func flush() {
                guard let p = pending else { return }
                let readoutText: String
                let tooltipText: String
                if p.count == 1 {
                    readoutText = "\(p.detail) · \(TurnTimeline.formatDuration(p.totalDuration))"
                    // Duration rides the header line ("Thinking · 37s"), the
                    // same shape as cluster headers.
                    let parts = p.firstTooltip.split(
                        separator: "\n", maxSplits: 1, omittingEmptySubsequences: false
                    )
                    let headline = parts.first.map(String.init) ?? p.detail
                    let header = "\(headline) · \(TurnTimeline.formatDuration(p.totalDuration))"
                    tooltipText = parts.count > 1 ? "\(header)\n\(parts[1])" : header
                } else {
                    readoutText = "\(lane.name) ×\(p.count) · \(TurnTimeline.formatDuration(p.totalDuration))"
                    // Xcode-timeline style: a merged bar lists its members.
                    var lines = [readoutText]
                    lines += p.memberDetails.prefix(6)
                    if p.memberDetails.count > 6 {
                        lines.append("… +\(p.memberDetails.count - 6) more")
                    }
                    tooltipText = lines.joined(separator: "\n")
                }
                drawn.append(DrawnSegment(
                    rect: NSRect(x: p.minX, y: y, width: max(Self.minSegmentWidth, p.maxX - p.minX), height: height),
                    stepUuid: p.stepUuid,
                    readout: readoutText,
                    isError: p.isError,
                    tooltip: tooltipText
                ))
                pending = nil
            }

            // Lane segments are chronological by construction (the builder
            // walks steps in order and its display-remap is monotonic) —
            // re-sorting thousands of segments on every layout pass would
            // burn main-thread time during live resize for nothing.
            for segment in lane.segments {
                let minX = plotX + CGFloat(segment.start) * scale
                let maxX = minX + max(Self.minSegmentWidth, CGFloat(segment.duration) * scale)
                if var p = pending, minX <= p.maxX + 0.5 {
                    // Overlaps (or abuts within half a point) the previous
                    // drawn bar → merge into a cluster.
                    p.maxX = max(p.maxX, maxX)
                    p.count += 1
                    p.totalDuration += segment.duration
                    p.isError = p.isError || segment.isError
                    p.memberDetails.append(segment.detail)
                    pending = p
                } else {
                    flush()
                    pending = Pending(
                        minX: minX, maxX: maxX, count: 1,
                        totalDuration: segment.duration,
                        stepUuid: segment.stepUuid,
                        detail: segment.detail,
                        isError: segment.isError,
                        firstTooltip: segment.tooltip,
                        memberDetails: [segment.detail]
                    )
                }
            }
            flush()
        }

        // Bars may have moved or re-clustered under the cursor (resize) —
        // re-derive hover from the actual mouse position, then refresh the
        // readout/tooltip explicitly: the numeric index can stay the same
        // while the segment behind it changed, which `didSet` won't catch.
        if let window {
            let point = convert(window.mouseLocationOutsideOfEventStream, from: nil)
            hoveredIndex = bounds.contains(point) ? hitIndex(at: point) : nil
        } else {
            hoveredIndex = nil
        }
        updateReadout()
        updateTooltip()
        needsDisplay = true
    }

    /// Instant tooltip (the Xcode-timeline behaviour): shown the moment a
    /// bar is hovered — the system tool-tip's fixed dwell delay defeats a
    /// scanning workflow, so this is a tiny non-activating panel we order
    /// in/out ourselves.
    private var tooltipPanel: TimelineTooltipPanel?

    private func updateTooltip() {
        guard let index = hoveredIndex, index < drawn.count,
              !drawn[index].tooltip.isEmpty,
              let window else {
            tooltipPanel?.hide()
            return
        }
        let segment = drawn[index]
        let panel = tooltipPanel ?? TimelineTooltipPanel()
        tooltipPanel = panel
        // Anchor above the hovered bar at the cursor's x — stable while the
        // pointer travels along the bar, never covering the lane being read.
        let barOnScreen = window.convertToScreen(convert(segment.rect, to: nil))
        panel.show(
            text: segment.tooltip,
            anchorX: NSEvent.mouseLocation.x,
            bottomY: barOnScreen.maxY + 6,
            host: window
        )
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { tooltipPanel?.hide() }
    }

    /// Detail tabs swap views with `isHidden` (no remove-from-superview), so
    /// this — not `viewDidMoveToWindow` — is what fires on a tab switch.
    override func viewDidHide() {
        super.viewDidHide()
        tooltipPanel?.hide()
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard !model.lanes.isEmpty else { return }

        // Lane labels (name left, per-lane total right) + faint row guides.
        let labelFont = NSFont.systemFont(ofSize: 10)
        for (index, lane) in model.lanes.enumerated() {
            let y = laneY(index)
            let nameAttributes: [NSAttributedString.Key: Any] = [
                .font: labelFont,
                .foregroundColor: NSColor.secondaryLabelColor,
            ]
            let totalAttributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .regular),
                .foregroundColor: NSColor.tertiaryLabelColor,
            ]
            let total = TurnTimeline.formatDuration(lane.totalDuration) as NSString
            let totalWidth = total.size(withAttributes: totalAttributes).width
            total.draw(
                at: NSPoint(x: Self.labelWidth - totalWidth, y: y + 1.5),
                withAttributes: totalAttributes
            )

            let nameBudget = Self.labelWidth - totalWidth - 6
            var truncated = lane.name as NSString
            while truncated.size(withAttributes: nameAttributes).width > nameBudget,
                  truncated.length > 4 {
                truncated = (truncated.substring(to: truncated.length - 2) + "…") as NSString
            }
            truncated.draw(at: NSPoint(x: 0, y: y + 1), withAttributes: nameAttributes)

            NSColor.separatorColor.withAlphaComponent(0.25).setFill()
            NSRect(x: plotX, y: y + Self.laneHeight - 1, width: plotWidth, height: 0.5).fill()
        }

        // Segments + break markers.
        for (index, segment) in drawn.enumerated() {
            let hovered = index == hoveredIndex
            if segment.isBreak {
                // Axis cut: faint column + double hairline edges — reads as
                // "time removed here", not as activity.
                NSColor.separatorColor.withAlphaComponent(hovered ? 0.25 : 0.12).setFill()
                segment.rect.fill()
                NSColor.tertiaryLabelColor.setFill()
                NSRect(x: segment.rect.minX, y: segment.rect.minY,
                       width: 1, height: segment.rect.height).fill()
                NSRect(x: segment.rect.maxX - 1, y: segment.rect.minY,
                       width: 1, height: segment.rect.height).fill()
                continue
            }
            let base: NSColor = segment.isError
                ? .systemRed
                : .controlAccentColor
            base.withAlphaComponent(hovered ? 1.0 : 0.72).setFill()
            NSBezierPath(roundedRect: segment.rect, xRadius: 2, yRadius: 2).fill()
        }

        // Axis: hairline + 0s / total labels.
        let axisTop = laneY(model.lanes.count - 1) + Self.laneHeight + 3
        NSColor.separatorColor.setFill()
        NSRect(x: plotX, y: axisTop, width: plotWidth, height: 0.5).fill()
        let axisAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .regular),
            .foregroundColor: NSColor.tertiaryLabelColor,
        ]
        ("0s" as NSString).draw(
            at: NSPoint(x: plotX, y: axisTop + 2), withAttributes: axisAttributes
        )
        let totalLabel = TurnTimeline.formatDuration(model.totalDuration) as NSString
        let totalWidth = totalLabel.size(withAttributes: axisAttributes).width
        totalLabel.draw(
            at: NSPoint(x: plotX + plotWidth - totalWidth, y: axisTop + 2),
            withAttributes: axisAttributes
        )

        // Break durations sit in the axis row under their marker, so the
        // hidden time is visible without hovering. Clamped away from the
        // fixed 0s/total labels.
        for segment in drawn where segment.isBreak {
            guard let label = segment.axisLabel else { continue }
            let text = label as NSString
            let width = text.size(withAttributes: axisAttributes).width
            let minX = plotX + 22
            let maxX = plotX + plotWidth - totalWidth - width - 8
            guard maxX > minX else { continue }
            let x = min(max(segment.rect.midX - width / 2, minX), maxX)
            text.draw(at: NSPoint(x: x, y: axisTop + 2), withAttributes: axisAttributes)
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    // MARK: - Hover / click

    private var hoverTracking: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        // Remove only OUR area — AppKit's tooltip machinery parks its own
        // tracking areas in the same `trackingAreas` list, and nuking them
        // here silently kills every `addToolTip` registration.
        if let hoverTracking { removeTrackingArea(hoverTracking) }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self
        )
        addTrackingArea(area)
        hoverTracking = area
    }

    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        hoveredIndex = hitIndex(at: point)
        let clickable = hoveredIndex.map { drawn[$0].stepUuid != nil } ?? false
        (clickable ? NSCursor.pointingHand : NSCursor.arrow).set()
    }

    override func mouseExited(with event: NSEvent) {
        hoveredIndex = nil
        NSCursor.arrow.set()
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard let index = hitIndex(at: point),
              let stepUuid = drawn[index].stepUuid else { return }
        tooltipPanel?.hide()
        onJumpToStep?(stepUuid)
    }

    /// Segment under `point`, with a small vertical grace so 10pt bars are
    /// comfortable targets.
    private func hitIndex(at point: NSPoint) -> Int? {
        drawn.firstIndex { $0.rect.insetBy(dx: -1, dy: -2).contains(point) }
    }

    private func updateReadout() {
        if let index = hoveredIndex, index < drawn.count {
            let segment = drawn[index]
            readout.attributedStringValue = Self.readoutText(
                segment.readout, leadColor: segment.isError ? .systemRed : .labelColor
            )
        } else {
            readout.attributedStringValue = Self.readoutText(
                "⏱ \(model.summaryText)", leadColor: .labelColor
            )
        }
    }

    /// Lead component (up to the first "·") reads as the headline; the rest
    /// recedes — same hierarchy as the Reports hero readout.
    private static func readoutText(_ text: String, leadColor: NSColor) -> NSAttributedString {
        let font = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular)
        let leadFont = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .semibold)
        let result = NSMutableAttributedString(
            string: text,
            attributes: [.font: font, .foregroundColor: NSColor.secondaryLabelColor]
        )
        let lead = (text as NSString).range(of: " · ")
        let leadLength = lead.location == NSNotFound ? result.length : lead.location
        result.addAttributes(
            [.font: leadFont, .foregroundColor: leadColor],
            range: NSRange(location: 0, length: leadLength)
        )
        return result
    }
}

/// Tiny non-activating tooltip panel shown the instant a timeline bar is
/// hovered (the system tool tip's fixed dwell delay defeats scanning). Uses
/// the system `.toolTip` material so it reads as a native tooltip, ignores
/// mouse events so it can never steal the hover, and clamps to the screen.
@MainActor
private final class TimelineTooltipPanel {
    private let panel: NSPanel
    private let label = NSTextField(labelWithString: "")
    private static let maxTextWidth: CGFloat = 440
    private static let paddingH: CGFloat = 9
    private static let paddingV: CGFloat = 6

    init() {
        panel = NSPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = true
        panel.animationBehavior = .none

        let effect = NSVisualEffectView()
        effect.material = .toolTip
        effect.state = .active
        effect.blendingMode = .behindWindow
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 6
        effect.layer?.masksToBounds = true

        label.font = .systemFont(ofSize: 11)
        label.textColor = .labelColor
        label.lineBreakMode = .byWordWrapping
        label.maximumNumberOfLines = 0
        effect.addSubview(label)
        panel.contentView = effect
    }

    func show(text: String, anchorX: CGFloat, bottomY: CGFloat, host: NSWindow) {
        // Ride as a child window: closing/miniaturizing the host takes the
        // tooltip down with it — otherwise a floating panel can outlive a
        // Cmd-W'd window as a permanent screen ghost.
        if panel.parent !== host {
            panel.parent?.removeChildWindow(panel)
            host.addChildWindow(panel, ordered: .above)
        }
        label.attributedStringValue = Self.attributed(text)
        let bounds = label.attributedStringValue.boundingRect(
            with: NSSize(width: Self.maxTextWidth, height: 600),
            options: [.usesLineFragmentOrigin, .usesFontLeading]
        )
        let textSize = NSSize(width: ceil(bounds.width), height: ceil(bounds.height))
        label.frame = NSRect(
            x: Self.paddingH, y: Self.paddingV,
            width: textSize.width, height: textSize.height
        )
        let panelSize = NSSize(
            width: textSize.width + Self.paddingH * 2,
            height: textSize.height + Self.paddingV * 2
        )

        var origin = NSPoint(x: anchorX + 10, y: bottomY)
        if let screen = NSScreen.screens.first(where: { $0.frame.contains(NSPoint(x: anchorX, y: bottomY)) })
            ?? NSScreen.main {
            let visible = screen.visibleFrame
            origin.x = min(max(visible.minX + 4, origin.x), visible.maxX - panelSize.width - 4)
            origin.y = min(max(visible.minY + 4, origin.y), visible.maxY - panelSize.height - 4)
        }
        panel.setFrame(NSRect(origin: origin, size: panelSize), display: true)
        panel.orderFrontRegardless()
    }

    func hide() {
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
    }

    /// First line leads (semibold), the rest recedes — mirrors the readout.
    private static func attributed(_ text: String) -> NSAttributedString {
        let result = NSMutableAttributedString(
            string: text,
            attributes: [
                .font: NSFont.systemFont(ofSize: 11),
                .foregroundColor: NSColor.secondaryLabelColor,
            ]
        )
        let newline = (text as NSString).range(of: "\n")
        let leadLength = newline.location == NSNotFound ? result.length : newline.location
        result.addAttributes(
            [
                .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
                .foregroundColor: NSColor.labelColor,
            ],
            range: NSRange(location: 0, length: leadLength)
        )
        return result
    }
}
