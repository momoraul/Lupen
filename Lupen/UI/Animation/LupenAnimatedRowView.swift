import AppKit
import QuartzCore

/// Phase 8.3 — `NSTableRowView` subclass that knows how to play a
/// single subtle "appearance" animation: a brief background tint that
/// fades in, holds, and fades out. Used by both the conversation
/// outline (Turn / Step rows) and the sidebar (Session rows) to make
/// new arrivals + reorders perceptible without being noisy.
///
/// ## Implementation note (post-bugfix)
///
/// The first prototype relied on `self.wantsLayer = true` plus a
/// directly-added `CALayer` sublayer. That path silently failed in
/// practice: AppKit's row recycling and the outline view's own
/// drawing pipeline interacted badly with raw sublayers — the
/// animation either never appeared, ran on a zero-size layer, or got
/// composited beneath the cell content. Switched to a **layer-hosting
/// `NSView` subview** instead. The subview owns its own `CALayer`
/// (assigned BEFORE `wantsLayer` flip → layer-hosting mode, which is
/// reliable across recycling) and is added to the row view's subview
/// list, so it gets the standard subview drawing order — last-added
/// = topmost, just like every other cell in the row. The CAAnimation
/// is added to the subview's layer, which we own outright.
@MainActor
final class LupenAnimatedRowView: NSTableRowView {

    // MARK: - Tunables (from UX spec §1, §2, §4)

    /// How the animation reads visually + temporally. Three preset
    /// flavours map to the spec's three categories:
    ///   - `.appear` — generic "new item" tint (sidebar Session add,
    ///     outline Turn add). Strongest of the three.
    ///   - `.streamingAppear` — weaker tint for Step rows that arrive
    ///     mid-stream; the user is already looking at the outline so
    ///     the cue can be subtler.
    ///   - `.reorder` — neutral fill instead of accent; movement
    ///     itself is the primary cue and the tint is a supporting
    ///     "look here" hint.
    enum Style {
        case appear
        case streamingAppear
        case reorder
    }

    // MARK: - State

    private var tintHostView: TintHostView?
    private var pendingStyle: Style?
    private var pendingSyncStart: CFTimeInterval?

    // MARK: - Init

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    // MARK: - Public API

    /// Schedule an animation to fire after the row is laid out.
    func scheduleAppearanceAnimation(style: Style, syncStart: CFTimeInterval?) {
        pendingStyle = style
        pendingSyncStart = syncStart
        // Defer to the next runloop tick — by then AppKit will have
        // placed the row view in the hierarchy and given it a real
        // frame. Trying to fire synchronously here loses to the row
        // view's zero-bounds-at-construction issue.
        DispatchQueue.main.async { [weak self] in
            self?.firePendingAnimation()
        }
    }

    // MARK: - NSTableRowView lifecycle

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // Safety-net retry — if `scheduleAppearanceAnimation` was
        // called before the row view had a window, the deferred
        // dispatch above may have run too early. This catches that
        // rare ordering on the first display.
        if pendingStyle != nil, window != nil, bounds.width > 0, bounds.height > 0 {
            firePendingAnimation()
        }
    }

    override func layout() {
        super.layout()
        tintHostView?.frame = bounds
        if pendingStyle != nil, window != nil, bounds.width > 0, bounds.height > 0 {
            firePendingAnimation()
        }
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        tintHostView?.layer?.removeAllAnimations()
        tintHostView?.removeFromSuperview()
        tintHostView = nil
        pendingStyle = nil
        pendingSyncStart = nil
    }

    // MARK: - Private

    private func firePendingAnimation() {
        guard let style = pendingStyle else { return }
        guard window != nil, bounds.width > 0, bounds.height > 0 else {
            // viewDidMoveToWindow / layout will retry once the row
            // view is placed in the hierarchy with a real frame.
            return
        }
        pendingStyle = nil
        let syncStart = pendingSyncStart
        pendingSyncStart = nil

        let host = ensureTintHost()
        guard let layer = host.layer else {
            // Layer-hosting init should make this unreachable; log
            // once if it happens so a future AppKit change is caught.
            LoggerService.shared.warning(
                "LupenAnimatedRowView: TintHostView has no layer — animation skipped",
                context: "Animation"
            )
            return
        }

        let tintColor = Self.resolveTintColor(style: style, in: effectiveAppearance)
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion

        if reduceMotion {
            playReduceMotionFlash(on: layer, color: tintColor)
        } else {
            playMotionAnimation(
                on: layer,
                color: tintColor,
                style: style,
                syncStart: syncStart
            )
        }
    }

    private func ensureTintHost() -> TintHostView {
        if let existing = tintHostView {
            existing.frame = bounds
            return existing
        }
        let host = TintHostView(frame: bounds)
        host.autoresizingMask = [.width, .height]
        // Add as a subview — last-added = top of the subview stack =
        // composited on top of all cell views. The subview's layer
        // is created in `TintHostView.init` (layer-hosting mode), so
        // AppKit's lazy `wantsLayer` realisation timing doesn't
        // matter.
        addSubview(host)
        tintHostView = host
        return host
    }

    private func playMotionAnimation(
        on layer: CALayer,
        color: NSColor,
        style: Style,
        syncStart: CFTimeInterval?
    ) {
        layer.backgroundColor = color.cgColor

        let timing = Self.timingFor(style: style)
        let total = Double(timing.fadeInMs + timing.holdMs + timing.fadeOutMs)

        let anim = CAKeyframeAnimation(keyPath: "opacity")
        anim.values = [0.0, 1.0, 1.0, 0.0]
        anim.keyTimes = [
            0.0,
            NSNumber(value: Double(timing.fadeInMs) / total),
            NSNumber(value: Double(timing.fadeInMs + timing.holdMs) / total),
            1.0
        ]
        anim.timingFunctions = [
            CAMediaTimingFunction(name: .easeOut),
            CAMediaTimingFunction(name: .linear),
            CAMediaTimingFunction(controlPoints: 0.4, 0.0, 0.2, 1.0)
        ]
        anim.duration = total / 1000.0
        anim.fillMode = .both
        anim.isRemovedOnCompletion = false
        anim.beginTime = syncStart ?? CACurrentMediaTime()

        layer.add(anim, forKey: "lupenAppearance")

        // Cleanup based on the animation's end relative to *now* so a
        // late-arriving sibling that joined a coalesce burst still
        // gets its full fade-out before the host view tears down.
        let timeUntilEnd = (anim.beginTime - CACurrentMediaTime()) + anim.duration + 0.1
        let delaySeconds = max(0.1, timeUntilEnd)
        DispatchQueue.main.asyncAfter(deadline: .now() + delaySeconds) { [weak self, weak host = tintHostView] in
            guard let self, let host, host === self.tintHostView else { return }
            host.removeFromSuperview()
            self.tintHostView = nil
        }
    }

    private func playReduceMotionFlash(on layer: CALayer, color: NSColor) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.opacity = 1
        layer.backgroundColor = color.cgColor
        CATransaction.commit()

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self, weak host = tintHostView] in
            guard let self, let host, host === self.tintHostView else { return }
            host.removeFromSuperview()
            self.tintHostView = nil
        }
    }

    // MARK: - Color + timing resolution

    private static func resolveTintColor(style: Style, in appearance: NSAppearance) -> NSColor {
        let isDark = appearance.bestMatch(
            from: [.darkAqua, .vibrantDark, .accessibilityHighContrastDarkAqua, .accessibilityHighContrastVibrantDark]
        ) != nil

        // Subtle accent wash: a row appearing or streaming in gets a
        // brief controlAccentColor tint; a reorder uses the system's
        // appearance-aware fill. Kept under HIG's "subtle accent"
        // threshold so the cue reads as "something changed" without
        // pulling click attention.
        switch style {
        case .appear:
            return NSColor.controlAccentColor.withAlphaComponent(isDark ? 0.22 : 0.18)
        case .streamingAppear:
            return NSColor.controlAccentColor.withAlphaComponent(isDark ? 0.16 : 0.12)
        case .reorder:
            // `quaternarySystemFill` already carries an appearance-aware
            // base alpha, so no per-mode adjustment.
            return NSColor.quaternarySystemFill
        }
    }

    private struct Timing {
        let fadeInMs: Int
        let holdMs: Int
        let fadeOutMs: Int
    }

    private static func timingFor(style: Style) -> Timing {
        // Fade in, hold, fade out — kept short (640 ms total) so the
        // accent reads as a glance-level cue, well inside HIG's "subtle
        // accent" upper bound (~1 s).
        switch style {
        case .appear, .streamingAppear:
            return Timing(fadeInMs: 140, holdMs: 80, fadeOutMs: 420)
        case .reorder:
            return Timing(fadeInMs: 80, holdMs: 80, fadeOutMs: 420)
        }
    }
}

// MARK: - Layer-hosting subview

/// Tiny `NSView` whose only job is to host one `CALayer` we control
/// outright. Layer is assigned in `init` (layer-hosting mode) so
/// AppKit's lazy `wantsLayer` realisation never races with our
/// CAAnimation. The view's `autoresizingMask` keeps it sized to its
/// superview's bounds, so a row-height change tracks automatically.
@MainActor
private final class TintHostView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        // Layer-hosting: assigning `layer` BEFORE `wantsLayer = true`
        // tells AppKit "I own this layer, don't manage it for me."
        // This is the documented escape hatch for code that needs
        // direct CALayer access without the lazy creation timing
        // surprises of layer-backed mode.
        let l = CALayer()
        l.opacity = 0
        l.backgroundColor = NSColor.clear.cgColor
        self.layer = l
        self.wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    // Hit-testing pass-through — clicks fall to whatever cell is
    // beneath us. Otherwise the user couldn't select a row that's
    // mid-fade.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
