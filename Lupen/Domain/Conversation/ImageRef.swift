import Foundation

/// Reference to an image attached to a prompt Step.
///
/// Claude Code JSONL surfaces image attachments in two shapes:
/// 1. A `{"type": "image", "source": {...}}` block inside `message.content`.
/// 2. A separate user entry containing `[Image source: /abs/path.png]` text.
///
/// This struct represents either.
struct ImageRef: Sendable, Equatable, Codable {
    /// Local file path; when present the Finder reveal action is available.
    let path: String?
    /// MIME type (e.g. "image/png").
    let mediaType: String?

    init(path: String? = nil, mediaType: String? = nil) {
        self.path = path
        self.mediaType = mediaType
    }
}
