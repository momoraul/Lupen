#!/usr/bin/env python3
"""
Redact real Claude Code JSONL transcripts into a STRUCTURAL skeleton suitable
for committing as a cost-verification fixture.

PRIVACY MODEL — strict WHITELIST, not blacklist:
  For every line we build a BRAND-NEW object containing ONLY the handful of
  fields the cost / lineage / owner-map pipeline reads. Everything else is
  dropped by construction, so a field we never thought about cannot leak.

  Dropped entirely: message text, tool inputs/outputs, tool_use_result,
  thinking, summaries, file paths, cwd, git branches, slugs, custom titles,
  user content — i.e. anything that could carry the user's actual work.

  Kept (all non-content identifiers / numbers):
    top level : type, subtype, isMeta, uuid, parentUuid, sessionId,
                isSidechain, requestId, logicalParentUuid, (shifted) timestamp
    message   : id, role, model, stop_reason, type, usage (token counts only)
    content   : replaced with a fixed placeholder [{"type":"text","text":"x"}]

  Timestamps are shifted by a single global offset so the earliest becomes
  2020-01-01 — relative ordering (the only thing the rank tiebreak uses) is
  preserved, the absolute "when did you work" signal is removed.

  Project directory names are replaced with neutral "project-N".

Usage:
  redact_corpus.py capture  <out_dir> <session.jsonl | session_dir> ...
  redact_corpus.py scan     <out_dir>      # fail if any forbidden pattern survives
"""
import json, os, sys, shutil, re
from datetime import datetime, timezone

# Only these line types are emitted at all. Everything else (summary,
# file-history-snapshot, x-* telemetry, …) is dropped — not needed for cost.
KEPT_TYPES = {"user", "assistant", "system"}
TOP_KEEP = ["type", "subtype", "isMeta", "uuid", "parentUuid", "sessionId",
            "isSidechain", "requestId", "logicalParentUuid"]
MSG_KEEP = ["id", "role", "model", "stop_reason", "type"]
# Id-like fields get consistently remapped to synthetic values, so NO real
# identifier survives — only the SHARING STRUCTURE (same real id → same
# synthetic id across every file) which the dedup/owner logic depends on.
ID_FIELDS_TOP = {"uuid", "parentUuid", "sessionId", "logicalParentUuid", "requestId"}
ID_FIELDS_MSG = {"id"}
PLACEHOLDER_CONTENT = [{"type": "text", "text": "x"}]
BASE_TS = datetime(2020, 1, 1, tzinfo=timezone.utc)


class Remapper:
    """Bijective real-id → synthetic-id map, consistent across all files."""
    def __init__(self):
        self._m = {}
        self._n = {}

    def map(self, real, kind):
        if real is None:
            return None
        if real not in self._m:
            self._n[kind] = self._n.get(kind, 0) + 1
            self._m[real] = f"{kind}{self._n[kind]:05d}"
        return self._m[real]


REMAP = Remapper()
# requestId keeps a recognizable prefix; others get a short kind prefix.
KIND = {"requestId": "req_x", "sessionId": "sess", "uuid": "uuid",
        "parentUuid": "uuid", "logicalParentUuid": "uuid", "id": "msg_x"}


def parse_ts(s):
    if not isinstance(s, str):
        return None
    try:
        return datetime.fromisoformat(s.replace("Z", "+00:00"))
    except Exception:
        return None


def clean_usage(usage):
    """Keep ONLY numeric token fields + service_tier (an enum). No free text."""
    if not isinstance(usage, dict):
        return None
    out = {}
    for k, v in usage.items():
        if isinstance(v, bool):
            continue
        if isinstance(v, (int, float)):
            out[k] = v
        elif isinstance(v, dict):  # e.g. cache_creation: {ephemeral_*_input_tokens}
            nested = {nk: nv for nk, nv in v.items() if isinstance(nv, (int, float))}
            if nested:
                out[k] = nested
        elif k == "service_tier" and isinstance(v, str):
            out[k] = v  # "standard"/"batch" enum — not content
    return out


def redact_line(obj, offset):
    t = obj.get("type")
    if t not in KEPT_TYPES:
        return None
    out = {}
    for k in TOP_KEEP:
        if k in obj and obj[k] is not None:
            v = obj[k]
            out[k] = REMAP.map(v, KIND[k]) if k in ID_FIELDS_TOP else v
    ts = parse_ts(obj.get("timestamp"))
    if ts is not None:
        out["timestamp"] = (ts + offset).strftime("%Y-%m-%dT%H:%M:%S.") + \
            f"{ts.microsecond // 1000:03d}Z"
    msg = obj.get("message")
    if isinstance(msg, dict):
        m = {}
        for k in MSG_KEEP:
            if k in msg and msg[k] is not None:
                m[k] = REMAP.map(msg[k], KIND["id"]) if k in ID_FIELDS_MSG else msg[k]
        usage = clean_usage(msg.get("usage"))
        if usage is not None:
            m["usage"] = usage
        # role-appropriate placeholder content; never the real content
        m["content"] = "hi" if msg.get("role") == "user" else PLACEHOLDER_CONTENT
        out["message"] = m
    return out


def global_offset(files):
    earliest = None
    for f in files:
        for line in open(f, encoding="utf-8", errors="ignore"):
            try:
                ts = parse_ts(json.loads(line).get("timestamp"))
            except Exception:
                continue
            if ts and (earliest is None or ts < earliest):
                earliest = ts
    return (BASE_TS - earliest) if earliest else (BASE_TS - BASE_TS)


def expand(paths):
    """A session arg may be a file or a session dir (with subagents/). Returns
    list of (jsonl_path, relative_layout) where layout keeps subagents/wf dirs."""
    out = []
    for p in paths:
        if os.path.isdir(p):
            base = os.path.basename(p.rstrip("/"))
            for root, _, fnames in os.walk(p):
                for fn in fnames:
                    if fn.endswith(".jsonl"):
                        full = os.path.join(root, fn)
                        rel = os.path.join(base, os.path.relpath(full, p))
                        out.append((full, rel))
            sib = p.rstrip("/") + ".jsonl"
            if os.path.exists(sib):
                out.append((sib, os.path.basename(sib)))
        else:
            out.append((p, os.path.basename(p)))
    return out


UUID_RE = re.compile(r"^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$", re.I)


def remap_path(rel):
    """Replace UUID path components (session ids in dir/file names) with their
    synthetic ids; leave agent-<hash>/wf_<hash> names (random, non-sensitive)."""
    parts = []
    for seg in rel.split(os.sep):
        stem, dot, ext = seg.partition(".")
        if UUID_RE.match(stem):
            seg = REMAP.map(stem, "sess") + dot + ext
        parts.append(seg)
    return os.sep.join(parts)


def cmd_capture(out_dir, args):
    pairs = expand(args)
    offset = global_offset([f for f, _ in pairs])
    proj = os.path.join(out_dir, "projects", "project-1")
    os.makedirs(proj, exist_ok=True)
    kept_files = kept_lines = dropped_lines = 0
    for src, rel in pairs:
        # Process lines first (fills the id remap), then rename the path.
        buf = []
        for line in open(src, encoding="utf-8", errors="ignore"):
            line = line.strip()
            if not line:
                continue
            try:
                obj = json.loads(line)
            except Exception:
                dropped_lines += 1
                continue
            red = redact_line(obj, offset)
            if red is None:
                dropped_lines += 1
                continue
            buf.append(json.dumps(red, separators=(",", ":")))
        dst = os.path.join(proj, remap_path(rel))
        os.makedirs(os.path.dirname(dst), exist_ok=True)
        with open(dst, "w", encoding="utf-8") as w:
            w.write("\n".join(buf) + ("\n" if buf else ""))
        kept_files += 1
        kept_lines += len(buf)
    print(f"captured {kept_files} files, {kept_lines} kept lines, {dropped_lines} dropped")
    print(f"remapped {len(REMAP._m)} distinct identifiers → synthetic ids")


# Patterns that must NEVER appear in redacted output. If any matches, the
# capture is rejected — a tripwire on top of the whitelist.
FORBIDDEN = [
    re.compile(r"/Users/"), re.compile(r"/home/"),
    re.compile(r"\.(swift|py|ts|js|tsx|kt|java|md|json|sh)\b"),
    re.compile(r"\bcwd\b"), re.compile(r"gitBranch"), re.compile(r"\bslug\b"),
    re.compile(r"toolUseResult"), re.compile(r"thinking"),
    re.compile(r"\bcustomTitle\b"), re.compile(r"\bsummary\b"),
    # real identifiers that must have been remapped to synthetic ids
    re.compile(r"[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}", re.I),
    re.compile(r"req_(?!x)"), re.compile(r"msg_(?!x)"),
]

# Project/employer-specific words are deliberately NOT hardcoded here — a
# public tool must not ship someone's private project names. Pass your own
# (comma-separated) via the REDACT_EXTRA_FORBIDDEN env var to keep a local
# tripwire on names the whitelist can't know about, e.g.
#   REDACT_EXTRA_FORBIDDEN="acme,project-x" redact_corpus.py scan out/
# The whitelist (drop everything except the few kept fields) is the primary
# guarantee; these extras are a belt-and-suspenders check on top.
for _word in os.environ.get("REDACT_EXTRA_FORBIDDEN", "").split(","):
    _word = _word.strip()
    if _word:
        FORBIDDEN.append(re.compile(re.escape(_word), re.I))
# message text we know we inject — allowed.
ALLOWED_TEXT = {"x", "hi"}


def cmd_scan(out_dir):
    bad = 0
    for root, _, fnames in os.walk(out_dir):
        for fn in fnames:
            if not fn.endswith(".jsonl"):
                continue
            path = os.path.join(root, fn)
            for i, line in enumerate(open(path, encoding="utf-8"), 1):
                for pat in FORBIDDEN:
                    if pat.search(line):
                        print(f"  ★ FORBIDDEN {pat.pattern} at {fn}:{i}")
                        bad += 1
                # any text content other than our placeholders?
                try:
                    obj = json.loads(line)
                    c = (obj.get("message") or {}).get("content")
                    if isinstance(c, str) and c not in ALLOWED_TEXT:
                        print(f"  ★ unexpected user text at {fn}:{i}: {c[:40]!r}")
                        bad += 1
                    if isinstance(c, list):
                        for part in c:
                            txt = part.get("text") if isinstance(part, dict) else None
                            if txt is not None and txt not in ALLOWED_TEXT:
                                print(f"  ★ unexpected assistant text at {fn}:{i}")
                                bad += 1
                except Exception:
                    pass
    print(f"scan: {'CLEAN ✓' if bad == 0 else f'{bad} LEAKS ✗'}")
    return 1 if bad else 0


if __name__ == "__main__":
    if len(sys.argv) < 3:
        print(__doc__)
        sys.exit(2)
    cmd = sys.argv[1]
    if cmd == "capture":
        cmd_capture(sys.argv[2], sys.argv[3:])
    elif cmd == "scan":
        sys.exit(cmd_scan(sys.argv[2]))
    else:
        print(__doc__)
        sys.exit(2)
