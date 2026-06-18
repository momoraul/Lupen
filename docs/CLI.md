# `lupen` — command line

Lupen ships a CLI in the same binary as the app: scriptable, local, and
reading the very same index the menu-bar app maintains. Every report the
dashboard shows is available as a table, `--json`, or `--csv`.

```
lupen skills --last 30d
lupen top --by sessions --limit 5
lupen verify            # exit 4 if any cost drifts from the recomputed truth
```

## Install

The CLI is the app's own executable exposed on your `PATH` as `lupen`.

- **Homebrew** (once a release with the CLI ships): `brew install --cask momoraul/lupen/lupen` symlinks `lupen` automatically.
- **DMG / build from source**: run `lupen install-cli` once — it symlinks
  `lupen` into the first writable PATH directory (`/opt/homebrew/bin`,
  `/usr/local/bin`, or `~/.local/bin`). Or symlink it yourself:

  ```
  ln -s /Applications/Lupen.app/Contents/MacOS/Lupen /opt/homebrew/bin/lupen
  ```

`lupen` reads from disk only — no network, no API keys (the same promise as
the app). The index is a cache of `~/.claude` / `~/.codex`; the CLI builds it
itself on first run, so the app need not have been opened.

## Global options

Available on every reporting command:

| Option | Meaning |
|---|---|
| `--provider claude-code\|codex` | Which provider to report on (default: `claude-code`). |
| `--last <Nd\|Nw\|Nm>` | Relative window ending now, e.g. `30d`, `4w`, `1m`. |
| `--month <YYYY-MM>` | A calendar month. |
| `--since <YYYY-MM-DD> --until <YYYY-MM-DD>` | Explicit inclusive range. |
| `--json` / `--csv` | Machine-readable output (mutually exclusive). |
| `--no-color` | Disable ANSI color in tables. |
| `--refresh` / `--no-refresh` | Update the index from the logs first (default: on). |

`--last`, `--month`, and `--since/--until` are mutually exclusive; with none,
all recorded usage is included.

Row reports (`skills`, `daily`, `weekly`, `monthly`, `models`, `projects`)
also take `--limit <N>` and `--sort`.

## Commands

### Spend overview
- **`summary`** (default) — totals for the period: cost, sessions, turns, requests, tokens.
- **`daily`** / **`weekly`** / **`monthly`** — cost & usage per day / ISO week / month. `--sort date` (default) or `cost`; `--limit` keeps the most recent N (or costliest under `--sort cost`).

### Breakdowns
- **`skills`** — per-skill invocations, cost, $/run, and top model. `--sort cost` (default), `count`, or `name`.
- **`models`** — per-model uses + cost.
- **`projects`** — per-project sessions + cost.
- **`top`** — the most expensive `--by sessions` (default) or `--by days`. `--limit` (default 10).

### Find & resume
- **`search <text>`** — full-text search across every prompt, grouped by session (with a snippet). `--limit` (default 20).
- **`resume <session-id>`** — print (or `--run`) the command to reopen a session in its CLI (`claude --resume` / `codex resume`). Pass a full id from `search`/`top --json`.

### Trust & guards
- **`verify`** — recompute every session's cost from the raw logs and diff it against the index. **Exits 4 on any drift** — a CI / pre-commit gate. Audits the whole corpus (period flags don't apply).
- **`budget --over <usd>`** — **exits 4** when spend over the period exceeds the threshold. Scope it with `--last`/`--month`.
- **`statusline`** — a compact one-line spend figure (`$X.XX`, today by default) for a shell prompt or Claude Code `statusLine`. Never refreshes (instant); emits nothing on stderr.

### Index & setup
- **`refresh`** — index new/changed logs now, no report. (Pre-warm for `statusline`/cron.)
- **`config`** — the paths and versions Lupen uses for the current provider.
- **`install-cli`** — symlink `lupen` onto your PATH (DMG installs).

## Exit codes

| Code | Meaning |
|---|---|
| `0` | Success. On an empty index reports still exit 0 — `summary` prints zero totals; the row/breakdown reports print a "No usage…" line. |
| `3` | Nothing to act on: `verify` found no logs to audit, or `install-cli` found no writable PATH directory. |
| `4` | A gate failed: `verify` found drift, or `budget` is over. |
| `64` | Usage error (bad flags / arguments) — ArgumentParser's `EX_USAGE`. |

## Examples

```bash
# This month's spend, by skill, as JSON for jq
lupen skills --month 2026-06 --json | jq '.[0]'

# The five costliest sessions in the last week
lupen top --by sessions --last 7d --limit 5

# Fail CI if this week cost more than $20
lupen budget --over 20 --last 7d

# Gate a commit on cost accuracy
lupen verify || echo "cost drift detected"

# Find a past session and resume it
lupen search "rate limiter" --json | jq -r '.[0].sessionId' | xargs lupen resume

# Today's Claude Code spend in your shell prompt
PROMPT="$(lupen statusline) \$ "
```

JSON keys are stable camelCase (`costUsd`, `avgCostUsd`, …); CSV is RFC-4180
with spreadsheet-formula-injection guarding. Both are safe to pipe.
