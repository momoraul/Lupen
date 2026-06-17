import Foundation

/// Pretty-prints JSON data for the Raw tab.
enum JSONPrettyFormatter {

    static func format(_ data: Data) -> String {
        // Try to parse as JSON and re-serialize with pretty printing
        do {
            let obj = try JSONSerialization.jsonObject(with: data)
            let pretty = try JSONSerialization.data(
                withJSONObject: obj,
                options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            )
            return String(data: pretty, encoding: .utf8) ?? fallbackString(data)
        } catch {
            return fallbackString(data)
        }
    }

    private static func fallbackString(_ data: Data) -> String {
        String(data: data, encoding: .utf8) ?? "(binary data, \(data.count) bytes)"
    }
}
