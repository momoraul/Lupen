import AppKit

/// Slim find bar shown atop the Conversation detail (D-3). A search field +
/// match counter + prev/next + close. It owns no find logic — it reports user
/// intent through closures and the host (`ConversationDetailView`) drives the
/// match model and highlighting.
///
/// Keyboard: Return = next, Shift+Return = previous, Esc = close. ⌘G / ⇧⌘G are
/// handled by the menu → `DetailViewController` while the bar is open.
@MainActor
final class ConversationFindBar: NSView, NSSearchFieldDelegate {

    private let field = NSSearchField()
    private let countLabel = NSTextField(labelWithString: "")
    private let prevButton = NSButton()
    private let nextButton = NSButton()
    private let closeButton = NSButton()

    /// Fired on every keystroke with the live query.
    var onQueryChanged: ((String) -> Void)?
    var onNext: (() -> Void)?
    var onPrevious: (() -> Void)?
    var onClose: (() -> Void)?

    static let barHeight: CGFloat = 36

    var query: String { field.stringValue }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        setup()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func setup() {
        field.placeholderString = "Find in conversation"
        field.delegate = self
        field.sendsWholeSearchString = false
        field.focusRingType = .none
        field.controlSize = .small
        field.font = .systemFont(ofSize: 12)

        countLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        countLabel.textColor = .secondaryLabelColor
        countLabel.alignment = .right
        countLabel.setContentHuggingPriority(.required, for: .horizontal)
        countLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        configureIconButton(prevButton, symbol: "chevron.up", tip: "Previous match (⇧⌘G)", action: #selector(prevClicked))
        configureIconButton(nextButton, symbol: "chevron.down", tip: "Next match (⌘G)", action: #selector(nextClicked))
        configureIconButton(closeButton, symbol: "xmark", tip: "Close (Esc)", action: #selector(closeClicked))

        let stack = NSStackView(views: [field, countLabel, prevButton, nextButton, closeButton])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        let separator = NSBox()
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false
        addSubview(separator)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            field.widthAnchor.constraint(greaterThanOrEqualToConstant: 180),

            separator.leadingAnchor.constraint(equalTo: leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: trailingAnchor),
            separator.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    private func configureIconButton(_ button: NSButton, symbol: String, tip: String, action: Selector) {
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tip)
        button.bezelStyle = .accessoryBar
        button.isBordered = false
        button.imagePosition = .imageOnly
        button.toolTip = tip
        button.target = self
        button.action = action
        button.setContentHuggingPriority(.required, for: .horizontal)
    }

    /// Make the search field the first responder and select its text.
    func focusField() {
        window?.makeFirstResponder(field)
        field.selectText(nil)
    }

    /// Update the "current/total" counter. `current` is a 0-based index.
    func setCount(current: Int?, total: Int) {
        if total == 0 {
            countLabel.stringValue = query.isEmpty ? "" : "No matches"
        } else {
            countLabel.stringValue = "\((current ?? 0) + 1)/\(total)"
        }
        prevButton.isEnabled = total > 0
        nextButton.isEnabled = total > 0
    }

    // MARK: - Actions

    @objc private func prevClicked() { onPrevious?() }
    @objc private func nextClicked() { onNext?() }
    @objc private func closeClicked() { onClose?() }

    // MARK: - NSSearchFieldDelegate

    func controlTextDidChange(_ obj: Notification) {
        onQueryChanged?(field.stringValue)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        switch commandSelector {
        case #selector(NSResponder.insertNewline(_:)):
            onNext?()
            return true
        case #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)):
            onPrevious?()                       // Shift+Return
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            onClose?()                          // Esc
            return true
        default:
            return false
        }
    }
}
