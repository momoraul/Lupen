import AppKit

/// Stand-in shown where the detail pane normally sits while it lives in
/// its own window.
///
/// **Why a strip instead of collapsing the space entirely** — Lupen is a
/// menu-bar app the user keeps switching away from, so a detached window
/// spends a lot of its life behind another app. Leaving a blank gap where
/// the pane used to be reads as "the panel disappeared" rather than "the
/// panel moved", and the only ways back would be a menu item or hunting
/// for the window. A visible label plus a Put Back button keeps the
/// return path in the place the user is already looking.
///
/// Height is `DashboardSplitViewController.detailMinimizedHeight` — the
/// same 38pt the pane already collapses to for the minimize toggle, so no
/// new geometry constant enters the layout.
@MainActor
final class DetachedDetailPlaceholderView: NSView {

    private let label = NSTextField(labelWithString: "Detail is in a separate window")
    private let putBackButton = NSButton()
    private let onPutBack: () -> Void

    init(onPutBack: @escaping () -> Void) {
        self.onPutBack = onPutBack
        super.init(frame: .zero)
        setup()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func setup() {
        label.font = .systemFont(ofSize: 11)
        label.textColor = .secondaryLabelColor
        // `labelWithString:` clips mid-glyph by default; ellipsize instead
        // if the pane is ever narrow enough to run out of room.
        label.usesSingleLineMode = true
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false

        putBackButton.bezelStyle = .accessoryBarAction
        putBackButton.controlSize = .regular
        putBackButton.isBordered = true
        putBackButton.imagePosition = .imageOnly
        putBackButton.toolTip = DetailPaneDetachStrings.putBackFromDashboardTooltip
        putBackButton.setAccessibilityLabel(DetailPaneDetachStrings.putBackAccessibilityLabel)
        putBackButton.image = DetailPaneDetachStrings.reattachSymbol(tint: .controlAccentColor)
        putBackButton.target = self
        putBackButton.action = #selector(putBackClicked)
        putBackButton.translatesAutoresizingMaskIntoConstraints = false

        addSubview(label)
        addSubview(putBackButton)

        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: DetailStyles.horizontalInset),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),

            putBackButton.trailingAnchor.constraint(
                equalTo: trailingAnchor, constant: -DetailStyles.horizontalInset
            ),
            putBackButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            putBackButton.widthAnchor.constraint(equalToConstant: 28),
            putBackButton.heightAnchor.constraint(equalToConstant: 28),

            // Never let the label push the button off the edge in a narrow pane.
            label.trailingAnchor.constraint(lessThanOrEqualTo: putBackButton.leadingAnchor, constant: -12),
        ])
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        // Belt-and-suspenders. `paletteColors` keeps the `NSColor` object
        // and resolves it at draw time, so a dynamic system colour already
        // follows the appearance — unlike a colour rasterized into a
        // bitmap. This button is never re-rendered by anything else
        // though, so it re-renders here rather than depending on that.
        putBackButton.image = DetailPaneDetachStrings.reattachSymbol(tint: .controlAccentColor)
    }

    @objc private func putBackClicked() {
        onPutBack()
    }
}
