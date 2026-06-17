import SwiftUI
import AppKit

struct LogView: View {
    @Bindable var logger: LoggerService
    @State private var selectedEntry: LogEntry?

    @AppStorage("logDetailPosition") private var detailPosition: DetailPosition = .bottom
    @AppStorage("logDetailVisible") private var detailVisible: Bool = true

    var body: some View {
        VStack(spacing: 0) {
            filterBar
            Divider()
            contentArea
        }
    }

    // MARK: - Filter Bar

    private var filterBar: some View {
        HStack(spacing: 8) {
            logLevelFilterMenu

            HStack(spacing: 4) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search...", text: $logger.searchText)
                    .textFieldStyle(.plain)

                if !logger.searchText.isEmpty {
                    Button {
                        logger.searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(.quaternary)
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    // MARK: - Log Level Filter

    private var activeFilterCount: Int {
        LogLevel.allCases.count - logger.enabledLevels.count
    }

    private var logLevelFilterMenu: some View {
        Menu {
            ForEach(LogLevel.allCases, id: \.self) { level in
                Toggle(isOn: levelBinding(for: level)) {
                    Text(level.rawValue)
                }
            }

            Divider()

            Button("Select All") {
                logger.enabledLevels = Set(LogLevel.allCases)
            }
            .disabled(logger.enabledLevels.count == LogLevel.allCases.count)

            Button("Deselect All") {
                logger.enabledLevels.removeAll()
            }
            .disabled(logger.enabledLevels.isEmpty)
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "line.3.horizontal.decrease.circle\(activeFilterCount > 0 ? ".fill" : "")")
                Text("Filter")
                    .font(.caption)
                if activeFilterCount > 0 {
                    Text("\(activeFilterCount)")
                        .font(.system(.caption2, weight: .medium))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(.secondary))
                }
            }
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    // MARK: - Content Area

    @ViewBuilder
    private var contentArea: some View {
        if detailVisible {
            if detailPosition == .bottom {
                VSplitView {
                    logList
                        .frame(minHeight: 80)
                    detailPanel
                        .frame(minHeight: 80)
                }
            } else {
                HSplitView {
                    logList
                        .frame(minWidth: 200)
                    detailPanel
                        .frame(minWidth: 200)
                }
            }
        } else {
            logList
        }
    }

    // MARK: - Log List

    private var logList: some View {
        ScrollViewReader { proxy in
            List(selection: $selectedEntry) {
                ForEach(logger.filteredEntries) { entry in
                    LogEntryRow(entry: entry)
                        .tag(entry)
                        .id(entry.id)
                }
            }
            .listStyle(.plain)
            .onChange(of: logger.filteredEntries.count) { _, _ in
                if logger.autoScroll, let lastEntry = logger.filteredEntries.last {
                    withAnimation {
                        proxy.scrollTo(lastEntry.id, anchor: .bottom)
                    }
                }
            }
        }
    }

    // MARK: - Detail Panel

    private var detailPanel: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text("Detail")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()

                Picker("", selection: $detailPosition) {
                    Image(systemName: "rectangle.split.1x2")
                        .tag(DetailPosition.bottom)
                    Image(systemName: "rectangle.split.2x1")
                        .tag(DetailPosition.right)
                }
                .pickerStyle(.segmented)
                .frame(width: 56)
                .help("Detail panel position")

                Divider()
                    .frame(height: 12)

                Button {
                    guard let entry = selectedEntry else { return }
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(entry.detailText, forType: .string)
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                .buttonStyle(.plain)
                .disabled(selectedEntry == nil)
                .help("Copy")
            }

            if let entry = selectedEntry {
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 4) {
                            GridRow {
                                Text("Time")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .gridColumnAlignment(.trailing)
                                Text(entry.formattedDetailTimestamp)
                                    .font(.system(.caption, design: .monospaced))
                            }
                            GridRow {
                                Text("Level")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Text(entry.level.rawValue)
                                    .font(.caption.weight(.medium))
                                    .foregroundStyle(LogEntryRow.color(for: entry.level))
                            }
                            if let context = entry.context {
                                GridRow {
                                    Text("Context")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    Text(context)
                                        .font(.caption)
                                }
                            }
                            if let source = entry.source, let line = entry.line {
                                GridRow {
                                    Text("Source")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    Text("\((source as NSString).lastPathComponent):\(line)")
                                        .font(.system(.caption, design: .monospaced))
                                }
                            }
                        }

                        Divider()

                        Text(entry.message)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            } else {
                Text("Select a log entry to see details")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .padding(12)
        .background(.quaternary.opacity(0.5))
    }

    // MARK: - Helpers

    private func levelBinding(for level: LogLevel) -> Binding<Bool> {
        Binding(
            get: { logger.enabledLevels.contains(level) },
            set: { isEnabled in
                if isEnabled {
                    logger.enabledLevels.insert(level)
                } else {
                    logger.enabledLevels.remove(level)
                }
            }
        )
    }
}

// MARK: - Detail Position

enum DetailPosition: String, CaseIterable {
    case bottom
    case right
}

// MARK: - Log Entry Row

struct LogEntryRow: View {
    let entry: LogEntry

    var body: some View {
        HStack(spacing: 8) {
            Text(entry.formattedTimestamp)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 90, alignment: .leading)

            Text(entry.level.rawValue)
                .font(.caption.weight(.medium))
                .foregroundStyle(levelColor)
                .frame(width: 60, alignment: .leading)

            if let context = entry.context {
                Text("[\(context)]")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Text(entry.message)
                .font(.system(.caption, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer()
        }
        .padding(.vertical, 2)
    }

    static func color(for level: LogLevel) -> Color {
        switch level {
        case .debug: return .gray
        case .info: return .primary
        case .success: return .green
        case .warning: return .orange
        case .error: return .red
        }
    }

    private var levelColor: Color {
        Self.color(for: entry.level)
    }
}
