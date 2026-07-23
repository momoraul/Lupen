# Turn Analysis Export — Research

*Author: jaden · 2026-07-20*

Goal: when a turn burns unusual time or tokens, let the user export that turn in a
form an AI can analyze, so they can improve the **skill / subagent / prompt** that
caused it.

This document records what the data actually supports. Every claim below was
verified against source or against real on-disk logs; the few things that do **not**
exist are called out explicitly, because the design depends on them not existing.

---

## 1. What a "turn" is in this codebase

`Turn` ([Turn.swift:8](../../../Lupen/Domain/Conversation/Turn.swift#L8)) is deliberately thin —
`id`, `sessionId`, `steps: [Step]`, `isInterrupted`. Everything else is derived.

**All the payload lives on `Step`** ([Step.swift:35](../../../Lupen/Domain/Conversation/Step.swift#L35)):
`kind`, `timestamp`, `text`, `thinkingText`, `toolCalls: [ToolUseInfo]`,
`toolResult: ToolResultInfo?`, `model`, `stopReason`, `tokens`, `cost`,
`isSidechain`, `agentId`, `attachments`, `rawJSONLocator`.

There is no `Turn.model` and no `Turn.duration`.

### Turn rows are stubs until materialized

Under SQLite-first, the outline builds **header stubs** — a synthetic single-step
`Turn` carrying only `prompt_preview` — with real numbers held separately in
`Snapshot.aggregates`. Full steps are reconstructed on demand by
`SQLiteConversationSource.materializeSteps`, which seeks `raw_locators` byte offsets
and re-decodes the original JSONL lines.

**Consequence for export:** the export must run on a *materialized* turn.
`TurnOutlineViewController.materializedTurn(for:)` already does this before handing a
turn to the detail pane; the export action must go through the same call or it will
serialize an empty `steps` array.

### Tool payloads are not in the database

`steps` stores tool *identity* only — `tool_name`, `tool_use_id`, `tool_input_chars`,
`tool_result_chars`, `tool_summary`. Input JSON and result bodies live **only** in the
original JSONL, by design ("raw lines are the payload store").

So a full-fidelity export requires the source file to still exist at the recorded
offsets. That is the same requirement the Raw tab already has — acceptable — but the
exporter must degrade gracefully when a file has been deleted or rotated.

---

## 2. Timing — what is measured vs. what must be estimated

**This is the single most important finding, and it constrains the whole design.**

I enumerated every duration-shaped field in a real 13k-line Claude log and in a
120k-line Codex rollout.

### There is no per-request latency and no TTFT

Claude entries carry `timestamp` (ISO8601, **millisecond** precision) and nothing else
time-related. A grep for `ttft` matched only base64 blobs inside attachment payloads —
not a field. There is no `summary`-type entry on this machine either.

So **per-step and per-tool duration must be derived from timestamp deltas.** The
codebase already has exactly one convention for this, in
[TurnTimeline.swift:97](../../../Lupen/Domain/Conversation/Story/TurnTimeline.swift#L97):

> every gap belongs to the step that arrives at its end

because JSONL timestamps are *arrival* times. Lane totals then sum exactly to wall
clock, and parallel tool results split their shared wait. The export must reuse this
rule verbatim — inventing a second attribution would make the exported numbers
disagree with the timeline card the user is looking at.

### The durations that ARE measured

| Source | Field | Covers |
|---|---|---|
| Claude | `hookInfos[].durationMs` (197×) | each hook invocation |
| Claude | `attachment.durationMs` (492×) | hook execution |
| Claude | `toolUseResult.totalDurationMs` (41×) | a whole subagent run |
| Claude | `toolUseResult.durationSeconds` / `durationMs` | WebSearch / WebFetch |
| Claude | `compactMetadata.durationMs` | compaction |
| Codex | `mcp_tool_call_end.duration` | one MCP call |

**Design rule:** the export labels every duration as either *measured* or *derived*.
Mixing them silently would let an AI analyst confidently blame the wrong thing.
The app already holds this line elsewhere — `ContextComposition.Slice.isEstimate`
exists for exactly this reason.

---

## 3. High-value fields we currently discard

Verified present on disk, verified absent from our code (`grep -rl` over `Lupen/`
returned zero hits for each).

### Claude Code

| Field | Example | Why it matters for this feature |
|---|---|---|
| `message.diagnostics.cache_miss_reason` | `{"type":"previous_message_not_found"}` — 253× in one session | **The direct answer to "why was this turn expensive."** A cache miss re-bills the whole context at input rate instead of cache-read rate. Nothing else in our data explains a sudden cost spike. |
| `attributionSkill` | `"code-review"` | Stamped on **every** assistant entry while a skill is active — ground truth. `SkillGroupBuilder` currently *infers* spans from step ordering ([SkillGroupBuilder.swift:291](../../../Lupen/Domain/Conversation/SkillGroupBuilder.swift#L291)). |
| `attributionMcpServer` / `attributionMcpTool` | `ccd_session` / `mark_chapter` | Separates MCP cost from native tool cost. |
| `hookInfos[].durationMs` | `peon.sh 131ms` | The only measured latency the user can act on directly. |
| `toolUseResult` (Agent) | `totalDurationMs`, `totalTokens`, `totalToolUseCount`, `toolStats{readCount,bashCount,linesAdded,…}`, `agentType`, `resolvedModel` | Per-subagent efficiency — exactly the "was this subagent worth it" question. |
| `toolUseResult` (Bash/Edit) | `stdout`/`stderr` split, `structuredPatch`, `linesAdded/Removed` | Lets the analyst see *what the tool actually did*, not just its name. |
| `usage.service_tier`, `usage.server_tool_use` | | Tier and server-side tool counts. |
| subagent `.meta.json` sidecar | `{agentType, description, toolUseId, spawnDepth}` | `spawnDepth` and `attributionAgent` unread. |

### Codex

| Field | Why |
|---|---|
| `turn_context` — `effort`, `personality`, `approval_policy`, `sandbox_policy`, `collaboration_mode` | Per-turn configuration. `effort` in particular changes reasoning-token volume, so it is a first-order explanation for an expensive turn. We decode only `turn_id`/`cwd`/`model`. |
| `function_call.namespace` | `multi_agent_v1`, `mcp__serena`, … — a clean MCP-vs-native discriminator, not even in `CodingKeys`. |
| `token_count.rate_limits` | `plan_type`, `credits`, `rate_limit_reached_type`. |
| `mcp_tool_call_end.duration` | Decoded as untyped `CodexJSONValue`, never surfaced as a number. |
| `session_meta` — `base_instructions`, `dynamic_tools`, `memory_mode` | Baseline context the model carries. |

Codex subagents are already handled **better** than Claude skills: `spawn_agent` args
give `agent_type` and the output gives `{agent_id, nickname}`, and we read both.

### How to reach these fields without touching the import path

`RichEntry.rawJSON: Data` preserves the complete original line, and every `Step` has a
`rawJSONLocator`. So the exporter can pull these fields **at export time** from the raw
lines.

This matters a lot: adding them to the decoders would mean bumping
`SnapshotSchema.currentVersion` and/or `ProviderDatabase.schemaVersion`, which **wipes
and re-indexes the user's entire corpus**. For a rarely-used, user-initiated export
that trade is not worth it. Read raw, decode locally, keep the hot path untouched.

---

## 4. What we can already compute (no new parsing)

- `Turn.aggregateTokens` / `aggregateCost`, and the `…IncludingSubAgents` variants
  (outline-header display only — they double-count on a reporting path).
- `SkillGroupBuilder.SkillGroup` — per-skill span with aggregate tokens/cost, plus
  `hasToolResult` / `hasIsMetaAnchor` diagnostics.
- `SubAgentLinker.Link` — `subagentType`, `description`, `workflowName`,
  `workflowDurationMs`, `workflowTelemetryTokens`, `workflowToolCalls`.
- `ContextComposition` — Generation vs Context split by category, with honest
  `isEstimate` flags and a cost-by-category bar that reconciles to the real total.
- `TurnTimeline.Model` — lanes, per-segment durations, idle-break compression,
  and a ready-made `summaryText` ("3m 42s · Bash 62% · Thinking 18%").
- `CostConfidence` — whether a cost is exact or partial.

That is already most of an analysis bundle. The raw-field enrichment in §3 is what
turns it from "here are the numbers" into "here is *why*".

---

## 5. Existing UI surface

- **Cost-outlier highlighting already exists**
  ([TurnOutlineViewController.swift:286](../../../Lupen/UI/Dashboard/TurnOutlineViewController.swift#L286)):
  a turn reads as expensive at `max(2 × session mean of positive turn costs, $1)`.
  Session-relative on purpose — a fixed $10 line painted every row orange.
  **There is no duration-based flag or sort.** The outline's only time column is
  "Started", not elapsed.
- **No context menu on the turn outline.** The outline is a bare `NSOutlineView()`;
  adding one means subclassing it and injecting a `menuProvider`, mirroring
  `SessionListViewController`'s pattern (the subclass only hit-tests; the VC builds
  the menu and pins the subject via `representedObject`).
- **Export precedent is unambiguous.** `ReportsCSVExporter` is a pure, UI-free enum;
  the UI owns `NSSavePanel` (`ReportsView.swift:827-875`, including the
  `MainActor.assumeIsolated` idiom and the sheet-if-key-window-else-modal fallback).
  Copy-to-clipboard precedent is `CardCopyButton` + the pure
  `ConversationBlockCopy.plainText(for:)`.
- **Main menu** is built in code in `AppDelegate.setupMainMenu()`. State-dependent
  items use `target = nil` and travel the responder chain, so AppKit auto-disables
  them when the dashboard is closed; `DashboardSplitViewController` re-declares and
  forwards such selectors so shortcuts work regardless of focus.
- **No localization.** English string literals inline, enforced by
  `LupenTests/I18nGuardTests.swift` (fails if Hangul appears in a string literal under
  `Lupen/UI/`). All new user-facing text must be English; `…` for panel-opening items.

---

## 6. What format should the export be?

I checked the current evidence rather than assuming. Across a 9,649-trial benchmark
over 11 models and 4 formats, **format choice moved accuracy only −7.7%…+2.7%, while
model capability accounted for a 21-point gap** ([Notation Matters,
arXiv](https://arxiv.org/pdf/2605.29676);
[nested-format comparison](https://www.improvingagents.com/blog/best-nested-data-format/)).
YAML edged out others on some models; XML consistently underperformed.

**Conclusion: format is a second-order decision. Content selection, truncation
honesty, and task framing are first-order.** So optimize for those, and pick the
format on secondary criteria:

- **Markdown**, because the user must be able to *read the file before pasting it into
  an external AI*. This is user data — prompts, file contents, command output. A
  human-reviewable artifact is a privacy feature, not a cosmetic one.
- Numbers go in **markdown tables** (dense, unambiguous, no brace noise).
- A small **machine-readable header block** carries schema version and the key metrics
  so a tool could parse it later without re-deriving anything.

### What the document must do that a raw transcript dump does not

1. **State the budget up front** — cost, tokens, duration, and how far each is above
   the session's own baseline. Without a comparison an analyst cannot tell "expensive"
   from "big task".
2. **Rank the cost drivers**, so attention lands in the right place.
3. **Separate measured from derived** (§2).
4. **Name the mechanism** where we know it — `cache_miss_reason` is the clearest
   example.
5. **Truncate loudly.** Tool outputs are unbounded. Head/tail with an explicit
   `[… N characters omitted …]` marker so the model knows something was cut and how
   much, instead of silently reasoning over a fragment.
6. **Ask the questions.** End with the specific asks — which skill/subagent/prompt to
   change and how — otherwise the model writes a summary instead of a fix.

---

## 7. Constraints and risks

| Risk | Handling |
|---|---|
| Turn is a stub → empty export | Route through `materializedTurn(for:)`; assert non-empty steps. |
| Source JSONL deleted/rotated → no tool payloads | Degrade to the DB projection and say so in the document. |
| Unbounded size (a turn can hold MBs of tool output) | Character budget with head/tail truncation and explicit omission markers. |
| Privacy — export contains prompts, paths, file contents, command output | Save/copy only; never auto-send. Redact the home directory to `~` by default. Markdown so the user can read it first. |
| Schema-version bump would re-index the whole corpus | Read raw at export time; do not touch the decoders. |
| Double-counting subagents | Use plain `aggregate*` for reporting figures; use `…IncludingSubAgents` only where the outline header already does. |
| New Hangul UI strings | `I18nGuardTests` fails the build. English only. |

---

## 8. Open question for the user

The current branch `feat/live-session-follow` sits 3 commits ahead of `main` and is
unmerged, and `release/0.9.0` is still in flight. Starting this feature on top of
unmerged work would entangle them. **Recommendation: branch from `main`.**
