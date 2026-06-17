import AppKit

/// Attachment manifest for the currently selected Step or Turn. Reads
/// `[AttachmentRef]` produced by `AttachmentResolver` (per Step) or
/// `Turn.allAttachments` (aggregated de-duplicated).
///
/// Rows are grouped by `AttachmentRef.Origin` into sections:
///
///   • Inline images
///   • Attached images
///   • Prompt mentions
///   • Tool inputs
///   • Tool outputs
///   • URLs                   (any kind=url regardless of origin)
///   • Mentioned in reply
///
/// Each row supports:
///   - Primary click       → reveal in Finder (`open -R`) or open URL.
///   - Context menu        → Reveal in Finder / Copy.
///   - ⌘C over a row       → Copy locator.
///
/// Mirror the Finder / Xcode breadcrumb idiom: icon + emphasized name
/// + muted subline (path or "(embedded in prompt)" / "Write · /path").
/// Inline-image rows suppress the chevron because they have no file
/// destination to reveal.
@MainActor
final class AttachmentsDetailView: NSView {

    // MARK: - Public API

    /// Whether the current manifest came from a single Step or a full
    /// Turn aggregate. Only affects the empty-state string so the
    /// user knows which scope they're looking at.
    enum DisplayContext {
        case step
        case turn
    }

    /// Bytes + rendered image + declared media type for an inline
    /// image. The preview popover needs all three:
    ///   - `image` for the `NSImageView`.
    ///   - `rawBytes` so the Save button writes the **original** PNG
    ///     / JPEG bytes rather than a re-encoded copy that could
    ///     lose metadata (ICC profile, EXIF) or shift colour / size.
    ///   - `mediaType` to pick the default file extension in the
    ///     save panel ("image/png" → `.png`, etc.).
    struct InlineImagePayload {
        let image: NSImage
        let rawBytes: Data
        let mediaType: String?
    }

    /// Resolves an `.inlineImage` ref into a preview-able payload.
    /// Called when the user clicks an inline row — the view knows
    /// nothing about session/step plumbing, so the host
    /// (`DetailViewController`) supplies a closure that can reach
    /// the JSONL bytes. `nil` return = silent no-op (preview is
    /// skipped but the rest of the row stays interactive).
    typealias InlineImageProvider = (AttachmentRef) -> InlineImagePayload?

    /// Replaces the view's manifest. Re-renders the table, section
    /// group rows included, and flips to the empty state if
    /// `attachments` is empty.
    ///
    /// `inlineImageProvider` is captured for the lifetime of this
    /// manifest — passing `nil` disables preview on inline image
    /// rows (click becomes a no-op). The legacy 3-channel
    /// `configure` variant calls this with `nil` provider because it
    /// predates the preview feature.
    func configure(
        attachments: [AttachmentRef],
        context: DisplayContext,
        inlineImageProvider: InlineImageProvider? = nil
    ) {
        self.displayContext = context
        self.inlineImageProvider = inlineImageProvider
        rebuildRows(from: attachments)
        emptyLabel.stringValue = context == .turn
            ? "No attachments in this turn"
            : "No attachments in this step"
        showEmptyState(rows.isEmpty)
    }

    func clear() {
        rows = []
        tableView.reloadData()
        showEmptyState(true)
    }

    /// Backwards-compat shim for callers still driving the old
    /// three-channel signature (test code mostly). Wraps inputs into
    /// ad-hoc `AttachmentRef`s using `promptImageMeta` /
    /// `inlinePromptImage` / `promptTextMention` origins, which
    /// matches the pre-refactor UI behaviour exactly.
    ///
    /// New production callers use `configure(attachments:context:)`.
    func configure(
        inlineImages: [ImageRef],
        imageSourcePaths: [String],
        mentionedFilePaths: [String]
    ) {
        var refs: [AttachmentRef] = []
        for path in imageSourcePaths {
            refs.append(AttachmentRef(
                kind: .image, origin: .promptImageMeta, locator: path
            ))
        }
        for (idx, image) in inlineImages.enumerated() {
            let key = "#inline:\(idx):\(image.mediaType ?? "image")"
            refs.append(AttachmentRef(
                kind: .inlineImage, origin: .inlinePromptImage,
                locator: key, mediaType: image.mediaType
            ))
        }
        for path in mentionedFilePaths {
            // Mirror the old dedup rule: a path that appears in both
            // imageSourcePaths and mentionedFilePaths kept only the
            // .image (now .promptImageMeta) row. Skip duplicates here
            // to preserve test expectations.
            if refs.contains(where: { $0.locator == path }) { continue }
            refs.append(AttachmentRef(
                kind: .file, origin: .promptTextMention, locator: path
            ))
        }
        configure(attachments: refs, context: .step)
    }

    /// Test hook — returns only the **data rows** (attachments),
    /// with section-header rows filtered out. Legacy tests predate
    /// the sectioned layout and were written against a flat row list;
    /// this accessor keeps them stable. Use `allRowsForTesting` if a
    /// newer test needs to assert the header layout too.
    var rowsForTesting: [Row] {
        rows.filter { row in
            if case .sectionHeader = row.payload { return false }
            return true
        }
    }

    /// Test hook returning every rendered row including group
    /// headers, in visual order. Used by tests that assert the
    /// sectioned layout explicitly.
    var allRowsForTesting: [Row] { rows }

    // MARK: - Row model

    /// A single visible row in the table — either a section header
    /// (non-interactive, group-row style) or an attachment row bound
    /// to an `AttachmentRef`.
    struct Row: Equatable {
        enum Payload: Equatable {
            case sectionHeader(String)
            case attachment(AttachmentRef)
        }

        enum Kind: Equatable {
            case image
            case inlineImage
            case file
        }

        let payload: Payload

        /// Legacy accessor — returns the underlying ref's kind mapped
        /// to the old three-value enum so `AttachmentsDetailViewTests`
        /// (which checks `.image / .inlineImage / .file`) keeps
        /// working without being rewritten. Headers map to `.file` —
        /// tests never read `kind` on a header, so the mapping is
        /// irrelevant for them.
        var kind: Kind {
            switch payload {
            case .sectionHeader:
                return .file
            case .attachment(let ref):
                switch ref.kind {
                case .image:        return .image
                case .inlineImage:  return .inlineImage
                case .file, .directory, .url: return .file
                }
            }
        }

        /// Legacy accessor — the file path / URL / synthetic inline
        /// key. Headers return an empty string (never read by tests).
        var path: String {
            switch payload {
            case .sectionHeader:
                return ""
            case .attachment(let ref):
                return ref.locator
            }
        }

        var mediaType: String? {
            if case .attachment(let ref) = payload { return ref.mediaType }
            return nil
        }

        var displayName: String {
            switch payload {
            case .sectionHeader(let title):
                return title
            case .attachment(let ref):
                switch ref.kind {
                case .inlineImage:
                    return "Inline image"
                case .url:
                    return shortURLName(ref.locator)
                case .directory:
                    return (ref.locator as NSString).lastPathComponent.isEmpty
                        ? ref.locator
                        : (ref.locator as NSString).lastPathComponent
                case .image, .file:
                    return (ref.locator as NSString).lastPathComponent
                }
            }
        }

        static func == (lhs: Row, rhs: Row) -> Bool {
            lhs.payload == rhs.payload
        }
    }

    // MARK: - UI

    private let scrollView = NSScrollView()
    private let tableView = NSTableView()

    private let emptyStateView = NSView()
    private let emptyImageView = NSImageView()
    private let emptyLabel = NSTextField(labelWithString: "")

    private var rows: [Row] = []
    private var displayContext: DisplayContext = .step
    private var inlineImageProvider: InlineImageProvider?
    /// Retained for the duration of an active inline-image preview so
    /// the popover doesn't dismiss itself the moment we hand it off.
    private var activePreviewPopover: NSPopover?

    // MARK: - Init

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupTable()
        setupEmptyState()
        layoutSubviews()
        showEmptyState(true)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    // MARK: - Setup

    private func setupTable() {
        tableView.dataSource = self
        tableView.delegate = self
        tableView.headerView = nil
        // Height varies between section-header rows (22pt, small) and
        // data rows (36pt) — delegate supplies per-row height.
        tableView.rowHeight = 36
        tableView.style = .inset
        tableView.allowsMultipleSelection = false
        tableView.allowsEmptySelection = true
        tableView.gridStyleMask = []
        tableView.intercellSpacing = NSSize(width: 0, height: 0)
        tableView.target = self
        tableView.action = #selector(tableRowClicked)
        tableView.doubleAction = #selector(tableRowClicked)
        tableView.menu = buildContextMenu()

        let column = NSTableColumn(identifier: .init("AttachmentCell"))
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)

        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
    }

    private func setupEmptyState() {
        if let img = NSImage(systemSymbolName: "paperclip", accessibilityDescription: nil) {
            let config = NSImage.SymbolConfiguration(pointSize: 24, weight: .thin)
            emptyImageView.image = img.withSymbolConfiguration(config)
            emptyImageView.contentTintColor = .tertiaryLabelColor
        }
        emptyLabel.stringValue = "No attachments in this step"
        emptyLabel.font = .systemFont(ofSize: 11)
        emptyLabel.textColor = .tertiaryLabelColor
        emptyLabel.alignment = .center
    }

    private func layoutSubviews() {
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        emptyStateView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scrollView)
        addSubview(emptyStateView)

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),

            emptyStateView.topAnchor.constraint(equalTo: topAnchor),
            emptyStateView.leadingAnchor.constraint(equalTo: leadingAnchor),
            emptyStateView.trailingAnchor.constraint(equalTo: trailingAnchor),
            emptyStateView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        let stack = NSStackView(views: [emptyImageView, emptyLabel])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        emptyStateView.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: emptyStateView.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: emptyStateView.centerYAnchor),
        ])
    }

    // MARK: - Row building (section grouping)

    /// Groups refs by `Origin` into the documented section order and
    /// builds an interleaved [header, rows, header, rows, …] array.
    /// Section headers are only emitted for non-empty sections so the
    /// table stays dense — a Step with only prompt images doesn't
    /// show a "Tool inputs" header above an empty stretch.
    ///
    /// The special `.url` kind is lifted out of `toolInput` so URLs
    /// group under one heading even though they share the origin with
    /// file tool inputs. Files under `.toolInput` stay where they are.
    private func rebuildRows(from refs: [AttachmentRef]) {
        var inlineImages: [AttachmentRef] = []
        var imageMetas: [AttachmentRef] = []
        var promptMentions: [AttachmentRef] = []
        var toolInputs: [AttachmentRef] = []
        var toolOutputs: [AttachmentRef] = []
        var urls: [AttachmentRef] = []
        var replyMentions: [AttachmentRef] = []

        for ref in refs {
            if ref.kind == .url {
                urls.append(ref)
                continue
            }
            switch ref.origin {
            case .inlinePromptImage: inlineImages.append(ref)
            case .promptImageMeta:   imageMetas.append(ref)
            case .promptTextMention: promptMentions.append(ref)
            case .toolInput:         toolInputs.append(ref)
            case .toolOutput:        toolOutputs.append(ref)
            case .replyMention:      replyMentions.append(ref)
            }
        }

        var built: [Row] = []
        let sections: [(String, [AttachmentRef])] = [
            ("Inline images", inlineImages),
            ("Attached images", imageMetas),
            ("Prompt mentions", promptMentions),
            ("Tool inputs", toolInputs),
            ("Tool outputs", toolOutputs),
            ("URLs", urls),
            ("Mentioned in reply", replyMentions),
        ]
        for (title, group) in sections where !group.isEmpty {
            built.append(Row(payload: .sectionHeader(title)))
            for ref in group {
                built.append(Row(payload: .attachment(ref)))
            }
        }
        rows = built
        tableView.reloadData()
    }

    private func showEmptyState(_ show: Bool) {
        emptyStateView.isHidden = !show
        scrollView.isHidden = show
    }

    // MARK: - Actions

    @objc private func tableRowClicked() {
        let row = tableView.clickedRow
        guard row >= 0, row < rows.count else { return }
        handleActivate(rows[row])
    }

    private func handleActivate(_ row: Row) {
        guard case .attachment(let ref) = row.payload else { return }
        switch ref.kind {
        case .inlineImage:
            // No file to reveal, but we can fetch the base64 bytes
            // from the owning Step's raw JSONL line and show a
            // popover preview so the user at least gets to *see* the
            // attached image. If the host didn't provide a loader
            // (legacy callers), fall back to a silent no-op.
            presentInlineImagePreview(for: ref)
        case .url:
            if let url = URL(string: ref.locator) {
                NSWorkspace.shared.open(url)
            }
        case .image, .file, .directory:
            revealInFinder(path: ref.locator)
        }
    }

    /// Pops a small image viewer over the clicked inline-image row.
    /// Sized to the image's natural dimensions, capped at 480×480 so
    /// a very large screenshot doesn't blow past the detail pane.
    ///
    /// The popover contains a `Save…` button that opens `NSSavePanel`
    /// so the user can write the original (un-re-encoded) bytes to a
    /// path of their choosing. Default filename derives from the
    /// owning locator index and the declared media type.
    private func presentInlineImagePreview(for ref: AttachmentRef) {
        guard let provider = inlineImageProvider,
              let payload = provider(ref) else { return }

        // Look up the visual row we clicked so the popover anchors
        // under it. Fall back to self (the tab view) if the row isn't
        // on screen.
        let clickedRow = tableView.clickedRow
        let anchorView: NSView
        let anchorRect: NSRect
        if clickedRow >= 0,
           let cell = tableView.view(atColumn: 0, row: clickedRow, makeIfNecessary: false) {
            anchorView = cell
            anchorRect = cell.bounds
        } else {
            anchorView = self
            anchorRect = bounds
        }

        let imageView = NSImageView()
        imageView.image = payload.image
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.imageFrameStyle = .none
        imageView.translatesAutoresizingMaskIntoConstraints = false

        let maxSide: CGFloat = 480
        let size = payload.image.size
        let scale = min(1.0, maxSide / max(size.width, size.height, 1))
        let w = max(160, size.width * scale)
        let h = max(120, size.height * scale)

        // Save button — writes `payload.rawBytes` verbatim (no
        // NSImage round-trip) so the exported file matches what
        // Claude Code stored in JSONL.
        let saveButton = NSButton(title: "Save…", target: nil, action: nil)
        saveButton.bezelStyle = .rounded
        saveButton.controlSize = .regular
        saveButton.keyEquivalent = "s"
        saveButton.keyEquivalentModifierMask = .command
        saveButton.translatesAutoresizingMaskIntoConstraints = false

        let host = InlineImagePreviewHost(payload: payload, locator: ref.locator)
        saveButton.target = host
        saveButton.action = #selector(InlineImagePreviewHost.saveTapped(_:))

        // Byte-size caption — a quiet metadata hint under the image
        // so the user can tell a 10 KB screenshot from a 4 MB one
        // before they hit Save.
        let sizeLabel = NSTextField(labelWithString: Self.formatByteSize(payload.rawBytes.count))
        sizeLabel.font = .systemFont(ofSize: 10, weight: .regular)
        sizeLabel.textColor = .tertiaryLabelColor
        sizeLabel.translatesAutoresizingMaskIntoConstraints = false

        let container = NSView()
        container.addSubview(imageView)
        container.addSubview(sizeLabel)
        container.addSubview(saveButton)
        NSLayoutConstraint.activate([
            imageView.topAnchor.constraint(equalTo: container.topAnchor, constant: 8),
            imageView.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 8),
            imageView.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -8),
            imageView.widthAnchor.constraint(equalToConstant: w),
            imageView.heightAnchor.constraint(equalToConstant: h),

            sizeLabel.topAnchor.constraint(equalTo: imageView.bottomAnchor, constant: 6),
            sizeLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 10),

            saveButton.topAnchor.constraint(equalTo: imageView.bottomAnchor, constant: 4),
            saveButton.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -8),
            saveButton.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -8),

            sizeLabel.centerYAnchor.constraint(equalTo: saveButton.centerYAnchor),
        ])

        let contentVC = NSViewController()
        contentVC.view = container

        let popover = NSPopover()
        popover.contentViewController = contentVC
        popover.behavior = .transient
        popover.animates = true
        // Strong-retain the host so the button target isn't released
        // the moment we return — NSPopover keeps the content VC
        // alive but the button's target reference is weak.
        host.popover = popover
        objc_setAssociatedObject(popover, &InlineImagePreviewHost.associationKey, host, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        activePreviewPopover = popover
        popover.show(relativeTo: anchorRect, of: anchorView, preferredEdge: .maxX)
    }

    /// "12.3 KB" / "1.8 MB" formatting for the byte-size caption.
    /// Uses `ByteCountFormatter` so the output respects the user's
    /// locale (".file" style gives base-10 units on macOS).
    private static func formatByteSize(_ bytes: Int) -> String {
        let f = ByteCountFormatter()
        f.countStyle = .file
        return f.string(fromByteCount: Int64(bytes))
    }

    @objc private func contextRevealInFinder() {
        guard let rowIndex = contextRow() else { return }
        handleActivate(rows[rowIndex])
    }

    @objc private func contextCopyPath() {
        guard let rowIndex = contextRow() else { return }
        let row = rows[rowIndex]
        guard case .attachment(let ref) = row.payload else { return }
        if ref.kind == .inlineImage {
            copyPath(row.displayName)
        } else {
            copyPath(ref.locator)
        }
    }

    override func keyDown(with event: NSEvent) {
        // ⌘C copies the selected row's locator.
        if event.modifierFlags.contains(.command),
           event.charactersIgnoringModifiers == "c",
           tableView.selectedRow >= 0,
           tableView.selectedRow < rows.count,
           case .attachment(let ref) = rows[tableView.selectedRow].payload {
            copyPath(ref.locator)
            return
        }
        super.keyDown(with: event)
    }

    private func contextRow() -> Int? {
        let row = tableView.clickedRow
        if row >= 0, row < rows.count,
           case .attachment = rows[row].payload {
            return row
        }
        let selected = tableView.selectedRow
        if selected >= 0, selected < rows.count,
           case .attachment = rows[selected].payload {
            return selected
        }
        return nil
    }

    private func revealInFinder(path: String) {
        let process = Process()
        process.launchPath = "/usr/bin/open"
        process.arguments = ["-R", path]
        try? process.run()
    }

    private func copyPath(_ path: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(path, forType: .string)
    }

    private func buildContextMenu() -> NSMenu {
        let menu = NSMenu()
        let reveal = NSMenuItem(
            title: "Reveal in Finder",
            action: #selector(contextRevealInFinder),
            keyEquivalent: ""
        )
        reveal.target = self
        menu.addItem(reveal)

        let copy = NSMenuItem(
            title: "Copy Path",
            action: #selector(contextCopyPath),
            keyEquivalent: "c"
        )
        copy.keyEquivalentModifierMask = .command
        copy.target = self
        menu.addItem(copy)
        return menu
    }
}

// MARK: - Table delegate/datasource

extension AttachmentsDetailView: NSTableViewDataSource, NSTableViewDelegate {

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row < rows.count else { return nil }
        let model = rows[row]
        switch model.payload {
        case .sectionHeader(let title):
            let id = NSUserInterfaceItemIdentifier("AttachmentSectionHeader")
            let header: AttachmentSectionHeaderView
            if let reused = tableView.makeView(withIdentifier: id, owner: nil) as? AttachmentSectionHeaderView {
                header = reused
            } else {
                header = AttachmentSectionHeaderView()
                header.identifier = id
            }
            header.configure(title: title)
            return header

        case .attachment(let ref):
            let id = NSUserInterfaceItemIdentifier("AttachmentCell")
            let cell: AttachmentRowCellView
            if let reused = tableView.makeView(withIdentifier: id, owner: nil) as? AttachmentRowCellView {
                cell = reused
            } else {
                cell = AttachmentRowCellView()
                cell.identifier = id
            }
            cell.configure(with: ref)
            return cell
        }
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        guard row < rows.count else { return 36 }
        if case .sectionHeader = rows[row].payload { return 22 }
        return 36
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        guard row < rows.count else { return false }
        if case .sectionHeader = rows[row].payload { return false }
        return true
    }

    func tableView(_ tableView: NSTableView, isGroupRow row: Int) -> Bool {
        guard row < rows.count else { return false }
        if case .sectionHeader = rows[row].payload { return true }
        return false
    }
}

// MARK: - Section header view

@MainActor
private final class AttachmentSectionHeaderView: NSTableCellView {
    private let label = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func setup() {
        label.translatesAutoresizingMaskIntoConstraints = false
        // Small-caps feel via tracking; AppKit group-row convention.
        label.font = .systemFont(ofSize: 10, weight: .semibold)
        label.textColor = .secondaryLabelColor
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -12),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    func configure(title: String) {
        label.stringValue = title.uppercased()
    }
}

// MARK: - Row cell view

@MainActor
final class AttachmentRowCellView: NSTableCellView {

    private let iconView = NSImageView()
    private let nameLabel = NSTextField(wrappingLabelWithString: "")
    private let pathLabel = NSTextField(wrappingLabelWithString: "")
    private let chevronView = NSImageView()

    // Test seam for the subline-width regression: the subline must span to
    // the chevron, not collapse to a short title's width. See
    // `AttachmentRowCellLayoutTests`.
    var sublineMaxXForTesting: CGFloat { pathLabel.frame.maxX }
    var titleMaxXForTesting: CGFloat { nameLabel.frame.maxX }
    var chevronMinXForTesting: CGFloat { chevronView.frame.minX }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupLayout()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func setupLayout() {
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.imageScaling = .scaleProportionallyUpOrDown

        nameLabel.translatesAutoresizingMaskIntoConstraints = false
        nameLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        nameLabel.textColor = .labelColor
        nameLabel.lineBreakMode = .byTruncatingMiddle
        nameLabel.maximumNumberOfLines = 1

        pathLabel.translatesAutoresizingMaskIntoConstraints = false
        pathLabel.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
        pathLabel.textColor = .tertiaryLabelColor
        pathLabel.lineBreakMode = .byTruncatingHead
        pathLabel.maximumNumberOfLines = 1

        chevronView.translatesAutoresizingMaskIntoConstraints = false
        if let chevron = NSImage(systemSymbolName: "chevron.right", accessibilityDescription: nil) {
            let config = NSImage.SymbolConfiguration(pointSize: 10, weight: .regular)
            chevronView.image = chevron.withSymbolConfiguration(config)
        }
        chevronView.contentTintColor = .tertiaryLabelColor

        addSubview(iconView)
        addSubview(nameLabel)
        addSubview(pathLabel)
        addSubview(chevronView)

        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 18),
            iconView.heightAnchor.constraint(equalToConstant: 18),

            nameLabel.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 10),
            nameLabel.topAnchor.constraint(equalTo: topAnchor, constant: 5),
            nameLabel.trailingAnchor.constraint(lessThanOrEqualTo: chevronView.leadingAnchor, constant: -8),

            pathLabel.leadingAnchor.constraint(equalTo: nameLabel.leadingAnchor),
            pathLabel.topAnchor.constraint(equalTo: nameLabel.bottomAnchor, constant: 1),
            // Pin the subline to the chevron, NOT to nameLabel: nameLabel's
            // trailing is a loose `<=` so it hugs short titles ("src",
            // "Inline image"). Tying pathLabel to it collapsed the subline to
            // the title's width, head-truncating "…/src" → "…c" even with a
            // wide pane. The subline owns the full row width on its own.
            pathLabel.trailingAnchor.constraint(equalTo: chevronView.leadingAnchor, constant: -8),

            chevronView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            chevronView.centerYAnchor.constraint(equalTo: centerYAnchor),
            chevronView.widthAnchor.constraint(equalToConstant: 10),
            chevronView.heightAnchor.constraint(equalToConstant: 14),
        ])
    }

    func configure(with ref: AttachmentRef) {
        // Icon + tint driven by Kind; tints follow macOS convention
        // (blue for images/files, secondary for directories, accent
        // for URLs).
        let symbolName: String
        let tint: NSColor
        switch ref.kind {
        case .image, .inlineImage:
            symbolName = "photo"
            tint = .systemBlue
        case .file:
            symbolName = "doc.text"
            tint = .secondaryLabelColor
        case .directory:
            symbolName = "folder"
            tint = .secondaryLabelColor
        case .url:
            symbolName = "link"
            tint = .controlAccentColor
        }
        if let img = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil) {
            let config = NSImage.SymbolConfiguration(pointSize: 14, weight: .regular)
            iconView.image = img.withSymbolConfiguration(config)
        }
        iconView.contentTintColor = tint

        // Primary label: friendly filename / URL basename / "Inline image".
        nameLabel.stringValue = primaryName(for: ref)

        // Subline: file path, optionally prefixed with tool name
        // ("Write · /tmp/out.md") so the user can tell tool I/O apart
        // from plain mentions at a glance.
        let toolPrefix = ref.toolName.map { "\($0) · " } ?? ""
        switch ref.kind {
        case .inlineImage:
            let typePart = ref.mediaType.map { "\($0) " } ?? ""
            pathLabel.stringValue = "\(typePart)(embedded in prompt)"
            chevronView.isHidden = true
            toolTip = "Inline image attached to this prompt — no file on disk"
        case .url:
            pathLabel.stringValue = "\(toolPrefix)\(ref.locator)"
            chevronView.isHidden = false
            toolTip = ref.locator
        case .image, .file, .directory:
            pathLabel.stringValue = "\(toolPrefix)\(ref.locator)"
            chevronView.isHidden = false
            toolTip = ref.locator
        }
    }

    private func primaryName(for ref: AttachmentRef) -> String {
        switch ref.kind {
        case .inlineImage:
            return "Inline image"
        case .url:
            return shortURLName(ref.locator)
        case .directory:
            let name = (ref.locator as NSString).lastPathComponent
            return name.isEmpty ? ref.locator : name
        case .image, .file:
            return (ref.locator as NSString).lastPathComponent
        }
    }
}

/// NSButton target for the inline-image preview's Save button.
/// Lives as long as its owning `NSPopover` via `objc_setAssociatedObject`
/// — `NSButton.target` is a weak reference and would otherwise be
/// released the instant we return from `presentInlineImagePreview`,
/// leaving the button inert.
@MainActor
private final class InlineImagePreviewHost: NSObject {
    static var associationKey: UInt8 = 0

    let payload: AttachmentsDetailView.InlineImagePayload
    let locator: String
    weak var popover: NSPopover?

    init(payload: AttachmentsDetailView.InlineImagePayload, locator: String) {
        self.payload = payload
        self.locator = locator
    }

    @objc func saveTapped(_ sender: Any?) {
        let panel = NSSavePanel()
        panel.title = "Save Inline Image"
        panel.nameFieldStringValue = suggestedFilename()
        // Let the user pick any extension — we always write the raw
        // bytes, regardless. Don't filter allowedContentTypes so
        // e.g. a user who wants `.bin` can rename freely.
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false

        // Anchoring to the parent window gives the user a sheet
        // instead of a modal panel, which feels right for a
        // popover-triggered save. Fall back to modal run if no window
        // is available (shouldn't happen in practice).
        if let window = popover?.contentViewController?.view.window {
            panel.beginSheetModal(for: window) { [weak self] response in
                guard let self, response == .OK, let url = panel.url else { return }
                self.writeBytes(to: url)
            }
        } else {
            let response = panel.runModal()
            guard response == .OK, let url = panel.url else { return }
            writeBytes(to: url)
        }
    }

    private func suggestedFilename() -> String {
        // Locator shape: `#inline:<idx>:<mediaType>` — e.g.
        //   `#inline:0:image/png` → `inline-image-0.png`
        let idx = InlineImageLoader.imageIndex(fromLocator: locator) ?? 0
        let ext = extensionFor(mediaType: payload.mediaType) ?? "bin"
        return "inline-image-\(idx).\(ext)"
    }

    private func extensionFor(mediaType: String?) -> String? {
        guard let raw = mediaType?.lowercased() else { return nil }
        switch raw {
        case "image/png":                return "png"
        case "image/jpeg", "image/jpg":  return "jpg"
        case "image/gif":                return "gif"
        case "image/webp":               return "webp"
        case "image/heic":               return "heic"
        case "image/tiff":               return "tiff"
        case "image/bmp":                return "bmp"
        case "image/svg+xml":            return "svg"
        default:
            // Fallback: take whatever's after `image/`.
            if let slash = raw.lastIndex(of: "/"),
               raw[..<slash] == "image" {
                return String(raw[raw.index(after: slash)...])
            }
            return nil
        }
    }

    private func writeBytes(to url: URL) {
        do {
            try payload.rawBytes.write(to: url, options: .atomic)
            popover?.performClose(nil)
        } catch {
            // Surface the error as an alert; the file wasn't written
            // so leaving the popover open lets the user retry with a
            // different destination.
            let alert = NSAlert()
            alert.messageText = "Couldn't save image"
            alert.informativeText = error.localizedDescription
            alert.alertStyle = .warning
            alert.addButton(withTitle: "OK")
            if let window = popover?.contentViewController?.view.window {
                alert.beginSheetModal(for: window, completionHandler: nil)
            } else {
                alert.runModal()
            }
        }
    }
}

/// Trims a URL down to its host + last path component so the row
/// primary label stays scannable — the full URL lives in the subline.
private func shortURLName(_ urlString: String) -> String {
    if let url = URL(string: urlString), let host = url.host {
        let last = url.lastPathComponent
        return last.isEmpty || last == "/" ? host : "\(host)/\(last)"
    }
    return urlString
}
