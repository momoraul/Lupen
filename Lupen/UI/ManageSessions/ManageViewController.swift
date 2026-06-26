//
//  ManageViewController.swift
//  Lupen
//
//  Created by jaden on 2026/06/20.
//

import AppKit
import SwiftUI

/// Manage window body — top bar (provider/tab/search) + multi-column table
/// (header sort, row multi-selection) + Sessions-only inspector + bottom
/// collector bar. No classification badge/inline bar — classification only
/// surfaces via the delete alert (per user requirement).
final class ManageViewController: NSViewController {

    private struct Column {
        let id: String
        let title: String
        let width: CGFloat
        let sort: ManageRowSort?
        let rightAligned: Bool
        let flexible: Bool
    }
    private let columns: [Column] = [
        Column(id: "status", title: "", width: 32, sort: .status, rightAligned: false, flexible: false),
        Column(id: "project", title: "Project", width: 104, sort: .project, rightAligned: false, flexible: false),
        Column(id: "session", title: "Session", width: 200, sort: .session, rightAligned: false, flexible: true),
        Column(id: "created", title: "Created", width: 96, sort: .created, rightAligned: false, flexible: false),
        Column(id: "updated", title: "Updated", width: 96, sort: .updated, rightAligned: false, flexible: false),
        Column(id: "size", title: "Size", width: 90, sort: .size, rightAligned: true, flexible: false),
        Column(id: "files", title: "Files", width: 60, sort: .files, rightAligned: true, flexible: false),
    ]
    /// Minimum width the flexible (=session) column can shrink to. Never narrower.
    private let flexibleColumnMinWidth: CGFloat = 200

    private let store: ManageStore
    private let sessionResumer = SessionResumer()

    private let providerSeg = NSSegmentedControl(
        labels: [], trackingMode: .selectOne, target: nil, action: nil)
    private let scopeSeg = NSSegmentedControl(
        labels: ["Sessions", "Lupen Cache", "All Disk"], trackingMode: .selectOne, target: nil, action: nil)
    private let searchField = NSSearchField()
    private let scrollView = NSScrollView()
    private let tableView = ManageTableView()
    private let statusLabel = NSTextField(labelWithString: "")
    private let collectorBar = ManageDynamicBackgroundView()
    private let collectorLabel = NSTextField(labelWithString: "")
    private let clearButton = NSButton(title: "Clear Selection", target: nil, action: nil)
    private let trashButton = NSButton(title: "Move to Trash", target: nil, action: nil)
    private var inspectorHosting: NSHostingController<ManageInspectorView>!
    private var cacheHosting: NSHostingController<ManageCacheView>!
    private var inspectorWidth: NSLayoutConstraint!
    private var leftSeparator: NSView?

    private var cachedRows: [ManageRowModel] = []
    private var snackbar: NSView?
    private var pendingRestore: [ManageTrashService.RestoreEntry] = []
    private var indexingPoll: Timer?
    private var isRestoringSelection = false
    /// Don't run refresh until buildUI has created all views/constraints
    /// (setting sortDescriptors/delegate fires sortDescriptorsDidChange early).
    private var isReady = false

    private let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yy/MM/dd HH:mm"
        return formatter
    }()

    init(store: ManageStore) {
        self.store = store
        super.init(nibName: nil, bundle: nil)
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 1100, height: 680))
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        buildUI()
        store.onChange = { [weak self] in self?.refresh() }
        // load runs in viewDidAppear — so reopening the window reflects disk/index
        // changes (avoids stale state on reopen).
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        store.load()
    }

    override func viewWillDisappear() {
        super.viewWillDisappear()
        indexingPoll?.invalidate()
        indexingPoll = nil
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        // Re-fit the Session width whenever the table's available width changes
        // via window resize or inspector toggle (the 6 fixed columns stay put,
        // only Session grows and shrinks).
        adjustFlexibleColumnWidth()
    }

    // MARK: - Build

    private func buildUI() {
        providerSeg.target = self
        providerSeg.action = #selector(providerChanged)
        rebuildProviderSegments()

        scopeSeg.selectedSegment = 0
        scopeSeg.target = self
        scopeSeg.action = #selector(scopeChanged)

        searchField.placeholderString = "Search prompts…"
        searchField.target = self
        searchField.action = #selector(searchChanged)
        searchField.sendsWholeSearchString = false
        searchField.sendsSearchStringImmediately = true
        searchField.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let toolbar = NSStackView(views: [providerSeg, scopeSeg, NSView(), searchField])
        toolbar.orientation = .horizontal
        toolbar.spacing = 10
        toolbar.edgeInsets = NSEdgeInsets(top: 8, left: 14, bottom: 8, right: 14)
        toolbar.translatesAutoresizingMaskIntoConstraints = false
        toolbar.setHuggingPriority(.required, for: .vertical)

        // table (multi-column)
        tableView.allowsMultipleSelection = true
        tableView.usesAutomaticRowHeights = false
        tableView.rowHeight = 26
        tableView.style = .inset
        tableView.selectionHighlightStyle = .regular
        tableView.dataSource = self
        tableView.onDelete = { [weak self] in self?.performTrash(rows: self?.store.selectedRows ?? []) }
        tableView.target = self
        tableView.doubleAction = #selector(rowDoubleClicked)
        for column in columns {
            let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(column.id))
            col.title = column.title
            col.width = column.width
            col.minWidth = column.id == "status" ? 28 : 40
            if column.id == "status" {
                // Header text is empty for this column, so VoiceOver gets no meaning — assign a label.
                col.headerCell.setAccessibilityLabel("Status")
            }
            if column.sort != nil {
                col.sortDescriptorPrototype = NSSortDescriptor(key: column.id, ascending: true)
            }
            // Disable auto-resizing (.noColumnAutoresizing below) and recompute the
            // Session width directly in viewDidLayout. Allow only manual user drag.
            col.resizingMask = .userResizingMask
            tableView.addTableColumn(col)
        }
        // Unify the policy where only one column (Session) absorbs slack via explicit recompute.
        // Disable global auto-resizing like uniform/sequential (removes conflict with column masks)
        // and set Session width = available width − fixed column sum directly in viewDidLayout.
        tableView.columnAutoresizingStyle = .noColumnAutoresizing
        tableView.sortDescriptors = [NSSortDescriptor(key: "size", ascending: false)]
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        statusLabel.font = .systemFont(ofSize: 12)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.alignment = .center
        statusLabel.translatesAutoresizingMaskIntoConstraints = false

        cacheHosting = NSHostingController(rootView: ManageCacheView(
            store: store,
            onRebuild: { [weak self] in self?.confirmRebuild() },
            onClearSnapshots: { [weak self] in self?.confirmClearSnapshots() },
            onReveal: { [weak self] in self?.revealSupport() }
        ))
        addChild(cacheHosting)
        let cacheView = cacheHosting.view
        cacheView.translatesAutoresizingMaskIntoConstraints = false
        cacheView.isHidden = true

        let leftPane = NSView()
        leftPane.translatesAutoresizingMaskIntoConstraints = false
        leftPane.addSubview(scrollView)
        leftPane.addSubview(statusLabel)
        leftPane.addSubview(cacheView)
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: leftPane.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: leftPane.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: leftPane.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: leftPane.bottomAnchor),
            statusLabel.centerXAnchor.constraint(equalTo: leftPane.centerXAnchor),
            statusLabel.centerYAnchor.constraint(equalTo: leftPane.centerYAnchor),
            cacheView.topAnchor.constraint(equalTo: leftPane.topAnchor),
            cacheView.leadingAnchor.constraint(equalTo: leftPane.leadingAnchor),
            cacheView.trailingAnchor.constraint(equalTo: leftPane.trailingAnchor),
            cacheView.bottomAnchor.constraint(equalTo: leftPane.bottomAnchor),
        ])

        // inspector (Sessions tab only — width toggle)
        inspectorHosting = NSHostingController(rootView: ManageInspectorView(store: store, actions: makeActions()))
        addChild(inspectorHosting)
        let inspectorContainer = inspectorHosting.view
        inspectorContainer.translatesAutoresizingMaskIntoConstraints = false
        let leftSep = makeVerticalSeparator()
        leftSeparator = leftSep

        // collector
        collectorBar.fillColor = .windowBackgroundColor   // reinterpreted per mode in updateLayer
        collectorBar.translatesAutoresizingMaskIntoConstraints = false
        collectorLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        clearButton.target = self; clearButton.action = #selector(clearTapped); clearButton.bezelStyle = .rounded
        trashButton.target = self; trashButton.action = #selector(trashTapped); trashButton.bezelStyle = .rounded
        trashButton.contentTintColor = .systemRed
        let collectorStack = NSStackView(views: [collectorLabel, NSView(), clearButton, trashButton])
        collectorStack.orientation = .horizontal
        collectorStack.spacing = 10
        collectorStack.edgeInsets = NSEdgeInsets(top: 8, left: 14, bottom: 8, right: 14)
        collectorStack.translatesAutoresizingMaskIntoConstraints = false
        collectorBar.addSubview(collectorStack)
        NSLayoutConstraint.activate([
            collectorStack.leadingAnchor.constraint(equalTo: collectorBar.leadingAnchor),
            collectorStack.trailingAnchor.constraint(equalTo: collectorBar.trailingAnchor),
            collectorStack.topAnchor.constraint(equalTo: collectorBar.topAnchor),
            collectorStack.bottomAnchor.constraint(equalTo: collectorBar.bottomAnchor),
        ])

        let topSep = makeSeparator()
        let botSep = makeSeparator()
        for sub in [toolbar, topSep, leftPane, leftSep, inspectorContainer, botSep, collectorBar] {
            view.addSubview(sub)
        }

        inspectorWidth = inspectorContainer.widthAnchor.constraint(equalToConstant: 320)

        NSLayoutConstraint.activate([
            toolbar.topAnchor.constraint(equalTo: view.topAnchor),
            toolbar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            toolbar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            searchField.widthAnchor.constraint(greaterThanOrEqualToConstant: 200),

            topSep.heightAnchor.constraint(equalToConstant: 1),
            topSep.topAnchor.constraint(equalTo: toolbar.bottomAnchor),
            topSep.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            topSep.trailingAnchor.constraint(equalTo: view.trailingAnchor),

            leftPane.topAnchor.constraint(equalTo: topSep.bottomAnchor),
            leftPane.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            leftPane.bottomAnchor.constraint(equalTo: botSep.topAnchor),

            leftSep.topAnchor.constraint(equalTo: topSep.bottomAnchor),
            leftSep.bottomAnchor.constraint(equalTo: botSep.topAnchor),
            leftSep.leadingAnchor.constraint(equalTo: leftPane.trailingAnchor),
            leftSep.widthAnchor.constraint(equalToConstant: 1),

            inspectorContainer.topAnchor.constraint(equalTo: topSep.bottomAnchor),
            inspectorContainer.leadingAnchor.constraint(equalTo: leftSep.trailingAnchor),
            inspectorContainer.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            inspectorContainer.bottomAnchor.constraint(equalTo: botSep.topAnchor),
            inspectorWidth,

            botSep.heightAnchor.constraint(equalToConstant: 1),
            botSep.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            botSep.trailingAnchor.constraint(equalTo: view.trailingAnchor),

            collectorBar.topAnchor.constraint(equalTo: botSep.bottomAnchor),
            collectorBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            collectorBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            collectorBar.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            collectorBar.heightAnchor.constraint(equalToConstant: 44),
        ])
        // Wire the delegate only after all views/constraints are set — prevents the
        // sortDescriptors initialization above from firing sortDescriptorsDidChange
        // and touching nil (cacheHosting/inspectorWidth).
        tableView.delegate = self
        isReady = true
        refresh()
    }

    private func makeSeparator() -> NSView {
        let box = NSBox(); box.boxType = .separator
        box.translatesAutoresizingMaskIntoConstraints = false
        return box
    }
    private func makeVerticalSeparator() -> NSView { makeSeparator() }

    /// Sets the Session (flexible) column width to "table available width − fixed
    /// column sum". Computed against the actual content width (scrollView's
    /// contentSize, which excludes the .inset style insets and vertical scroller
    /// width), so Size/Files aren't truncated. If it goes negative, clamp to the
    /// minimum width (handled by horizontal scroll) to avoid clipping the right columns.
    private func adjustFlexibleColumnWidth() {
        guard isReady,
              let flexColumn = tableView.tableColumn(
                  withIdentifier: NSUserInterfaceItemIdentifier("session")) else { return }
        let available = scrollView.contentSize.width
        guard available > 0 else { return }
        let fixedSum = tableView.tableColumns.reduce(CGFloat.zero) { sum, col in
            col === flexColumn ? sum : sum + col.width
        }
        // The gap between columns (intercellSpacing) is also subtracted from the available width.
        let spacing = tableView.intercellSpacing.width * CGFloat(max(0, tableView.tableColumns.count - 1))
        let target = max(flexibleColumnMinWidth, available - fixedSum - spacing)
        if abs(flexColumn.width - target) > 0.5 { flexColumn.width = target }
    }

    // MARK: - Toolbar actions

    /// Populate the source switcher from the enabled sources (one segment
    /// each, labelled by name), selecting the current source.
    private func rebuildProviderSegments() {
        providerSeg.segmentCount = store.sources.count
        for (index, src) in store.sources.enumerated() {
            providerSeg.setLabel(src.name, forSegment: index)
        }
        if let index = store.sources.firstIndex(where: { $0.id == store.source.id }) {
            providerSeg.selectedSegment = index
        }
    }

    @objc private func providerChanged() {
        let index = providerSeg.selectedSegment
        guard store.sources.indices.contains(index) else { return }
        store.switchSource(store.sources[index])
    }
    @objc private func scopeChanged() {
        let scopes: [ManageScope] = [.sessions, .cache, .allDisk]
        store.scope = scopes[min(scopeSeg.selectedSegment, scopes.count - 1)]
        store.clearSelection()
        refresh()
    }
    @objc private func searchChanged() {
        store.searchText = searchField.stringValue
        refresh()
    }
    @objc private func clearTapped() {
        store.clearSelection()
        refresh()
    }
    @objc private func trashTapped() { performTrash(rows: store.selectedRows) }

    // MARK: - Row actions

    private func makeActions() -> ManageRowActions {
        ManageRowActions(
            resume: { [weak self] row in self?.resume(row) },
            reveal: { [weak self] row in self?.reveal(row) },
            openFolder: { [weak self] row in self?.openFolder(row) },
            openTerminal: { [weak self] row in self?.openTerminal(row) },
            copyCommand: { [weak self] row in self?.copyCommand(row) },
            export: { [weak self] row in self?.export(row) },
            trashRow: { [weak self] row in self?.performTrash(rows: [row]) },
            trashSelected: { [weak self] in self?.performTrash(rows: self?.store.selectedRows ?? []) }
        )
    }

    private func reveal(_ row: ManageRowModel) {
        guard let path = row.filePaths.first ?? row.projectPath else { return }
        runOpen(["-R", path])
    }
    private func openFolder(_ row: ManageRowModel) {
        guard let path = row.projectPath else { return }
        runOpen([path])
    }
    private func openTerminal(_ row: ManageRowModel) {
        guard let path = row.projectPath else { return }
        runOpen(["-a", "Terminal", path])
    }
    private func runOpen(_ args: [String]) {
        let process = Process()
        process.launchPath = "/usr/bin/open"
        process.arguments = args
        try? process.run()
    }
    private func resume(_ row: ManageRowModel) {
        guard let session = makeSession(row) else { return }
        do { try sessionResumer.resume(session: session) } catch { showActionError(error) }
    }
    private func copyCommand(_ row: ManageRowModel) {
        guard let session = makeSession(row) else { return }
        do { _ = try sessionResumer.copyResumeCommand(for: session) } catch { showActionError(error) }
    }
    private func export(_ row: ManageRowModel) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Export"
        panel.message = "Choose a folder to copy the session files into."
        guard panel.runModal() == .OK, let dest = panel.url else { return }
        do {
            for path in row.trashTargets {
                let src = URL(fileURLWithPath: path)
                try FileManager.default.copyItem(at: src, to: dest.appendingPathComponent(src.lastPathComponent))
            }
        } catch {
            // Conflict/permission/out-of-disk etc. — notify the user, same as other actions.
            showActionError(error)
        }
    }
    private func makeSession(_ row: ManageRowModel) -> Session? {
        guard row.kind == .session else { return nil }
        return Session(
            id: row.id, provider: row.provider, rawSessionId: row.rawSessionId ?? row.id,
            requests: [], projectPath: row.encodedProject ?? row.projectPath
        )
    }
    private func showActionError(_ error: Error) { NSAlert(error: error).runModal() }

    // MARK: - Deletion flow

    private func performTrash(rows: [ManageRowModel]) {
        guard !rows.isEmpty else { return }
        guard ManageDeletionPlanner.allDeletable(rows) else {
            let alert = NSAlert()
            alert.messageText = "Some items can't be deleted."
            alert.informativeText = "Blocked (auth/config, app state, outside the session area) or unclassified items can't be moved to Trash."
            alert.runModal()
            return
        }
        if ManageDeletionPlanner.friction(rows: rows) == .low {
            trashNow(rows)
            return
        }
        guard confirmDeletion(ManageDeletionPlanner.confirmCopy(rows: rows)) else { return }
        trashNow(rows)
    }

    private func trashNow(_ rows: [ManageRowModel]) {
        let attempted = rows.count
        Task { @MainActor in
            let outcome = await store.trash(rows: rows)
            showUndoSnackbar(outcome: outcome, attempted: attempted)
        }
    }

    private func confirmDeletion(_ copy: ManageDeletionPlanner.ConfirmCopy) -> Bool {
        let alert = NSAlert()
        alert.messageText = copy.title
        alert.informativeText = copy.body
        alert.alertStyle = .warning
        alert.addButton(withTitle: copy.confirmButton)
        alert.addButton(withTitle: "Cancel")
        guard copy.requiresTyping else {
            return alert.runModal() == .alertFirstButtonReturn
        }
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.placeholderString = "Type \(copy.typingToken) to continue"
        alert.accessoryView = field
        guard alert.runModal() == .alertFirstButtonReturn else { return false }
        if field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines) != copy.typingToken {
            let warn = NSAlert()
            warn.messageText = "Input didn't match — cancelled."
            warn.runModal()
            return false
        }
        return true
    }

    private func showUndoSnackbar(outcome: ManageTrashService.Outcome, attempted: Int) {
        snackbar?.removeFromSuperview()
        guard !outcome.trashedPaths.isEmpty || !outcome.failedPaths.isEmpty else { return }
        pendingRestore = outcome.restore

        let bar = ManageDynamicBackgroundView()
        bar.fillColor = .controlBackgroundColor   // reinterpreted in updateLayer on mode switch
        bar.corner = 9
        bar.strokeWidth = 1
        bar.strokeColor = .separatorColor
        bar.translatesAutoresizingMaskIntoConstraints = false

        let label = NSTextField(labelWithString: snackbarText(outcome, attempted: attempted))
        label.font = .systemFont(ofSize: 12, weight: .medium)
        let undo = NSButton(title: "Undo", target: self, action: #selector(undoTapped))
        undo.bezelStyle = .rounded
        undo.isHidden = outcome.restore.isEmpty
        let stack = NSStackView(views: [label, undo])
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 8, left: 14, bottom: 8, right: 12)
        stack.translatesAutoresizingMaskIntoConstraints = false
        bar.addSubview(stack)
        view.addSubview(bar)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: bar.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: bar.trailingAnchor),
            stack.topAnchor.constraint(equalTo: bar.topAnchor),
            stack.bottomAnchor.constraint(equalTo: bar.bottomAnchor),
            bar.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            bar.bottomAnchor.constraint(equalTo: collectorBar.topAnchor, constant: -14),
        ])
        snackbar = bar
        let current = bar
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak self, weak current] in
            if self?.snackbar === current { self?.snackbar = nil }
            current?.removeFromSuperview()
        }
    }

    @objc private func undoTapped() {
        let entries = pendingRestore
        pendingRestore = []
        snackbar?.removeFromSuperview()
        snackbar = nil
        Task { @MainActor in await store.undoTrash(entries) }
    }

    private func snackbarText(_ outcome: ManageTrashService.Outcome, attempted: Int) -> String {
        let failed = outcome.failedPaths.count
        if failed == 0 { return "Moved \(attempted) to Trash." }
        if outcome.trashedPaths.isEmpty { return "Couldn't move items (\(failed) failed)." }
        return "Partly deleted — \(failed) failed."
    }

    // MARK: - Cache tab

    private func confirmRebuild() {
        // An enabled-but-never-activated source has no live driver, so a
        // rebuild would silently do nothing. Tell the user how to enable it
        // instead of pretending the rebuild ran.
        guard store.canManageIndex else {
            let info = NSAlert()
            info.messageText = "Activate this source to rebuild"
            info.informativeText = "Switch to this source in the sidebar (the mode picker) first — only the active source's index can be rebuilt."
            info.addButton(withTitle: "OK")
            info.runModal()
            return
        }
        let alert = NSAlert()
        alert.messageText = "Rebuild the index?"
        alert.informativeText = "Clears the derived index and re-scans your session logs. Original logs are not modified."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Rebuild")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        store.rebuildCacheIndex()
    }

    private func confirmClearSnapshots() {
        let alert = NSAlert()
        alert.messageText = "Clear the snapshot cache?"
        alert.informativeText = "Deletes only Lupen's derived JSON cache. The index DB and original logs are kept, and it's regenerated on next launch."
        alert.addButton(withTitle: "Clear")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        store.clearSnapshots()
    }

    private func revealSupport() {
        runOpen([store.providerSupportRoot.path])
    }

    // MARK: - Refresh

    private func refresh() {
        guard isReady else { return }
        // Keep the source switcher in sync with the store (handles the window
        // being re-opened with an updated source list / active selection).
        rebuildProviderSegments()
        switch store.scope {
        case .sessions:
            cachedRows = store.displayRows
        case .allDisk:
            cachedRows = ManageRowFilter.apply(store.allDiskRows, search: store.searchText, sort: store.sortKey, ascending: store.sortAscending)
        default:
            cachedRows = []
        }

        let showCache = store.scope == .cache
        cacheHosting.view.isHidden = !showCache
        scrollView.isHidden = showCache
        // Inspector/separator only on the Sessions tab — width 0 alone makes a
        // zero-width view render text vertically, so toggle isHidden as well.
        let showInspector = store.scope == .sessions
        inspectorHosting.view.isHidden = !showInspector
        leftSeparator?.isHidden = !showInspector
        inspectorWidth.constant = showInspector ? 320 : 0

        isRestoringSelection = true
        tableView.reloadData()
        let indexes = IndexSet(cachedRows.enumerated().filter { store.selectedIDs.contains($0.element.id) }.map(\.offset))
        tableView.selectRowIndexes(indexes, byExtendingSelection: false)
        isRestoringSelection = false

        updateCollector()

        if showCache {
            statusLabel.isHidden = true
        } else if cachedRows.isEmpty {
            let scanningText = store.scope == .allDisk ? "Measuring disk items…" : "Loading…"
            let emptyText: String
            switch store.scope {
            case .allDisk:  emptyText = "No items to show."
            default:        emptyText = "No sessions for this provider."
            }
            statusLabel.stringValue = store.isScanning ? scanningText
                : (store.searchText.isEmpty ? emptyText : "No matching items.")
            statusLabel.isHidden = false
        } else {
            statusLabel.isHidden = true
        }

        view.window?.subtitle = store.isIndexingNow ? "Indexing — you can clean up when it finishes" : ""
        syncIndexingPoll()
    }

    private func updateCollector() {
        // The collector (selection/Trash) only on the cleanable Sessions tab. All Disk/Cache
        // are read-only, so the Trash button is meaningless there.
        let count = store.selectedCount
        if store.scope == .sessions && count > 0 {
            let size = ByteCountFormatter.string(fromByteCount: store.selectedReclaimBytes, countStyle: .file)
            collectorLabel.stringValue = "\(count) selected · \(size)"
            clearButton.isHidden = false
            trashButton.isHidden = false
        } else {
            collectorLabel.stringValue = ""
            clearButton.isHidden = true
            trashButton.isHidden = true
        }
    }

    /// All Disk items are read-only — double-click reveals them in Finder.
    @objc private func rowDoubleClicked() {
        let row = tableView.clickedRow
        guard row >= 0, row < cachedRows.count else { return }
        if store.scope == .allDisk { reveal(cachedRows[row]) }
    }

    private func syncIndexingPoll() {
        if store.isIndexingNow {
            if indexingPoll == nil {
                indexingPoll = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
                    Task { @MainActor in
                        guard let self else { return }
                        if !self.store.isIndexingNow {
                            self.indexingPoll?.invalidate()
                            self.indexingPoll = nil
                            self.store.load()
                        }
                    }
                }
            }
        } else {
            indexingPoll?.invalidate()
            indexingPoll = nil
        }
    }
}

extension ManageViewController: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int { cachedRows.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let tableColumn, row < cachedRows.count else { return nil }
        let model = cachedRows[row]
        let columnId = tableColumn.identifier.rawValue
        let rightAligned = columns.first { $0.id == columnId }?.rightAligned ?? false
        let cell = makeCell(tableView, columnId: columnId, rightAligned: rightAligned)
        cell.textField?.stringValue = text(for: model, columnId: columnId)
        cell.textField?.font = columnId == "session"
            ? .systemFont(ofSize: 12, weight: .medium)
            : .systemFont(ofSize: 12)
        cell.textField?.textColor = (columnId == "created" || columnId == "updated") ? .secondaryLabelColor : .labelColor
        switch columnId {
        case "project": cell.toolTip = model.projectPath
        case "status":
            cell.toolTip = model.status.label
            // Emoji alone doesn't convey status to VoiceOver/color-blind users, so
            // spell out the status name via the accessibility label (honors the model
            // comment's "don't rely on color alone").
            cell.textField?.setAccessibilityLabel(model.status.label)
        default:
            cell.toolTip = nil
            cell.textField?.setAccessibilityLabel(nil)
        }
        return cell
    }

    private func text(for row: ManageRowModel, columnId: String) -> String {
        switch columnId {
        case "status":  return row.status.emoji
        case "project": return row.projectName
        case "session": return row.displayTitle
        case "created": return row.createdAt.map { dateFormatter.string(from: $0) } ?? "—"
        case "updated": return row.lastActivity.map { dateFormatter.string(from: $0) } ?? "—"
        case "size":    return ByteCountFormatter.string(fromByteCount: row.sizeBytes, countStyle: .file)
        case "files":   return row.fileCount > 0 ? "\(row.fileCount)" : "—"
        default:        return ""
        }
    }

    private func makeCell(_ tableView: NSTableView, columnId: String, rightAligned: Bool) -> NSTableCellView {
        let cellId = NSUserInterfaceItemIdentifier("cell_\(columnId)")
        if let existing = tableView.makeView(withIdentifier: cellId, owner: self) as? NSTableCellView {
            return existing
        }
        let cell = NSTableCellView()
        cell.identifier = cellId
        let field = NSTextField(labelWithString: "")
        field.translatesAutoresizingMaskIntoConstraints = false
        field.lineBreakMode = .byTruncatingTail
        field.alignment = columnId == "status" ? .center : (rightAligned ? .right : .left)
        if rightAligned { field.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular) }
        cell.addSubview(field)
        cell.textField = field
        NSLayoutConstraint.activate([
            field.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 6),
            field.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -6),
            field.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !isRestoringSelection else { return }
        let ids = Set(tableView.selectedRowIndexes.compactMap { idx -> String? in
            idx < cachedRows.count ? cachedRows[idx].id : nil
        })
        store.setSelectedIDs(ids)
        updateCollector()
    }

    func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
        guard isReady else { return }
        guard let descriptor = tableView.sortDescriptors.first,
              let key = descriptor.key,
              let sort = ManageRowSort(rawValue: key) else { return }
        store.sortKey = sort
        store.sortAscending = descriptor.ascending
        refresh()
    }
}

// MARK: - ManageDynamicBackgroundView

/// Layer-backed view that repaints its background/border color on dark↔light
/// mode switches. `.cgColor` is a static capture that doesn't react to
/// effectiveAppearance changes, so — like the project standard (PillBackgroundView)
/// — it reinterprets the dynamic NSColor every time in `updateLayer()`. AppKit
/// invalidates the layer and calls `updateLayer()` on appearance changes, so no
/// separate observation is needed.
private final class ManageDynamicBackgroundView: NSView {
    var fillColor: NSColor = .windowBackgroundColor
    var strokeColor: NSColor?
    var strokeWidth: CGFloat = 0
    var corner: CGFloat = 0

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }
    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.backgroundColor = fillColor.cgColor
        layer?.cornerRadius = corner
        layer?.borderWidth = strokeWidth
        layer?.borderColor = strokeColor?.cgColor
    }
}
