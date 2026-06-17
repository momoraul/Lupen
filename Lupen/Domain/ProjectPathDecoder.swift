import Foundation

/// Decodes a Claude Code–encoded project directory name back into an
/// absolute filesystem path.
///
/// Claude Code stores each project under
/// `~/.claude/projects/<encoded>/<sessionId>.jsonl` where `<encoded>` is
/// derived from the absolute path by replacing **every** `/` **and** `_`
/// with `-`. For example:
///
///     /Users/example/work/_claude/Lupen
///     → -Users-example-work--claude-Lupen
///
/// Notice how `/_claude` collapses into the `--claude` segment — the leading
/// slash and the leading underscore of the directory name each contribute one
/// dash, producing a double-dash pair.
///
/// ## Why this is lossy
///
/// Because both `/` and `_` collapse into `-`, the encoding is **not
/// round-trippable**. A decoded `--` could legally mean `/_`, `__`, or even
/// literal `--`. This decoder picks the common convention — `--` means
/// `/_` (a directory whose name starts with an underscore) — which handles
/// ~every real path on disk correctly, including Lupen's own
/// `/Users/.../_claude/Lupen` location.
///
/// The failure mode is "a segment whose name contains an internal
/// underscore", e.g. `/Users/.../\_bono/_side_pjt/APIBuddy`. That path
/// encodes as `-Users-...--bono--side-pjt-APIBuddy` and we decode the last
/// chunk as `_side/pjt/APIBuddy` — wrong, because we can't tell that the
/// internal `-` was once an `_` instead of a path separator. Callers that
/// need correctness must verify the decoded path against the filesystem and
/// fall back to the `cwd` field from the session's first JSONL entry (which
/// Claude Code writes verbatim, without lossy transformation) when the
/// decode doesn't exist on disk.
///
/// ## Algorithm
///
/// 1. Expand every `--` to `/_`. This runs first so the next pass can't
///    consume one of its dashes.
/// 2. Replace every remaining single `-` with `/`.
/// 3. If the result doesn't already start with `/` (caller passed a
///    malformed input without the usual leading dash), prepend one so the
///    return value is always an absolute path.
///
/// No leading-dash stripping is needed: the leading `-` that originally
/// encoded the absolute-path root is already converted to `/` by pass 2.
enum ProjectPathDecoder {

    /// Best-effort decode. See the type doc for the lossy-encoding caveat.
    ///
    /// - Parameter encoded: The raw encoded directory name, exactly as it
    ///   appears under `~/.claude/projects/`. Must not be prefixed with
    ///   `file://` or any other scheme.
    /// - Returns: An absolute filesystem path (always starts with `/`).
    ///   Empty input degrades to `"/"` so downstream `cd` calls stay safe.
    static func decodeFullPath(_ encoded: String) -> String {
        guard !encoded.isEmpty else { return "/" }
        // Step 1: `--` must be expanded before the solo-dash → slash pass,
        // or the first pass would eat one of its dashes and we'd get
        // `//<name>` where the user meant `/_<name>`.
        let underscoresRestored = encoded.replacingOccurrences(of: "--", with: "/_")
        // Step 2: Every remaining dash is a path separator.
        let slashesRestored = underscoresRestored.replacingOccurrences(of: "-", with: "/")
        // Step 3: Guarantee absolute form. Normal Claude Code inputs start
        // with a dash and therefore become `/…` after step 2, but defend
        // against a caller that handed us a path fragment.
        return slashesRestored.hasPrefix("/") ? slashesRestored : "/" + slashesRestored
    }
}
