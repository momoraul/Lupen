# Security policy

Lupen reads your local Claude Code transcripts, which contain whatever
you've ever typed into Claude — including prompts, file paths, code,
and any attachments you pasted in. That makes Lupen's security posture
the single most important thing about the app, more than features or
performance. The notes below describe the model so you can verify
independently and report issues with the right context.

## 1. What Lupen reads

Lupen only reads files under:

- `~/.claude/projects/**/*.jsonl` — Claude Code's per-session transcript log

That directory is opened **read-only**. New entries are picked up via
`DispatchSource.makeFileSystemObjectSource(.extend)` — the same kernel
primitive `tail -f` uses — so there is no polling, no full re-read on
every tick, and no fan-out to other paths.

Lupen does not read:

- Other Claude Code state (`~/.claude/settings.json`, agents, skills,
  commands, conversations outside `projects/`)
- macOS Keychain, browser cookies, or any other app's data
- Any path outside `~/.claude/projects/` and Lupen's own support folder
  (see §2)

## 2. What Lupen writes

Lupen writes only to its own data and preference locations:

- `~/Library/Application Support/Lupen/` — snapshot cache (a binary blob
  that lets Lupen launch incrementally instead of re-parsing every JSONL
  on every start). Format is internal and version-tagged; mismatched
  versions trigger a full re-parse instead of crashing.
- `~/Library/Logs/Lupen/` — diagnostic logs written via `LoggerService`.
  Includes parse-rejection counts and timing summaries, **never** raw
  prompt or response content.
- `~/Library/Preferences/com.momoraul.lupen.plist` — the standard macOS
  preferences file. Boolean toggles, picker selections, window
  positions.
- `~/.claude/lupen/ratelimit-samples.jsonl` — append-only log of the
  rate-limit signals Claude Code's `statusline-tap` writes to Lupen.
  This file is created and rotated by Lupen itself; it never leaves
  your machine.

Lupen does not write back into `~/.claude/projects/`. The transcript
log stays read-only from Lupen's side.

## 3. Network behaviour: zero

Lupen makes **zero network requests** during normal operation. You can
verify this several ways:

- `Lupen.app/Contents/Info.plist` carries no `NSAppTransportSecurity`
  block, no `NSAllowsArbitraryLoads`, no domain exceptions. Lupen
  doesn't ask macOS for permission to call any HTTPS server because
  the app never opens a socket.
- Run any outbound-traffic monitor (Little Snitch, LuLu, or
  `lsof -i -P` while Lupen is running) — you will see no Lupen-owned
  TCP/UDP connections.
- Signed and notarised builds are scanned by Apple for unexpected
  network behaviour as part of notarisation.

The one exception is the **optional** Sparkle auto-updater (see §4).

## 4. Updates (Sparkle, opt-in)

Lupen ships with [Sparkle 2](https://sparkle-project.org) wired up so
you can choose to receive updates automatically. When automatic
checks are **enabled** (Preferences → Updates):

- Sparkle fetches a signed AppCast feed (`appcast.xml`) from the
  release host on a configurable cadence.
- If an update is available and downloads are also enabled, Sparkle
  fetches the signed DMG.
- Every update is verified against an EdDSA public key embedded in
  Lupen's binary at build time. An update with a mismatched signature
  is rejected and never installed.

You can turn both toggles off in Preferences; the app then makes no
network requests at all. The toggles default to your previous choice
across launches.

## 5. No telemetry, analytics, or crash reporting

Lupen does not include any third-party telemetry, analytics SDK, or
crash-reporting service. There is no first-party endpoint either.

The diagnostic counters you see in Window → Diagnostics are tallied
locally and never uploaded.

## 6. Dependencies

Lupen's runtime is pure Apple frameworks (AppKit, SwiftUI, Foundation,
Observation, Combine) plus two SPM dependencies:

- **Sparkle 2** (MIT License) — auto-update framework. Source:
  <https://github.com/sparkle-project/Sparkle>.
- **GRDB.swift** (MIT License) — SQLite toolkit backing the on-disk
  cache. Source: <https://github.com/groue/GRDB.swift>.

Both are pinned to exact hashes in
`Lupen.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved`
so builds across machines resolve identically.

No other third-party SDKs, no embedded binaries, no dynamic
libraries beyond what macOS ships.

## 7. Reporting a vulnerability

If you find a security issue, please report it privately. Two
channels:

- Open a [GitHub Security Advisory](https://github.com/momoraul/Lupen/security/advisories/new)
  on the repository (preferred — keeps the discussion auditable).
- Email the maintainer at `huni@live.com` if you'd rather not
  use GitHub Security Advisories.

Please include:

- A description of the issue and the threat it represents
- The smallest reproducer you can manage (a sanitised JSONL snippet,
  or a sequence of menu actions)
- The Lupen version (`Lupen ▸ About Lupen`) and macOS version
  (`sw_vers -productVersion`)

The maintainer will acknowledge within **48 hours**, work with you on
a fix, and credit you in the release notes (or keep you anonymous —
your call). Please do **not** open a public issue for security
problems until a fix has shipped.

## 8. Supported versions

Security fixes ship in the latest minor release. The previous minor
release also receives security fixes for 30 days after a new minor
ships, to give Homebrew users a smooth upgrade window.

| Version | Security fixes |
|---------|---------------|
| 0.x (latest minor) | Yes |
| 0.x (previous minor, ≤ 30 days old) | Yes |
| Earlier | No — please upgrade |
