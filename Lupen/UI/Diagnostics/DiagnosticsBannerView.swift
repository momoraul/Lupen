import AppKit

/// Compact clickable banner shown at the top of the status-bar dropdown
/// whenever `ParseDiagnostics.hasAnyIssues`. Tapping posts the
/// `.openParseDiagnostics` notification; `AppDelegate` opens the window.
///
/// Visibility is driven by the dropdown controller — this view knows
/// nothing about ParseDiagnostics directly so tests can stand it up in
/// isolation.
final class DiagnosticsBannerView: NSView {

    private let iconView = NSImageView()
    private let textLabel = NSTextField(labelWithString: "")
    private let chevronView = NSImageView()
    private let button = NSButton()

    override init(frame: NSRect) {
        super.init(frame: frame)
        setupSubviews()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    // MARK: - Configure

    /// Update the banner text and color for a given error/warning count.
    /// If both counts are 0 the banner should be hidden by the caller;
    /// this method doesn't perform visibility control.
    func configure(errors: Int, warnings: Int) {
        if errors > 0 {
            iconView.image = NSImage(systemSymbolName: "exclamationmark.circle.fill",
                                     accessibilityDescription: nil)
            iconView.contentTintColor = .systemRed
            textLabel.stringValue = errorSummary(errors: errors, warnings: warnings)
        } else if warnings > 0 {
            iconView.image = NSImage(systemSymbolName: "exclamationmark.triangle.fill",
                                     accessibilityDescription: nil)
            iconView.contentTintColor = .systemOrange
            textLabel.stringValue = warningSummary(warnings: warnings)
        } else {
            iconView.image = nil
            textLabel.stringValue = ""
        }
    }

    private func errorSummary(errors: Int, warnings: Int) -> String {
        let errorWord = errors == 1 ? "error" : "errors"
        if warnings == 0 {
            return "\(errors) parse \(errorWord) — open Diagnostics"
        }
        return "\(errors) \(errorWord), \(warnings) warning(s) — open Diagnostics"
    }

    private func warningSummary(warnings: Int) -> String {
        let word = warnings == 1 ? "warning" : "warnings"
        return "\(warnings) parse \(word) — open Diagnostics"
    }

    // MARK: - Setup

    private func setupSubviews() {
        wantsLayer = true
        layer?.cornerRadius = 8
        // Subtle tinted background — matches system warning affordances.
        layer?.backgroundColor = NSColor.systemOrange.withAlphaComponent(0.12).cgColor

        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 14, weight: .medium)

        textLabel.translatesAutoresizingMaskIntoConstraints = false
        textLabel.font = .systemFont(ofSize: 12, weight: .medium)
        textLabel.textColor = .labelColor
        textLabel.lineBreakMode = .byTruncatingTail
        textLabel.maximumNumberOfLines = 1

        chevronView.translatesAutoresizingMaskIntoConstraints = false
        chevronView.image = NSImage(systemSymbolName: "chevron.right",
                                    accessibilityDescription: nil)
        chevronView.contentTintColor = .tertiaryLabelColor
        chevronView.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 10, weight: .semibold)

        // Full-cover invisible button for the tap affordance.
        button.translatesAutoresizingMaskIntoConstraints = false
        button.isBordered = false
        button.title = ""
        button.target = self
        button.action = #selector(didTap)
        button.setButtonType(.momentaryChange)

        addSubview(iconView)
        addSubview(textLabel)
        addSubview(chevronView)
        addSubview(button)

        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 16),
            iconView.heightAnchor.constraint(equalToConstant: 16),

            textLabel.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 8),
            textLabel.trailingAnchor.constraint(equalTo: chevronView.leadingAnchor, constant: -8),
            textLabel.centerYAnchor.constraint(equalTo: centerYAnchor),

            chevronView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            chevronView.centerYAnchor.constraint(equalTo: centerYAnchor),
            chevronView.widthAnchor.constraint(equalToConstant: 10),
            chevronView.heightAnchor.constraint(equalToConstant: 10),

            // Button covers the entire banner for easy clicking.
            button.topAnchor.constraint(equalTo: topAnchor),
            button.leadingAnchor.constraint(equalTo: leadingAnchor),
            button.trailingAnchor.constraint(equalTo: trailingAnchor),
            button.bottomAnchor.constraint(equalTo: bottomAnchor),

            heightAnchor.constraint(equalToConstant: 32),
        ])
    }

    @objc private func didTap() {
        NotificationCenter.default.post(name: .openParseDiagnostics, object: nil)
    }
}
