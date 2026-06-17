import Foundation

enum LogLevel: String, Codable, CaseIterable, Sendable {
    case debug = "DEBUG"
    case info = "INFO"
    case success = "SUCCESS"
    case warning = "WARNING"
    case error = "ERROR"

    var emoji: String {
        switch self {
        case .debug: return "🔍"
        case .info: return "ℹ️"
        case .success: return "✅"
        case .warning: return "⚠️"
        case .error: return "❌"
        }
    }
}

struct LogEntry: Identifiable, Hashable, Sendable {
    let id: UUID
    let timestamp: Date
    let level: LogLevel
    let message: String
    let context: String?
    let source: String?
    let line: Int?

    init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        level: LogLevel,
        message: String,
        context: String? = nil,
        source: String? = nil,
        line: Int? = nil
    ) {
        self.id = id
        self.timestamp = timestamp
        self.level = level
        self.message = message
        self.context = context
        self.source = source
        self.line = line
    }

    var formattedTimestamp: String {
        Self.timestampFormatter.string(from: timestamp)
    }

    var detailText: String {
        var parts: [String] = []
        parts.append("[\(formattedTimestamp)] [\(level.rawValue)]")
        if let source, let line {
            parts.append("\(source):\(line)")
        }
        if let context {
            parts.append("[\(context)]")
        }
        parts.append(message)
        return parts.joined(separator: " ")
    }

    private static let timestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()

    private static let detailTimestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale.autoupdatingCurrent
        formatter.setLocalizedDateFormatFromTemplate("yMMMdHHmmssSSS")
        return formatter
    }()

    var formattedDetailTimestamp: String {
        Self.detailTimestampFormatter.string(from: timestamp)
    }
}
