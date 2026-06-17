import Foundation
import AppKit

/// Pulls the decoded bytes of an inline base64 image block out of a
/// raw JSONL line.
///
/// Inline images carry no file path — the bytes live only inside the
/// JSONL `message.content[].source.data` field. For a UI preview we
/// need to:
///
///   1. Find the locator's image index (`#inline:<idx>:<mediaType>`).
///   2. Walk `message.content[]` and pick the N-th block of
///      `type == "image"`.
///   3. Base64-decode `source.data` into `Data`.
///   4. Hand the bytes to AppKit for `NSImage` construction.
///
/// Kept as a tiny stateless enum so both `AttachmentsDetailView` and
/// any future detail surface (e.g. a Quick Look extension) can share
/// the same parser.
enum InlineImageLoader {

    /// Parses `imageIndex` from the synthetic locator string shipped
    /// by `AttachmentResolver` for `.inlineImage` refs. Returns nil
    /// if the prefix doesn't match — callers should fall back to no
    /// preview rather than guessing.
    static func imageIndex(fromLocator locator: String) -> Int? {
        guard locator.hasPrefix("#inline:") else { return nil }
        let rest = locator.dropFirst("#inline:".count)
        // Format: `<idx>:<mediaType>` — split once.
        let parts = rest.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        guard let first = parts.first else { return nil }
        return Int(first)
    }

    /// Locates the `imageIndex`-th `type=="image"` block in the raw
    /// JSONL line and returns its decoded bytes plus reported media
    /// type. Returns nil if parsing fails at any step — the caller
    /// should then skip the preview silently so a corrupt line
    /// doesn't break the rest of the UI.
    static func decodeImage(
        fromRawJSON raw: Data,
        imageIndex: Int
    ) -> (data: Data, mediaType: String?)? {
        guard
            let obj = try? JSONSerialization.jsonObject(with: raw) as? [String: Any],
            let message = obj["message"] as? [String: Any]
        else { return nil }

        // `content` may be a string (legacy format) or an array of
        // blocks (current format). Inline images only exist in the
        // array form, so we require that.
        guard let blocks = message["content"] as? [[String: Any]] else {
            return nil
        }

        var seenImages = 0
        for block in blocks {
            guard (block["type"] as? String) == "image",
                  let source = block["source"] as? [String: Any]
            else { continue }
            if seenImages == imageIndex {
                let mediaType = source["media_type"] as? String
                guard let base64 = source["data"] as? String,
                      let data = Data(base64Encoded: base64, options: .ignoreUnknownCharacters)
                else { return nil }
                return (data, mediaType)
            }
            seenImages += 1
        }
        return nil
    }

    /// Convenience wrapper — builds an `NSImage` directly from the
    /// locator + raw JSONL bytes. Returns nil if decoding fails.
    static func loadNSImage(
        forLocator locator: String,
        rawJSON raw: Data
    ) -> NSImage? {
        guard let idx = imageIndex(fromLocator: locator) else { return nil }
        guard let (data, _) = decodeImage(fromRawJSON: raw, imageIndex: idx) else {
            return nil
        }
        return NSImage(data: data)
    }
}
