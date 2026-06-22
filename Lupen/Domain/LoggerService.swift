import Foundation
import os.log
import AppKit

@Observable
@MainActor
final class LoggerService {
    // MARK: - Constants

    private static let maxEntries: Int = 2000

    private enum Keys {
        static let enabledLevels = "Lupen.log.enabledLevels"
        static let searchText = "Lupen.log.searchText"
        static let autoScroll = "Lupen.log.autoScroll"
        static let fileLoggingEnabled = "Lupen.log.fileLoggingEnabled"
    }

    // MARK: - Properties

    private(set) var entries: [LogEntry] = []
    private var fileHandle: FileHandle?
    private(set) var logFilePath: URL?

    // MARK: - Filter State (persisted)

    var enabledLevels: Set<LogLevel> = Set(LogLevel.allCases) {
        didSet { saveFilterState() }
    }
    var searchText: String = "" {
        didSet { saveFilterState() }
    }
    var autoScroll: Bool = true {
        didSet { UserDefaults.standard.set(autoScroll, forKey: Keys.autoScroll) }
    }
    var fileLoggingEnabled: Bool = false {
        didSet {
            UserDefaults.standard.set(fileLoggingEnabled, forKey: Keys.fileLoggingEnabled)
            if fileLoggingEnabled {
                startFileLogging()
            } else {
                stopFileLogging()
            }
        }
    }

    // MARK: - Computed Properties

    var filteredEntries: [LogEntry] {
        entries.filter { entry in
            guard enabledLevels.contains(entry.level) else { return false }
            if searchText.isEmpty { return true }

            if let match = searchText.wholeMatch(of: /\[(.+)\]/) {
                let ctx = String(match.1)
                return entry.context?.localizedCaseInsensitiveContains(ctx) ?? false
            }

            return entry.message.localizedCaseInsensitiveContains(searchText) ||
                   (entry.context?.localizedCaseInsensitiveContains(searchText) ?? false)
        }
    }

    // MARK: - Singleton

    nonisolated static let shared = LoggerService()

    /// Intentionally empty and `nonisolated` so the singleton can be created
    /// from whatever thread first touches `shared`. Under the CLI that is a
    /// background indexing queue, not the main actor — the previous
    /// `MainActor.assumeIsolated` trapped there (`lupen summary` crashed
    /// 100%). The main-actor-isolated stored properties (`@Observable` makes
    /// even in-init assignment go through isolated setters) keep their
    /// declared defaults here; persisted filter state and file logging are
    /// restored lazily on the first `log()` via `bootstrapIfNeeded()`, which
    /// always runs on the main actor.
    nonisolated init() {}

    /// One-time, main-actor restore of persisted filter state + file logging.
    /// Deferred out of `init` because `init` must stay `nonisolated` for a
    /// safe background first-touch. Every `log()` entry point is main-actor
    /// isolated, so touching the isolated properties here is safe.
    private var didBootstrap = false
    private func bootstrapIfNeeded() {
        guard !didBootstrap else { return }
        didBootstrap = true
        // `loadFilterState` sets `fileLoggingEnabled`, whose `didSet` starts
        // file logging when enabled — no separate start call needed.
        loadFilterState()
    }

    // MARK: - Nonisolated entry point for background threads

    nonisolated func logFromAnyThread(
        _ level: LogLevel,
        _ message: String,
        context: String? = nil,
        file: String = #file,
        line: Int = #line
    ) {
        // Build the entry once, here, so its timestamp reflects the call site
        // and OSLog + the in-app store share the exact same record. Emit to
        // OSLog synchronously (thread-safe) for immediate Console.app
        // visibility, then hop to the main actor to record it in the Logs
        // window / file. There is deliberately NO `MainActor.assumeIsolated`
        // and no main-thread fast path: assuming "main thread == main actor
        // executor" traps on the CLI's background index queue (and on any
        // non-main executor), which was the root of the `lupen` SIGTRAP.
        // This path is safe to call from any thread or executor.
        let source = URL(fileURLWithPath: file).lastPathComponent
        let entry = LogEntry(level: level, message: message, context: context, source: source, line: line)
        Self.emitToOSLog(entry: entry, context: context)
        DispatchQueue.main.async { [self] in
            store(entry)
        }
    }

    // MARK: - Logging Methods

    func log(
        _ level: LogLevel,
        _ message: String,
        context: String? = nil,
        file: String = #file,
        line: Int = #line
    ) {
        let source = URL(fileURLWithPath: file).lastPathComponent
        let entry = LogEntry(
            level: level,
            message: message,
            context: context,
            source: source,
            line: line
        )
        store(entry)
        Self.emitToOSLog(entry: entry, context: context)
    }

    /// Records an already-built entry into the in-app log + file. Main-actor
    /// isolated — the single sink shared by `log()` (direct main-thread calls)
    /// and the main hop of `logFromAnyThread`. OSLog emission is the caller's
    /// job, so the background path can emit synchronously off-main (for
    /// immediate Console visibility) before hopping here, without a duplicate.
    private func store(_ entry: LogEntry) {
        bootstrapIfNeeded()
        entries.append(entry)
        if entries.count > Self.maxEntries {
            entries.removeFirst(entries.count - Self.maxEntries)
        }
        writeToFile(entry)
    }

    /// Shared OSLog fan-out — used by both `log()` (main-thread path)
    /// and `logFromAnyThread` (background path). `nonisolated static`
    /// because it reads only from thread-safe sources (`osLog(forCategory:)`
    /// takes the cache lock; `os_log` itself is thread-safe).
    nonisolated private static func emitToOSLog(entry: LogEntry, context: String?) {
        let osLogType: OSLogType = switch entry.level {
        case .debug: .debug
        case .info: .info
        case .success: .info
        case .warning: .default
        case .error: .error
        }
        // Route through a category-scoped OSLog so Console.app filters
        // like `subsystem:com.momoraul.lupen category:OutlineGraft` work.
        // Without this every LoggerService line lands in `log: .default`
        // and the user has to grep raw text instead of using Apple's
        // native filtering. `context ?? "App"` keeps un-categorised
        // logs grouped under a sensible default.
        let categoryLog = osLog(forCategory: context ?? "App")
        os_log("%{public}@", log: categoryLog, type: osLogType, entry.detailText)
    }

    // MARK: - Per-category OSLog cache

    /// Cached `OSLog` instances keyed by category name. Built lazily so
    /// new contexts don't pay a construction cost on every log line.
    /// Subsystem is fixed at `com.momoraul.lupen` to match the rest of the
    /// codebase (PricingTable / ParseDiagnostics / FileDiscovery use the
    /// same subsystem via direct `Logger(subsystem:category:)`).
    nonisolated(unsafe) private static var osLogByCategory: [String: OSLog] = [:]
    nonisolated private static let osLogCacheLock = NSLock()

    nonisolated private static func osLog(forCategory category: String) -> OSLog {
        osLogCacheLock.lock(); defer { osLogCacheLock.unlock() }
        if let existing = osLogByCategory[category] { return existing }
        let log = OSLog(subsystem: "com.momoraul.lupen", category: category)
        osLogByCategory[category] = log
        return log
    }

    func debug(_ message: String, context: String? = nil, file: String = #file, line: Int = #line) {
        log(.debug, message, context: context, file: file, line: line)
    }

    func info(_ message: String, context: String? = nil, file: String = #file, line: Int = #line) {
        log(.info, message, context: context, file: file, line: line)
    }

    func success(_ message: String, context: String? = nil, file: String = #file, line: Int = #line) {
        log(.success, message, context: context, file: file, line: line)
    }

    func warning(_ message: String, context: String? = nil, file: String = #file, line: Int = #line) {
        log(.warning, message, context: context, file: file, line: line)
    }

    func error(_ message: String, context: String? = nil, file: String = #file, line: Int = #line) {
        log(.error, message, context: context, file: file, line: line)
    }

    // MARK: - File Logging

    /// `~/Library/Application Support/Lupen/Logs` — public so the app
    /// menu's "Reveal Log File in Finder" can open the directory even
    /// when file logging is disabled and no log file exists yet.
    static var logDirectoryURL: URL {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!
        return appSupport.appendingPathComponent("Lupen/Logs")
    }

    /// Backward-compat alias for the old private accessor.
    private static var logDirectory: URL { logDirectoryURL }

    private func startFileLogging() {
        let directory = Self.logDirectory
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd"
        let fileName = "Lupen_\(dateFormatter.string(from: Date())).log"
        let filePath = directory.appendingPathComponent(fileName)
        logFilePath = filePath

        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

            if !FileManager.default.fileExists(atPath: filePath.path) {
                FileManager.default.createFile(atPath: filePath.path, contents: nil)
            }

            fileHandle = try FileHandle(forWritingTo: filePath)
            fileHandle?.seekToEndOfFile()

            info("Log file started: \(filePath.path)")
        } catch {
            self.error("Failed to start file logging: \(error.localizedDescription)")
        }
    }

    private func stopFileLogging() {
        guard fileHandle != nil else { return }
        try? fileHandle?.close()
        fileHandle = nil
    }

    private func writeToFile(_ entry: LogEntry) {
        guard let fileHandle else { return }

        let line = entry.detailText + "\n"
        if let data = line.data(using: .utf8) {
            try? fileHandle.write(contentsOf: data)
        }
    }

    func revealLogFile() {
        if let logFilePath {
            NSWorkspace.shared.selectFile(logFilePath.path, inFileViewerRootedAtPath: Self.logDirectory.path)
        } else {
            NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: Self.logDirectory.path)
        }
    }

    // MARK: - Clear

    func clear() {
        entries.removeAll()
    }

    // MARK: - Export

    func exportToClipboard() -> Bool {
        let text = filteredEntries.map(\.detailText).joined(separator: "\n")
        NSPasteboard.general.clearContents()
        return NSPasteboard.general.setString(text, forType: .string)
    }

    // MARK: - Filter Persistence

    private func saveFilterState() {
        let levelRawValues = enabledLevels.map(\.rawValue)
        UserDefaults.standard.set(levelRawValues, forKey: Keys.enabledLevels)
        UserDefaults.standard.set(searchText, forKey: Keys.searchText)
    }

    /// Restores persisted filter state. Called once from `bootstrapIfNeeded()`
    /// on the main actor (never from the `nonisolated init`).
    private func loadFilterState() {
        if let rawValues = UserDefaults.standard.stringArray(forKey: Keys.enabledLevels) {
            enabledLevels = Set(rawValues.compactMap { LogLevel(rawValue: $0) })
        }

        if let saved = UserDefaults.standard.string(forKey: Keys.searchText) {
            searchText = saved
        }

        let storedAutoScroll = UserDefaults.standard.object(forKey: Keys.autoScroll)
        autoScroll = (storedAutoScroll as? Bool) ?? true

        // Default-on so issues that surface after long-running sessions
        // can be diagnosed from disk; OSLog's ring buffer only keeps a
        // few minutes. Users can still toggle off via the Logs window.
        let storedFileLogging = UserDefaults.standard.object(forKey: Keys.fileLoggingEnabled)
        fileLoggingEnabled = (storedFileLogging as? Bool) ?? true
    }

    // MARK: - Accessors used by AppDelegate menu

    /// Returns the live log file path or, if file logging is disabled
    /// or the file hasn't been created yet, the expected path — so the
    /// Reveal in Finder menu can always resolve a destination.
    var resolvedLogFilePath: URL {
        if let logFilePath { return logFilePath }
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd"
        let fileName = "Lupen_\(dateFormatter.string(from: Date())).log"
        return Self.logDirectoryURL.appendingPathComponent(fileName)
    }

    /// Safe reveal for the menu path: creates the directory if missing
    /// so Finder always opens, even with file logging disabled.
    func revealLogDirectoryInFinder() {
        let dir = Self.logDirectoryURL
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if let logFilePath, FileManager.default.fileExists(atPath: logFilePath.path) {
            NSWorkspace.shared.selectFile(logFilePath.path, inFileViewerRootedAtPath: dir.path)
        } else {
            NSWorkspace.shared.open(dir)
        }
    }
}
