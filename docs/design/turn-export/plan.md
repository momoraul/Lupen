# Turn Analysis Export — Implementation Plan

*Author: jaden · 2026-07-20 · Depends on [research.md](research.md)*

Ship a **"Export Turn Analysis"** action that turns one selected turn into a
self-contained Markdown document written for an AI to diagnose *why the turn was
expensive or slow* and *what to change in the skill / subagent / prompt*.

---

## 1. Architecture

Follows the `ReportsCSVExporter` contract exactly: **pure, testable Domain code
produces a String; the UI layer owns the save panel and the pasteboard.**

```
Lupen/Domain/Export/
  TurnAnalysisBundle.swift          // the data model (pure, Sendable, Codable)
  TurnAnalysisBundleBuilder.swift   // Turn + context  → Bundle
  TurnRawEnricher.swift             // raw JSONL lines → the fields we don't decode
  TurnAnalysisMarkdownRenderer.swift// Bundle          → String
  TurnExportBudget.swift            // truncation policy (head/tail + markers)
```

No AppKit, no filesystem, no `Date()` inside the builder or renderer — injected —
so every part is unit-testable, matching `ContextComposition` and `ReportsCSVExporter`.

### Why enrich from raw at export time

The highest-value fields (`cache_miss_reason`, `attributionSkill`, `hookInfos`,
`toolUseResult` telemetry, Codex `turn_context`) are not decoded today. Adding them to
`RichEntryDecoder` / `CodexEntry` would require bumping `SnapshotSchema.currentVersion`
or `ProviderDatabase.schemaVersion`, which **wipes and re-indexes the user's entire
corpus** — a heavy, user-visible cost for a rarely-used action.

`TurnRawEnricher` instead reads the turn's own raw lines (via `Step.rawJSON` when the
materialized step already carries it, else `Step.rawJSONLocator` → file seek) and
decodes only what the export needs. Blast radius: this feature only.

> **Task 0 (verify before building):** confirm whether steps returned by
> `SQLiteConversationSource.materializeSteps` already carry `rawJSON` for Claude and
> for Codex. If yes, the enricher needs no file I/O in the common case. If no, it
> falls back to `rawJSONLocator`. This is a factual check, not a guess — do it first.

### Data flow

```
TurnOutlineViewController
  └─ materializedTurn(for:)                    // never export a stub
  └─ displayCost / displayTokens               // same numbers the header shows
  └─ SkillGroupBuilder.group(steps)
  └─ subAgentGraftIndex → [SubAgentLinker.Link]
  └─ TurnTimeline.build(steps:)
  └─ store.contextCompositionContentChars(...) → ContextComposition.make(...)
  └─ TurnRawEnricher.enrich(steps:)            // cache misses, hooks, attribution, telemetry
        ↓
   TurnAnalysisBundleBuilder.build(...)  →  Bundle
        ↓
   TurnAnalysisMarkdownRenderer.render(bundle) → String
        ↓
   UI: NSSavePanel (.md)  |  NSPasteboard
```

---

## 2. The exported document

Structure is the design. Section order is deliberate: **budget → mechanism → evidence
→ ask.** An analyst that reads only the first screen still gets the actionable part.

````markdown
# Lupen Turn Analysis — <project> / <session title>

<!-- lupen-turn-export: v1 -->
| metric | value | vs. session median |
|---|---|---|
| Cost | $2.41 | 6.8× |
| Tokens | 412,905 | 4.1× |
| Duration | 8m 12s | 3.2× |
| Steps | 47 | — |

## What to analyze
This is one turn from an AI coding session. It cost significantly more than a
typical turn in the same session. Identify the top causes and propose concrete
changes to the skill, subagent, or prompt involved. Numbers marked *(derived)*
are attributed from timestamp gaps, not measured — do not over-read them.

## 1. Verdict — where the money went
| driver | cost | share |
|---|---|---|
| Cache writes (3 misses) | $1.31 | 54% |
| Output / reasoning | $0.62 | 26% |
| ... |

⚠ 3 cache misses (`previous_message_not_found`) — the context was re-billed at
input rate instead of cache-read rate.

## 2. Turn context
provider, model(s), effort/personality (Codex), git branch, cwd, start/end,
complete / interrupted / ended-with-API-error, stop reasons, cost confidence

## 3. Token & cost breakdown
per-category table + ContextComposition (Generation vs Context, isEstimate honored)

## 4. Where the time went
lane totals *(derived)* + measured rows: hooks, subagents, WebSearch/Fetch, MCP

## 5. The prompt that started this turn
(full text — this is the artifact most likely to need editing)

## 6. Skills involved
per skill: name · steps · tokens · cost · share of turn   [attributionSkill = ground truth]

## 7. Subagents spawned
per agent: type/nickname · description · model · duration (measured) · tokens ·
tool calls · toolStats (reads/bash/edits/lines±)

## 8. Tool call ledger
| # | tool | input (summary) | result size | latency *(derived)* | error |
+ aggregate by tool name

## 9. Step trace
compact chronological list; bodies truncated per budget

## 10. Questions to answer
1. Which single change would cut the most cost without losing the result?
2. Was any subagent's output worth its cost?
3. Did the prompt under-specify something that caused rework?
4. Were any tool calls redundant or re-reading known content?
5. What caused the cache misses, and is it avoidable?
````

### Truncation policy (`TurnExportBudget`)

- Default total budget ~**60k characters** (fits comfortably in a long-context chat).
- Per-body caps: prompt full; thinking head 2,000; tool input head 1,500; tool result
  **head 1,200 + tail 400**.
- Every cut emits `[… 12,431 characters omitted …]` — the count is the point.
- If the total still exceeds budget, drop §9 step bodies first (keep the ledger),
  then thinking bodies. Record what was dropped in a `## Omitted` note.
- Never silently truncate: a fragment reasoned over as if complete is the main
  failure mode of this kind of export.

### Privacy

- Save-to-file or copy-to-clipboard only. **Nothing is ever sent anywhere by the app.**
- Home directory rewritten to `~` by default.
- Markdown so the user can read it before pasting into an external service.
- The save panel's message states plainly that the file contains prompts, file paths,
  and command output.

---

## 3. UI placement

Three entry points, matching how the app already double-wires actions.

**a) Detail pane header** — primary, most discoverable.
Add an export button to `DetailViewController.trailingClusterStack` (which already
holds the Finder-reveal + toggle and auto-collapses hidden subviews), SF Symbol
`square.and.arrow.up`, tooltip `"Export Turn Analysis…"`. Visible only when the
selection is a turn.

**b) Turn outline context menu** — right-click the expensive row, which is exactly
where the user notices the problem.
Requires subclassing the currently-bare `NSOutlineView` to add
`menu(for event:)` hit-testing plus an injected `menuProvider`, mirroring
`SessionListViewController`. Items: `Export Turn Analysis…` / `Copy Turn Analysis`.
Subject pinned via `representedObject`, not selection.

**c) File menu** — `Export Turn Analysis…`, `⇧⌘E` (free — verified against the
existing shortcut set). `target = nil` so it rides the responder chain and
auto-disables when the dashboard is closed, with a forwarding `@objc` on
`DashboardSplitViewController` per the established pattern.

Save panel copied from `ReportsView.swift:827-875` verbatim (including
`MainActor.assumeIsolated` and the sheet-vs-modal fallback);
`allowedContentTypes = [.markdown]`; filename
`lupen-turn-<provider>-<yyyy-MM-dd-HHmm>.md`.

---

## 4. Phases

**Phase 1 — bundle + renderer + primary entry point**
Everything computable from already-decoded data: aggregates, ContextComposition,
TurnTimeline lanes, SkillGroups, SubAgentLinks, tool ledger, step trace, budget /
truncation, session-relative comparison. Detail-header button + File menu. Tests.

*Deliverable is already useful on its own.*

**Phase 2 — raw enrichment (the part that explains "why")**
`TurnRawEnricher`: `cache_miss_reason`, `attributionSkill`, `attributionMcpServer/Tool`,
`hookInfos[].durationMs`, `toolUseResult` telemetry (`totalDurationMs`, `toolStats`,
`linesAdded/Removed`), `usage.service_tier`; Codex `turn_context`
(`effort`/`personality`/policies) and `function_call.namespace`. Verdict section gains
the cache-miss callout.

**Phase 3 — optional, only if wanted**
Outline context menu (needs the `NSOutlineView` subclass) and a duration-based outlier
hint to sit beside the existing cost-outlier flag.

---

## 5. Task breakdown

### Phase 1
- [x] **T0** Verify `rawJSON` availability on materialized steps (Claude + Codex).
      **Result:** Claude's `claudeSteps` re-decodes through `StepBuilder`, which sets
      `rawJSON: entry.rawJSON` ([StepBuilder.swift:73](../../../Lupen/Domain/Conversation/StepBuilder.swift#L73)),
      so Claude steps carry the raw line. Codex goes through `tableSteps`, which
      builds `Step` values by hand and never sets `rawJSON`. **Both** paths get
      `rawJSONLocator` from `attachLocator`
      ([SQLiteConversationSource.swift:427](../../../Lupen/Store/SQLiteConversationSource.swift#L427)).
      → The enricher needs both paths: prefer `step.rawJSON`, else seek the locator.
- [x] T1 `TurnAnalysisBundle` — model types, `Sendable`, `Codable`, `isEstimate` flags.
- [x] T2 `TurnExportBudget` — head/tail truncation + omission markers.
- [x] T3 `TurnAnalysisBundleBuilder` — assemble from Turn/SkillGroup/Link/Timeline/Composition.
- [x] T4 Session-relative baseline (median turn cost/tokens/duration) for the "vs." column.
- [x] T5 `TurnAnalysisMarkdownRenderer` — §0…§10, tables, honest estimate labels.
- [x] T6 Home-directory redaction.
- [x] T7 Detail-header export button + save panel + copy action.
- [x] T8 File-menu item + `DashboardSplitViewController` forwarding.
- [x] T9 Tests (see §6).

### Phase 2
- [x] T10 `TurnRawEnricher` — Claude fields.
- [x] T11 `TurnRawEnricher` — Codex `turn_context` / `namespace`.
- [x] T12 Verdict cache-miss callout + measured-vs-derived timing merge.
- [x] T13 Graceful degradation when source files are gone.
- [x] T14 Tests for the enricher against fixture lines.

---

## 6. Tests

Placed beside existing suites (`LupenTests/Domain/ReportsCSVExporterTests.swift`,
`LupenTests/Domain/Conversation/`), using `ConversationTestFactory` for fixtures.

- Renderer is deterministic — fixed injected date, snapshot-style string assertions.
- Budget: over-cap body produces head+tail with an **accurate** omitted-character count.
- Truncation never emits a fragment without a marker.
- Estimate labeling: derived durations carry *(derived)*; measured ones do not.
- Aggregates in the document equal `Turn.aggregateCost` / the display values passed in
  (guards the outline↔export desync that `showTurn`'s required parameters guard).
- Empty / orphan / interrupted turn produces a valid document, not a crash.
- Redaction rewrites the home directory and nothing else.
- Enricher: fixture line with `cache_miss_reason` / `hookInfos` / `toolUseResult`
  decodes; a malformed line is skipped without failing the export.
- `I18nGuardTests` continues to pass (English-only UI strings).

Build and test runs will be requested before execution, per the standing rule.

---

## 7. Trade-offs taken

| Decision | Alternative rejected | Reason |
|---|---|---|
| Read raw at export time | Extend the decoders | A schema bump re-indexes the user's whole corpus for a rarely-used action. |
| Markdown | JSON / YAML | Format moves accuracy only a few points; human reviewability before sending user data outward is worth more. |
| Reuse `TurnTimeline` gap attribution | New timing model | A second attribution rule would contradict the timeline card on screen. |
| Single-turn scope | Whole-session export | Matches the ask, and bounds size. Session-level rollups already exist in Reports. |
| Detail-header button first | Context menu first | The context menu needs an `NSOutlineView` subclass; the header button reuses an existing stack. |

---

## 8. Decisions (approved 2026-07-20)

1. **Branch base** — `feat/turn-analysis-export`, branched from `main` (184c788).
2. **Scope** — Phases 1, 2 **and** 3 are all in scope.
3. **Export methods** — save to file **and** copy to clipboard, both from the start.

### Phase 3 tasks (now in scope)
- [x] T15 `TurnOutlineView` — subclass `NSOutlineView`, add `menu(for:)` hit-testing
      and an injected `menuProvider` closure (mirror `SessionListViewController`).
- [x] T16 Context-menu items pinned via `representedObject`:
      `Export Turn Analysis…` / `Copy Turn Analysis`.
- [x] T17 Duration-based outlier hint beside the existing cost-outlier flag —
      session-relative, same shape as `recomputeCostOutlierThreshold`
      (`max(2 × mean of positive turn durations, floor)`).
- [x] T18 Tests for the duration threshold + a context-menu construction test.

### Added during review
- [x] T19 Per-step elapsed time in the step trace (`TraceEntry.derivedSeconds`).
      Omitted from the first draft; the data supports it via `TurnTimeline`'s gap
      rule. Two exclusions keep it honest: a `.prompt` step is **not** charged
      its preceding gap (that is the user composing, not work the turn did), and
      a gap past `TurnTimeline.idleBreakThreshold` is labelled
      _(derived, likely mostly idle)_ rather than reported as compute.
