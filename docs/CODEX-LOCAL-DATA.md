# Codex Local Data

Lupen's Codex support reads local rollout JSONL written by Codex. It makes no
network calls, does not require API keys, and does not write Lupen cache files
inside the Codex home.

This implementation was cross-checked against CodeBurn's public Codex provider
notes and source, especially the same high-risk areas: first-line validation,
large `session_meta` lines, cumulative token deduplication, mixed
`last_token_usage`/`total_token_usage`, cached-input normalization, and avoiding
empty-cache poisoning for transient read failures:

- https://github.com/getagentseal/codeburn/blob/main/docs/providers/codex.md
- https://github.com/getagentseal/codeburn/blob/main/src/providers/codex.ts

## Roots And Discovery

Codex home resolution:

1. Explicit `codexRootPath` setting, when supplied by the app.
2. `$CODEX_HOME`.
3. `~/.codex`.

Session files are discovered below:

```text
<codex-home>/sessions/YYYY/MM/DD/rollout-*.jsonl
```

Lupen accepts a rollout file only when its first line is readable as
`session_meta` and the originator starts with `codex` case-insensitively. The
first-line reader is capped at 1 MiB so modern Codex metadata with large system
prompt fields is accepted while corrupt files without a newline stay bounded.

`session_index.jsonl`, when present, is used as a title hint source. The
conversation itself remains authoritative for turns, usage, and raw payloads.

## Session Metadata

`CodexSessionMetadataReader` extracts:

- raw session id from `payload.id`, `payload.session_id`, or filename fallback
- created timestamp
- `cwd` project path
- originator
- CLI version, when present
- model hint, when present
- `forked_from_id`, when present

The Lupen session id is provider-scoped:

```text
codex:<raw-session-id>
```

The raw id is preserved on the `Session` for source-specific lookup and display
logic.

## Line Model

`CodexLineReader` decodes rollout JSONL into `CodexEntry`. It preserves raw line
bytes for Raw-tab display and usage-event lookup.

Important entry shapes:

| Codex line | Lupen use |
| --- | --- |
| `session_meta` | session id, cwd, model, fork metadata |
| `turn_context` | current turn id and model |
| `response_item` + `message` + `role=user` | prompt step |
| `event_msg` + `user_message` | prompt fallback/sidecar |
| `response_item` + `message` + `role=assistant` | reply step |
| `event_msg` + `agent_message` | reply step |
| `response_item` + `reasoning` | thought step |
| `event_msg` + `agent_reasoning` | thought step |
| `response_item` + `function_call` | tool call step |
| `response_item` + `function_call_output` | tool result step |
| `event_msg` + `patch_apply_end` | edit result step |
| `event_msg` + `token_count` | usage event attached to the current turn |
| `turn_aborted` / `task_complete` | turn terminator |

Tool display names are normalized into Lupen's existing vocabulary:

- `exec_command`, `shell_command` -> Bash
- `read_file` -> Read
- `write_file`, `apply_diff`, `apply_patch` -> Edit
- `spawn_agent`, `close_agent`, `wait_agent` -> Agent
- `read_dir`, `list_dir` -> Glob

## Unsupported And Unknown Data

Codex rollout JSONL is still evolving, so Lupen treats local data support as an
explicit allowlist rather than assuming every decoded object is safe to display.

Supported line-shape allowlist:

| `entry.type` | Supported `payload.type` values |
| --- | --- |
| `session_meta` | Top-level metadata line |
| `turn_context` | Top-level turn context |
| `turn_aborted` | Top-level terminator |
| `task_complete` | Top-level terminator |
| `response_item` | `message`, `reasoning`, `function_call`, `custom_tool_call`, `function_call_output`, `custom_tool_call_output` |
| `event_msg` | `turn_context`, `user_message`, `agent_message`, `agent_reasoning`, `token_count`, `patch_apply_begin`, `patch_apply_end`, `turn_aborted`, `task_complete` |

Any decoded line outside that allowlist emits `codexUnknownLineType` with an
`entry.type/payload.type` label. Lupen keeps the raw line available for the Raw
tab, but it does not turn the unknown shape into a conversation row, attachment,
or usage request until the parser is deliberately taught that shape.

Malformed JSON is counted as a rejected line. If the first line is not a valid
Codex `session_meta`, the rollout file is rejected as a source. If a later line
is malformed, the readable lines still load and the Codex load summary exposes
the rejected-line count.

Known-but-limited fields:

- `info.model_context_window` is preserved on the token breakdown and shown in
  the Codex conversation outline as `Ctx` only when at least one visible turn has
  that value.
- `patch_apply_end.payload.changes` is used only for changed-file keys in the
  conversation outline; nested patch metadata is left in Raw.
- Unknown payload keys are ignored by the normalized model. The original JSONL
  bytes remain available through Raw-tab lookup.
- `custom_tool_call` and `custom_tool_call_output` are displayed through the
  generic tool-call/tool-result path. Novel custom-tool input fields may need
  additional attachment extraction before they appear in the Attachments tab.

Unavailable Codex fields:

- Claude-style TTL is not present in current Codex local JSONL.
- Claude-style cache-write tokens are not present. `cached_input_tokens` is
  treated as cached-read input only.
- A Codex-specific official billed-cost field is not present. Lupen computes
  local estimates from token usage and known model rates.

## Turn Assembly

Codex does not use Claude Code's `parentUuid`/`stop_reason` conversation model.
`CodexConversationAssembler` builds turns from Codex-specific signals:

1. `turn_context.payload.turn_id`, when present.
2. A new user message when no turn id is present.
3. Generated chronological turn ids as a fallback.
4. `task_complete`/`turn_aborted` as terminators.

If both `response_item/message role=user` and `event_msg/user_message` carry the
same prompt, the event message is skipped so the outline does not show duplicate
prompt rows.

Usage is applied to the nearest relevant assistant/tool/stop step in the same
turn. If a usage event has no visible step to attach to, Lupen creates a compact
reply-like usage carrier so the cost is still visible.

## Token Normalization

Codex token events may provide:

- `info.last_token_usage`: per-event usage
- `info.total_token_usage`: cumulative usage

Lupen uses `last_token_usage` when available. When only cumulative totals are
present, it computes a delta from the previous cumulative event.

OpenAI-style cached input is inclusive: `input_tokens` includes
`cached_input_tokens`. Lupen normalizes this into its provider-neutral token
model:

```text
fresh input       = max(0, input_tokens - cached_input_tokens)
cache read input  = cached_input_tokens
output            = output_tokens
reasoning output  = reasoning_output_tokens
cache creation    = 0
```

Reasoning output is kept as a separate token count and folded into output cost
for pricing.

## Deduplication And Forks

Codex can emit repeated cumulative totals. Lupen skips duplicate cumulative
events after the first observed cumulative value. The first event is not treated
as a duplicate merely because its cumulative total is zero.

Mixed streams are supported:

- `last_token_usage` can be used for the current event.
- `total_token_usage`, when present, still advances the cumulative baseline.
- A later cumulative-only event therefore deltas against the latest total, not
  a stale zero baseline.

Forked Codex sessions can replay parent usage near the fork start. When
`forked_from_id` and a created timestamp are available, Lupen skips token events
inside the initial 5-second fork replay window.

## Cost And Pricing

Lupen does not assume there is a Codex-specific official billing table. Codex
costs are computed from the model name through Lupen's `PricingTable` when a
rate is known.

Unknown Codex pricing is visible:

- the loader increments `unknownPricingCount`
- verification reports an unknown-pricing issue
- cost calculation returns unavailable (`nil`) rather than silently inventing a
  provider-specific price

This keeps token accounting useful even when a new Codex model appears before
the app's pricing table is updated.

### Cost Confidence

Codex cost values are local estimates, not official Codex billing records. The
calculation starts from rollout `token_count` events, normalizes the token
fields, and applies the matching Lupen `PricingTable` model rate:

```text
cost = fresh input + cached input + output + reasoning output
```

Reasoning output is priced with the output rate. Codex JSONL currently has no
Claude-style TTL or cache-write token fields, so those fields are not part of
the Codex cost model.

Lupen exposes confidence instead of treating every dollar value as equally
trusted:

| Confidence | When it applies | UI contract |
| --- | --- | --- |
| `exact` | Every billable Codex request has a model, known pricing, and computed cost. | Show the dollar value normally. It is still a local estimate from logs and rates, not an official bill. |
| `partial` | Some requests have known pricing and some do not. | Show an approximate value with `≈`; the total includes only known-rate requests. |
| `unavailable` | Usage exists, but pricing is unavailable for all billable requests. | Show `N/A` instead of `$0`. |
| `notBillable` | No token-bearing requests exist. | Show the normal empty/zero-cost state. |

Missing model names, unknown model names, or known models whose cost could not
be computed reduce confidence. Synthetic usage carrier rows are not treated as
pricing failures because they only make otherwise hidden usage visible in the
conversation outline.

## Raw Payload Lookup

Codex usage request ids are scoped and deterministic:

```text
codex:<session-id>:token_count:<turn-id>:<ordinal>
```

`AppStateStore.rawPayload(for:)` first checks in-memory raw payloads. If a
snapshot restore or mode switch left only the request/source indexes in memory,
it lazily rereads the source rollout file, rebuilds the usage raw-payload map,
and returns the matching token-count line.

## Conversation Attachments

Codex turns run through the same attachment manifest used by Claude turns before
they are cached. Prompt absolute paths become prompt mentions, Codex
`shell_command`/`exec_command` `cmd` inputs map to `Bash`, `read_file` and
`write_file` inputs map to file tool rows, and `apply_patch` patch headers are
resolved against the session `cwd` when the JSONL only stores relative paths.

Codex agent tools are normalized before display: `spawn_agent` is shown as
`Agent`, `wait_agent` as `AgentWait`, and `close_agent` as `AgentClose`.
Tool rows summarize agent type, description, id, and status instead of showing
raw JSON when those fields are present.

## Snapshot Cache

Codex parsing has a Lupen-owned snapshot cache under Application Support:

```text
~/Library/Application Support/Lupen/providers/codex/usage_snapshot.json
```

The cache is keyed by:

- resolved Codex home path
- every discovered rollout file path/size/mtime
- `session_index.jsonl` path/size/mtime when the title index exists
- snapshot schema version

Load outcomes:

- `hit`: all input fingerprints match. Lupen restores sessions, turns, source
  indexes, bookmarks, and request costs from the snapshot. The result reports
  `parsedRolloutFileCount == 0`.
- `partial`: only some rollout files changed/vanished or the title index
  changed. Lupen reuses unchanged sessions, reparses changed rollout files, drops
  removed rollout files, updates title hints, saves a fresh snapshot, and shows
  `partial` in the Codex load summary. Title-index-only changes keep
  `parsedRolloutFileCount == 0`; changed rollout files increment it.
- `miss`: no valid baseline exists, the Codex home changed, schema changed, or
  the inputs are too different for an incremental merge. Lupen does a full parse
  and saves a new snapshot.

The sidebar summary and load log both include the parsed rollout count so a
startup can be verified as a true cache hit without launching Instruments.

The snapshot intentionally does not store raw payload bytes. Raw-tab lookup
falls back to rereading the source rollout file on demand, which keeps startup
memory lower and avoids persisting large local transcripts twice.

Codex Usage detail rendering reads the same raw `token_count` JSONL line and
formats `payload.info.last_token_usage` and `payload.info.total_token_usage`.
This keeps the Raw tab authoritative while giving Codex sessions a useful Usage
tab even though they do not use Claude's `message.usage` shape.

Diagnostics are generated for full parses and for changed files in partial
loads. A pure cache hit returns no new diagnostic batches because no source
lines were decoded during that launch.

## Live Updates

Codex mode watches `<codex-home>/sessions`.

- File events refresh the changed rollout file from the beginning.
- Directory events discover new `YYYY/MM/DD` folders and new rollout files.
- Bookmark offsets are standardized to avoid `/var` vs `/private/var` duplicate
  keys.
- A file shrink logs a warning and preserves the previous good state.
- A torn or unreadable rollout file is skipped and left unbookmarked.

Refreshing from the full file is intentionally conservative. Codex token
deduplication depends on cumulative state, so an append-only slice is not always
enough to produce correct usage without additional persisted per-file parser
state.

After live refreshes, Lupen asynchronously refreshes the Codex usage snapshot
from the current in-memory state. This makes the next app launch or provider
switch eligible for a cache hit without writing any Lupen-owned state into the
Codex home.

## Verification

`CodexUsageVerifier` is independent from the main loader. It reads rollout files
again, extracts usage lines, applies its own dedup/fork/normalization rules, and
compares the result against the active Codex view.

It checks:

- session presence
- usage/request count
- fresh input tokens
- cached input tokens
- output tokens
- reasoning output tokens
- cost totals when pricing is known
- missing usage events
- unknown pricing
- duplicate cumulative handling

Verification results are not written into parse diagnostics. They live in the
Verify Usage window/report so data-format drift and manual accounting audits
stay separate.
