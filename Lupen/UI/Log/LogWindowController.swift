import AppKit
import SwiftUI

@MainActor
final class LogWindowController {

    private var window: NSWindow?
    private let logger: LoggerService

    init(logger: LoggerService) {
        self.logger = logger
    }

    func showWindow() {
        if let window, window.isVisible {
            window.bringToFront()
            return
        }

        let logContent = LogWindowContent(logger: logger)
        let hostingView = NSHostingView(rootView: logContent)

        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 500),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        win.title = "Lupen Logs"
        win.contentView = hostingView
        win.center()
        win.isReleasedWhenClosed = false
        win.setFrameAutosaveName("LogWindow")
        win.minSize = NSSize(width: 500, height: 300)

        self.window = win
        win.bringToFront()
    }
}

/// SwiftUI wrapper with toolbar for the log window.
private struct LogWindowContent: View {
    @Bindable var logger: LoggerService

    @AppStorage("logDetailVisible") private var detailVisible: Bool = true

    var body: some View {
        LogView(logger: logger)
            .frame(minWidth: 500, minHeight: 300)
            .toolbar(id: "logTools") {
                ToolbarItem(id: "autoScroll", placement: .automatic, showsByDefault: true) {
                    Toggle(isOn: $logger.autoScroll) {
                        Image(systemName: "arrow.down.to.line")
                    }
                    .toggleStyle(.button)
                    .help("Auto-scroll")
                }

                ToolbarItem(id: "detailToggle", placement: .automatic, showsByDefault: true) {
                    Toggle(isOn: Binding(
                        get: { detailVisible },
                        set: { newValue in
                            withAnimation(.easeInOut(duration: 0.2)) {
                                detailVisible = newValue
                            }
                        }
                    )) {
                        Image(systemName: "rectangle.bottomhalf.inset.filled")
                    }
                    .toggleStyle(.button)
                    .help(detailVisible ? "Hide detail panel" : "Show detail panel")
                }

                ToolbarSpacer(.fixed)

                ToolbarItem(id: "copy", placement: .automatic, showsByDefault: true) {
                    Button {
                        _ = logger.exportToClipboard()
                    } label: {
                        Image(systemName: "doc.on.doc")
                    }
                    .help("Copy logs to clipboard")
                }

                ToolbarItem(id: "clear", placement: .automatic, showsByDefault: true) {
                    Button {
                        logger.clear()
                    } label: {
                        Image(systemName: "trash")
                    }
                    .help("Clear logs")
                }
            }
            .toolbarRole(.editor)
    }
}
