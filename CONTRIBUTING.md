# Contributing

Thanks for opening Lupen. The notes below cover the workflow the
maintainer uses; reviewers will hold PRs to roughly the same bar.

## Workflow

1. **Open an issue first** for anything non-trivial — a one-paragraph
   description of *what* and *why* before writing code. Trivial fixes
   (typo, 1–3 line bug fix) skip straight to a PR.
2. **State your approach** in the PR description before significant
   work lands. If the plan changes during implementation, update the
   description so reviewers see the current intent, not the original.
3. **Respect the existing patterns** — if you're introducing a new
   pattern, say why in the PR description so the reviewer can weigh it
   against the cost of having two patterns.
4. **Keep PRs scoped.** One concern per PR. Drive-by fixes go in
   separate commits or follow-up PRs so the diff stays reviewable.

## Local setup

```bash
git clone https://github.com/momoraul/Lupen.git
cd Lupen

# Copy the example and fill in your Apple Developer Team ID
# (Xcode → Settings → Accounts → Manage Certificates).
cp Config/Local.xcconfig.example Config/Local.xcconfig
$EDITOR Config/Local.xcconfig

xcodebuild test -project Lupen.xcodeproj -scheme Lupen \
  -destination 'platform=macOS'
```

Without a `Config/Local.xcconfig`, the build still succeeds — it just
signs with the "Sign to Run Locally" identity, which means the binary
only runs on the machine that built it.

To exercise the app against real data, point a Claude Code installation
at `~/.claude/projects/` (the default location). Lupen reads from that
directory only — no other paths, no network.

## Commit messages

Conventional commits, slightly relaxed:

```
type(scope): short imperative subject

Body explains "why". The diff already shows "what". Wrap at 72 cols.
```

Allowed `type` values: `feat`, `fix`, `refine`, `chore`, `test`,
`docs`, `perf`, `refactor`.

Example: `fix(store): rescue orphan sub-agent sessions from UNKNOWN group`

## Pull-request checklist

- [ ] `xcodebuild test` passes locally and in CI
- [ ] UI changes include a screenshot or short screen recording
- [ ] New features add tests (domain) or list a manual-verification
      procedure (UI) in the PR description
- [ ] Vocabulary is consistent (Session / Turn / Step / SkillGroup / SubAgent)
- [ ] Logging goes through `LoggerService` — no direct `os_log`,
      `print`, `NSLog`, or `dump` in production code
- [ ] Cost-affecting changes are checked against `CostVerifier` drift
      output (Window → Verify Costs…)
- [ ] No hard-coded `/Users/<your-name>/…` paths
      (`grep -rn "/Users/" Lupen LupenTests` returns nothing personal)

## Review principles

- UI changes are validated by **running** the app, not by reading the
  diff. A reviewer who can't reproduce the change locally will ask for
  a screenshot before approving.
- Domain invariants — `CostVerifier` and the ground-truth comparisons
  in `LupenTests/Domain/` — are absolute. A red invariant blocks merge,
  no exceptions.
- The repository has a handful of files larger than the 500-line soft
  cap (`AppStateStore.swift`, `TurnOutlineViewController.swift`). A PR
  that grows any of these by a meaningful amount should propose a
  split as a follow-up issue, even if the split itself isn't part of
  the same PR.

## Filing a bug

A good bug report includes:

1. A minimal JSONL snippet that reproduces the issue. Strip anything
   sensitive first — file paths, project names, prompt text. The
   parser only needs the structural fields (`type`, `uuid`, `parentUuid`,
   `message.usage`, `message.stop_reason`, …) to reproduce most
   parse-and-cost issues. If you don't know what to keep, attach the
   smallest file that reproduces and we'll redact in a follow-up.
2. macOS version (`sw_vers -productVersion`) and Xcode version if
   relevant (`xcodebuild -version`).
3. Steps to reproduce, expected vs. actual.
4. If it's a cost discrepancy: screenshots of both Window → Verify
   Costs… and the affected Turn/Step row in the dashboard.

Open issues at <https://github.com/momoraul/Lupen/issues>.

## Code style

- Swift 6 strict concurrency. New code should compile without
  concurrency warnings.
- No `// swiftlint:disable` blocks for files you didn't already
  inherit them from.
- Comments explain **why**, not what. The "what" is in the diff.
- Domain types are documented at the type level; methods get
  doc-comments only when behaviour isn't obvious from the signature.

## License

By contributing you agree your contributions are licensed under the
same MIT License the project uses ([LICENSE](LICENSE)).
