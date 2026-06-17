#!/usr/bin/env python3
#
# lupen-generate-corpus.py — synthetic large-corpus generator for Lupen.
# Author: jaden (2026/06/10)
#
# Generates 10 GB-class Claude Code + Codex corpora for the SQLite-first
# refactor's budget and memory runs (plan.md tasks 0.3 / 0.5 / 2.10 and the
# Phase 3/5 gates). Volume generator only — semantic edge cases (duplicate
# rollout groups, replay trimming, forks, …) live in the test-target
# RefactorFixtureCorpus; line shapes here mirror the same proven formats.
#
# Usage:
#   Tools/lupen-generate-corpus.py --output /tmp/lupen-corpus \
#       [--claude-mb 512] [--codex-mb 512] [--days 30] [--seed 42] [--verify]
#
# Output layout:
#   <output>/projects/<project>/<sessionId>.jsonl            Claude sessions
#   <output>/projects/<project>/<sessionId>/subagents/...    ~10% of sessions
#   <output>/codex/sessions/YYYY/MM/DD/rollout-*.jsonl       Codex rollouts
#   <output>/codex/session_index.jsonl                       visible subset (~60%)
#
# Composition (fixed rates, mirroring production pain points):
#   ~1%   huge assistant lines (~512 KB; type key far outside tail window)
#   ~0.1% corrupt lines (malformed JSON → error diagnostics at scale)
#   ~10%  Claude sessions carry a subagent child (Agent link + sidechain file)
#   Codex: one oversized rollout (~25% of the codex byte budget) to exercise
#          streaming readers; the rest spread across --days daily files.

import argparse
import io
import json
import os
import random
import sys
import uuid
from datetime import datetime, timedelta, timezone

HUGE_LINE_RATE = 0.01
CORRUPT_LINE_RATE = 0.001
SUBAGENT_SESSION_RATE = 0.10
HUGE_PADDING_BYTES = 512 * 1024
VISIBLE_INDEX_RATE = 0.60
WRITE_BUFFER_BYTES = 4 * 1024 * 1024

WORDS = (
    "refactor sqlite index session turn step cost token cache parse rollout "
    "provider sidebar conversation report search diagnostics workflow agent "
    "memory budget watchdog streaming provenance coverage"
).split()


def iso(ts: datetime) -> str:
    return ts.strftime("%Y-%m-%dT%H:%M:%S.000Z")


def codex_iso(ts: datetime) -> str:
    return ts.strftime("%Y-%m-%dT%H:%M:%SZ")


def sentence(rng: random.Random, words: int) -> str:
    return " ".join(rng.choice(WORDS) for _ in range(words))


class Budget:
    """Tracks bytes written toward a target."""

    def __init__(self, target_bytes: int):
        self.target = target_bytes
        self.written = 0

    @property
    def exhausted(self) -> bool:
        return self.written >= self.target

    def add(self, n: int):
        self.written += n


def write_lines(path: str, lines, budget: Budget):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with io.open(path, "w", encoding="utf-8", buffering=WRITE_BUFFER_BYTES) as f:
        for line in lines:
            f.write(line)
            f.write("\n")
            budget.add(len(line) + 1)


# MARK: Claude

def claude_user_line(sid: str, u: str, parent, ts: datetime, text: str) -> str:
    p = f'"{parent}"' if parent else "null"
    return (
        f'{{"type":"user","uuid":"{u}","parentUuid":{p},"sessionId":"{sid}",'
        f'"isSidechain":false,"timestamp":"{iso(ts)}",'
        f'"message":{{"role":"user","content":"{text}"}}}}'
    )


def claude_assistant_line(
    sid: str, u: str, parent: str, req: str, ts: datetime,
    text: str, inp: int, out: int, sidechain: bool = False, agent_id: str = ""
) -> str:
    side = "true" if sidechain else "false"
    agent = f'"agentId":"{agent_id}",' if agent_id else ""
    return (
        f'{{"type":"assistant","uuid":"{u}","parentUuid":"{parent}","sessionId":"{sid}",'
        f'"isSidechain":{side},{agent}"timestamp":"{iso(ts)}","requestId":"{req}",'
        f'"message":{{"id":"msg-{u}","role":"assistant","model":"claude-sonnet-4-6",'
        f'"stop_reason":"end_turn","content":[{{"type":"text","text":"{text}"}}],'
        f'"usage":{{"input_tokens":{inp},"output_tokens":{out}}}}}}}'
    )


def claude_agent_call_line(sid: str, u: str, parent: str, req: str, ts: datetime, tool_use_id: str) -> str:
    return (
        f'{{"type":"assistant","uuid":"{u}","parentUuid":"{parent}","sessionId":"{sid}",'
        f'"isSidechain":false,"timestamp":"{iso(ts)}","requestId":"{req}",'
        f'"message":{{"id":"msg-{u}","role":"assistant","model":"claude-sonnet-4-6",'
        f'"stop_reason":"tool_use","content":[{{"type":"tool_use","id":"{tool_use_id}",'
        f'"name":"Agent","input":{{"description":"generated agent","subagent_type":"general-purpose"}}}}],'
        f'"usage":{{"input_tokens":8,"output_tokens":4}}}}}}'
    )


def claude_tool_result_line(sid: str, u: str, parent: str, ts: datetime, tool_use_id: str, agent_id: str) -> str:
    body = (
        "Async agent launched successfully.\\n"
        f"agentId: {agent_id} (internal ID - do not mention to user.)"
    )
    return (
        f'{{"type":"user","uuid":"{u}","parentUuid":"{parent}","sessionId":"{sid}",'
        f'"isSidechain":false,"timestamp":"{iso(ts)}",'
        f'"message":{{"role":"user","content":[{{"type":"tool_result",'
        f'"tool_use_id":"{tool_use_id}","content":"{body}"}}]}}}}'
    )


def generate_claude(out_dir: str, budget: Budget, days: int, rng: random.Random, stats: dict):
    projects_dir = os.path.join(out_dir, "projects")
    now = datetime(2026, 6, 10, 12, 0, 0, tzinfo=timezone.utc)
    project_count = 6
    project_names = [f"-Users-example-GenProject-{i}" for i in range(project_count)]

    while not budget.exhausted:
        sid = str(uuid.uuid4())
        project = rng.choice(project_names)
        day_offset = rng.randrange(days)
        ts = now - timedelta(days=day_offset, minutes=rng.randrange(600))
        turn_count = rng.randrange(4, 40)
        lines = []
        parent = None
        for t in range(turn_count):
            u_user = f"{sid[:8]}-u{t}"
            u_asst = f"{sid[:8]}-a{t}"
            req = f"req-{sid[:8]}-{t}"
            ts = ts + timedelta(seconds=rng.randrange(5, 90))
            if rng.random() < CORRUPT_LINE_RATE:
                lines.append('{"type":"assistant","uuid":"broken THIS IS NOT JSON')
                stats["claude_corrupt_lines"] += 1
            lines.append(claude_user_line(sid, u_user, parent, ts, sentence(rng, rng.randrange(4, 30))))
            if rng.random() < HUGE_LINE_RATE:
                text = "x" * HUGE_PADDING_BYTES
                stats["claude_huge_lines"] += 1
            else:
                text = sentence(rng, rng.randrange(10, 120))
            lines.append(claude_assistant_line(
                sid, u_asst, u_user, req, ts + timedelta(seconds=2),
                text, rng.randrange(100, 20_000), rng.randrange(50, 4_000)
            ))
            parent = u_asst

        has_subagent = rng.random() < SUBAGENT_SESSION_RATE
        if has_subagent:
            agent_id = uuid.uuid4().hex[:17]
            tool_use_id = f"toolu_{uuid.uuid4().hex[:12]}"
            u_call = f"{sid[:8]}-agentcall"
            lines.append(claude_agent_call_line(
                sid, u_call, parent, f"req-{sid[:8]}-agent", ts + timedelta(seconds=3), tool_use_id
            ))
            lines.append(claude_tool_result_line(
                sid, f"{sid[:8]}-agentres", u_call, ts + timedelta(seconds=4), tool_use_id, agent_id
            ))

        session_path = os.path.join(projects_dir, project, f"{sid}.jsonl")
        write_lines(session_path, lines, budget)
        stats["claude_sessions"] += 1
        stats["claude_files"] += 1

        if has_subagent:
            child_lines = [
                f'{{"type":"user","uuid":"{agent_id}-u1","parentUuid":null,"sessionId":"{sid}",'
                f'"timestamp":"{iso(ts + timedelta(seconds=5))}","isSidechain":true,"agentId":"{agent_id}",'
                f'"message":{{"role":"user","content":"child prompt"}}}}',
                claude_assistant_line(
                    sid, f"{agent_id}-a1", f"{agent_id}-u1", f"req-{agent_id}",
                    ts + timedelta(seconds=6), sentence(rng, 40),
                    rng.randrange(100, 5_000), rng.randrange(50, 2_000),
                    sidechain=True, agent_id=agent_id
                ),
            ]
            child_path = os.path.join(
                projects_dir, project, sid, "subagents", f"agent-{agent_id}.jsonl"
            )
            write_lines(child_path, child_lines, budget)
            stats["claude_subagent_files"] += 1
            stats["claude_files"] += 1


# MARK: Codex

def codex_meta_line(raw_id: str, ts: datetime) -> str:
    return (
        f'{{"type":"session_meta","timestamp":"{codex_iso(ts)}",'
        f'"payload":{{"id":"{raw_id}","timestamp":"{codex_iso(ts)}",'
        f'"cwd":"/Users/example/GenCodexProject","originator":"codex_cli_rs","model":"gpt-5.3-codex"}}}}'
    )


def codex_turn_context_line(turn_id: str, ts: datetime) -> str:
    # Real rollouts carry turn_context with explicit turn ids; without them
    # the aggregator's and ground-truth verifier's fallback turn-id
    # generation diverges for multi-turn sessions.
    return (
        f'{{"type":"turn_context","timestamp":"{codex_iso(ts)}",'
        f'"payload":{{"type":"turn_context","turn_id":"{turn_id}","model":"gpt-5.3-codex"}}}}'
    )


def codex_user_line(text: str, ts: datetime) -> str:
    return (
        f'{{"type":"response_item","timestamp":"{codex_iso(ts)}",'
        f'"payload":{{"type":"message","role":"user","content":[{{"type":"input_text","text":"{text}"}}]}}}}'
    )


def codex_assistant_line(text: str, ts: datetime) -> str:
    return (
        f'{{"type":"response_item","timestamp":"{codex_iso(ts)}",'
        f'"payload":{{"type":"message","role":"assistant","content":[{{"type":"output_text","text":"{text}"}}]}}}}'
    )


def codex_token_line(inp: int, cached: int, out: int, reasoning: int, ts: datetime, turn_id: str) -> str:
    # turn_id rides on the token event itself (as in real rollouts) so the
    # usage aggregator and the ground-truth verifier derive identical
    # request ids regardless of their differing turn-tracking fallbacks.
    total = inp + out + reasoning
    return (
        f'{{"type":"event_msg","timestamp":"{codex_iso(ts)}",'
        f'"payload":{{"type":"token_count","turn_id":"{turn_id}","info":{{"last_token_usage":{{'
        f'"input_tokens":{inp},"cached_input_tokens":{cached},"output_tokens":{out},'
        f'"reasoning_output_tokens":{reasoning},"total_tokens":{total}}}}}}}}}'
    )


def codex_rollout_lines(raw_id: str, ts: datetime, turn_count: int, rng: random.Random, stats: dict):
    lines = [codex_meta_line(raw_id, ts)]
    for t in range(turn_count):
        ts = ts + timedelta(seconds=rng.randrange(5, 120))
        lines.append(codex_turn_context_line(f"t-{t}", ts))
        lines.append(codex_user_line(sentence(rng, rng.randrange(4, 30)), ts))
        if rng.random() < HUGE_LINE_RATE:
            text = "x" * HUGE_PADDING_BYTES
            stats["codex_huge_lines"] += 1
        else:
            text = sentence(rng, rng.randrange(10, 120))
        lines.append(codex_assistant_line(text, ts + timedelta(seconds=1)))
        lines.append(codex_token_line(
            rng.randrange(100, 20_000), rng.randrange(0, 5_000),
            rng.randrange(50, 4_000), rng.randrange(0, 1_000),
            ts + timedelta(seconds=1), f"t-{t}"
        ))
    return lines


def generate_codex(out_dir: str, budget: Budget, days: int, rng: random.Random, stats: dict):
    codex_home = os.path.join(out_dir, "codex")
    sessions_root = os.path.join(codex_home, "sessions")
    now = datetime(2026, 6, 10, 12, 0, 0, tzinfo=timezone.utc)
    visible_ids = []

    # One oversized rollout (~25% of the codex budget) for streaming-reader
    # and per-file memory-bound coverage.
    oversized_target = budget.target // 4
    raw_id = str(uuid.uuid4())
    ts = now - timedelta(days=min(2, days - 1) if days > 1 else 0, hours=3)
    day_dir = os.path.join(sessions_root, ts.strftime("%Y"), ts.strftime("%m"), ts.strftime("%d"))
    path = os.path.join(day_dir, f"rollout-{ts.strftime('%Y-%m-%dT%H-%M-%S')}-{raw_id}.jsonl")
    os.makedirs(day_dir, exist_ok=True)
    with io.open(path, "w", encoding="utf-8", buffering=WRITE_BUFFER_BYTES) as f:
        f.write(codex_meta_line(raw_id, ts) + "\n")
        budget.add(80)
        written_here = 0
        t = 0
        while written_here < oversized_target:
            chunk_ts = ts + timedelta(seconds=10 * t)
            for line in (
                codex_turn_context_line(f"t-{t}", chunk_ts),
                codex_user_line(sentence(rng, 20), chunk_ts),
                codex_assistant_line(sentence(rng, 200), chunk_ts),
                codex_token_line(5000, 1000, 800, 100, chunk_ts, f"t-{t}"),
            ):
                f.write(line + "\n")
                budget.add(len(line) + 1)
                written_here += len(line) + 1
            t += 1
    visible_ids.append(raw_id)
    stats["codex_files"] += 1
    stats["codex_sessions"] += 1
    stats["codex_oversized_bytes"] = written_here

    while not budget.exhausted:
        raw_id = str(uuid.uuid4())
        day_offset = rng.randrange(days)
        ts = now - timedelta(days=day_offset, minutes=rng.randrange(600))
        day_dir = os.path.join(sessions_root, ts.strftime("%Y"), ts.strftime("%m"), ts.strftime("%d"))
        path = os.path.join(day_dir, f"rollout-{ts.strftime('%Y-%m-%dT%H-%M-%S')}-{raw_id}.jsonl")
        lines = codex_rollout_lines(raw_id, ts, rng.randrange(4, 40), rng, stats)
        write_lines(path, lines, budget)
        stats["codex_files"] += 1
        stats["codex_sessions"] += 1
        if rng.random() < VISIBLE_INDEX_RATE:
            visible_ids.append(raw_id)

    index_budget = Budget(1 << 60)
    index_lines = [
        f'{{"id":"{raw_id}","thread_name":"Generated session {i}","updated_at":"{codex_iso(now)}"}}'
        for i, raw_id in enumerate(visible_ids)
    ]
    write_lines(os.path.join(codex_home, "session_index.jsonl"), index_lines, index_budget)
    stats["codex_visible_sessions"] = len(visible_ids)


# MARK: Verify / main

def verify(out_dir: str) -> int:
    """Spot-check: first and last line of a sample of files must be JSON."""
    bad = 0
    checked = 0
    for root, _, files in os.walk(out_dir):
        for name in sorted(files)[:3]:
            if not name.endswith(".jsonl"):
                continue
            path = os.path.join(root, name)
            size = os.path.getsize(path)
            tail_window = 1 << 20
            with open(path, "rb") as f:
                first = f.readline().decode("utf-8", "replace").strip()
                f.seek(max(0, size - tail_window))
                tail = f.read().decode("utf-8", "replace").strip().splitlines()
                last = tail[-1] if tail else ""
            for line in (first, last):
                if not line:
                    continue
                checked += 1
                try:
                    json.loads(line)
                except json.JSONDecodeError:
                    # Corrupt lines are intentional at CORRUPT_LINE_RATE;
                    # only flag if the corruption marker is absent.
                    if "THIS IS NOT JSON" not in line:
                        bad += 1
                        print(f"[verify] unparseable line in {path}", file=sys.stderr)
    print(f"[verify] checked={checked} unexpected_bad={bad}")
    return bad


def main():
    parser = argparse.ArgumentParser(description="Generate synthetic Lupen corpora.")
    parser.add_argument("--output", required=True)
    parser.add_argument("--claude-mb", type=int, default=512)
    parser.add_argument("--codex-mb", type=int, default=512)
    parser.add_argument("--days", type=int, default=30)
    parser.add_argument("--seed", type=int, default=42)
    parser.add_argument("--verify", action="store_true")
    args = parser.parse_args()

    rng = random.Random(args.seed)
    out_dir = os.path.abspath(args.output)
    os.makedirs(out_dir, exist_ok=True)

    stats = {
        "claude_sessions": 0, "claude_files": 0, "claude_subagent_files": 0,
        "claude_huge_lines": 0, "claude_corrupt_lines": 0,
        "codex_sessions": 0, "codex_files": 0, "codex_huge_lines": 0,
        "codex_visible_sessions": 0, "codex_oversized_bytes": 0,
    }

    claude_budget = Budget(args.claude_mb * 1024 * 1024)
    codex_budget = Budget(args.codex_mb * 1024 * 1024)

    if args.claude_mb > 0:
        generate_claude(out_dir, claude_budget, max(1, args.days), rng, stats)
    if args.codex_mb > 0:
        generate_codex(out_dir, codex_budget, max(1, args.days), rng, stats)

    stats["claude_bytes"] = claude_budget.written
    stats["codex_bytes"] = codex_budget.written
    print(json.dumps(stats, indent=2, sort_keys=True))

    if args.verify and verify(out_dir) > 0:
        sys.exit(1)


if __name__ == "__main__":
    main()
