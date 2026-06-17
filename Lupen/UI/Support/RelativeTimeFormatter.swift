import Foundation

enum RelativeTimeFormatter {
    static func compact(_ date: Date, now: Date = .now) -> String {
        let age = now.timeIntervalSince(date)
        if age < 5 { return "just now" }
        else if age < 60 { return "\(Int(age))s ago" }
        else if age < 3600 { return "\(Int(age / 60))m ago" }
        else if age < 86400 { return "\(Int(age / 3600))h ago" }
        else { return dateFormatter.string(from: date) }
    }

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "MM/dd"; return f
    }()
}
