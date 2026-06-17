import Foundation

enum ProjectLabelFormatter {
    static func decode(_ raw: String) -> String {
        guard !raw.isEmpty else { return "" }
        if raw.contains("/") {
            let last = URL(fileURLWithPath: raw).lastPathComponent
            if !last.isEmpty { return last }
        }
        let stripped = raw.hasPrefix("-") ? String(raw.dropFirst()) : raw
        let components = stripped.split(separator: "-", omittingEmptySubsequences: true)
        if let last = components.last { return String(last) }
        return raw
    }
}
