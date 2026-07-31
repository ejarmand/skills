#!/usr/bin/env python3
"""Collect likely steering/interruption turns from Codex session history."""

from __future__ import annotations

import argparse
import datetime as dt
import json
import os
import re
from pathlib import Path
from typing import Any


DEFAULT_PATTERNS = [
    r"\b(stop|pause|hold on|wait)\b",
    r"\b(actually|instead|rather than|changed my mind)\b",
    r"\b(nope|no,|not that|not what|that's not|this is not)\b",
    r"\b(wrong|incorrect|you missed|you forgot|you ignored)\b",
    r"\b(i meant|i asked|i said|the request was)\b",
    r"\b(don't|do not|please don't|should have|shouldn't have)\b",
    r"\b(latest|newest|previous|earlier|original) (message|request|instruction|task)\b",
    r"\b(interrupt|interrupted|steer|steering|redirect|resume)\b",
    r"\b(only|just) (do|need|wanted|asked)\b",
]

MODEL_KEYS = {"model", "model_slug", "model_name", "model_id"}


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Find likely user steering turns in Codex JSONL session histories."
    )
    parser.add_argument(
        "--codex-home",
        default=os.environ.get("CODEX_HOME") or str(Path.home() / ".codex"),
        help="Codex home directory. Defaults to ${CODEX_HOME:-$HOME/.codex}.",
    )
    parser.add_argument(
        "--model",
        default="auto",
        help="Target model name. Use 'auto' to infer the newest session model; if inference fails, no model filter is applied.",
    )
    parser.add_argument(
        "--include-unknown-model",
        action="store_true",
        help="Include sessions without model metadata even when --model names a specific model.",
    )
    parser.add_argument(
        "--include-subagents",
        action="store_true",
        help="Include subagent/internal sessions. By default only user-originated threads are scanned.",
    )
    parser.add_argument(
        "--since",
        default=None,
        help="Only include sessions on or after YYYY-MM-DD, or relative Nd such as 30d.",
    )
    parser.add_argument("--limit", type=int, default=80, help="Maximum cases to emit.")
    parser.add_argument(
        "--max-chars",
        type=int,
        default=1400,
        help="Maximum characters per excerpt.",
    )
    parser.add_argument(
        "--keywords",
        default="",
        help="Comma-separated extra regex patterns for steering detection.",
    )
    parser.add_argument(
        "--format",
        choices=("markdown", "json"),
        default="markdown",
        help="Output format.",
    )
    return parser.parse_args()


def cutoff_from_since(value: str | None) -> dt.datetime | None:
    if not value:
        return None
    now = dt.datetime.now(dt.timezone.utc)
    if value.endswith("d") and value[:-1].isdigit():
        return now - dt.timedelta(days=int(value[:-1]))
    parsed = dt.datetime.fromisoformat(value)
    if parsed.tzinfo is None:
        parsed = parsed.replace(tzinfo=dt.timezone.utc)
    return parsed


def parse_timestamp(value: Any) -> dt.datetime | None:
    if value is None:
        return None
    if isinstance(value, (int, float)):
        return dt.datetime.fromtimestamp(value, tz=dt.timezone.utc)
    if not isinstance(value, str):
        return None
    text = value.replace("Z", "+00:00")
    try:
        parsed = dt.datetime.fromisoformat(text)
    except ValueError:
        return None
    if parsed.tzinfo is None:
        parsed = parsed.replace(tzinfo=dt.timezone.utc)
    return parsed


def text_from_content(value: Any) -> str:
    if value is None:
        return ""
    if isinstance(value, str):
        return value
    if isinstance(value, list):
        parts = []
        for item in value:
            if isinstance(item, str):
                parts.append(item)
            elif isinstance(item, dict):
                parts.append(text_from_content(item.get("text") or item.get("content")))
        return "\n".join(part for part in parts if part)
    if isinstance(value, dict):
        if "text" in value or "content" in value:
            return text_from_content(value.get("text") or value.get("content"))
        if "message" in value:
            return text_from_content(value.get("message"))
    return ""


def collect_model_names(value: Any) -> set[str]:
    found: set[str] = set()
    if isinstance(value, dict):
        for key, child in value.items():
            if key in MODEL_KEYS and isinstance(child, str) and child:
                found.add(child)
            elif key != "base_instructions":
                found.update(collect_model_names(child))
    elif isinstance(value, list):
        for child in value:
            found.update(collect_model_names(child))
    return found


def normalize_model(value: str) -> str:
    return re.sub(r"[^a-z0-9]+", "", value.casefold())


def model_matches(target: str | None, models: set[str], include_unknown: bool) -> bool:
    if not target:
        return True
    if not models:
        return include_unknown
    wanted = normalize_model(target)
    for model in models:
        candidate = normalize_model(model)
        if wanted == candidate or wanted in candidate or candidate in wanted:
            return True
    return False


def event_from_record(record: dict[str, Any], line_no: int) -> dict[str, Any] | None:
    payload = record.get("payload") if isinstance(record.get("payload"), dict) else {}
    record_type = record.get("type")
    payload_type = payload.get("type")
    role = payload.get("role")
    text = ""

    if payload_type == "message" and role in {"user", "assistant"}:
        text = text_from_content(payload.get("content"))
    elif role in {"user", "assistant"}:
        text = text_from_content(payload)
    elif record_type in {"user_message", "agent_message"}:
        role = "user" if record_type == "user_message" else "assistant"
        text = text_from_content(payload)
    elif payload_type == "agent_message":
        role = "assistant"
        text = text_from_content(payload.get("message"))
    elif payload_type == "user_message":
        role = "user"
        text = text_from_content(payload.get("message") or payload.get("text"))

    if not role or not text.strip():
        return None
    return {
        "role": role,
        "text": text.strip(),
        "timestamp": record.get("timestamp") or payload.get("timestamp"),
        "line": line_no,
    }


def read_session(path: Path) -> tuple[dict[str, Any], list[dict[str, Any]]]:
    meta: dict[str, Any] = {"models": set(), "session_id": None, "thread_source": None, "timestamps": []}
    events: list[dict[str, Any]] = []
    with path.open("r", encoding="utf-8", errors="replace") as handle:
        for line_no, line in enumerate(handle, start=1):
            try:
                record = json.loads(line)
            except json.JSONDecodeError:
                continue
            payload = record.get("payload") if isinstance(record.get("payload"), dict) else {}
            if record.get("type") == "session_meta":
                meta["session_id"] = payload.get("session_id") or payload.get("id")
                meta["thread_source"] = payload.get("thread_source")
                meta["models"].update(collect_model_names(payload))
            elif record.get("type") == "turn_context":
                meta["models"].update(collect_model_names(payload))
            timestamp = parse_timestamp(record.get("timestamp") or payload.get("timestamp"))
            if timestamp:
                meta["timestamps"].append(timestamp)
            event = event_from_record(record, line_no)
            if event:
                events.append(event)
    return meta, events


def infer_newest_model(paths: list[Path], include_subagents: bool) -> str | None:
    for path in sorted(paths, reverse=True):
        meta, _events = read_session(path)
        if not include_subagents and meta.get("thread_source") not in {None, "user"}:
            continue
        if meta["models"]:
            return sorted(meta["models"])[0]
    return None


def compile_patterns(extra: str) -> list[re.Pattern[str]]:
    patterns = list(DEFAULT_PATTERNS)
    patterns.extend(part.strip() for part in extra.split(",") if part.strip())
    return [re.compile(pattern, re.IGNORECASE) for pattern in patterns]


def truncate(text: str, max_chars: int) -> str:
    clean = re.sub(r"\n{3,}", "\n\n", text.strip())
    if len(clean) <= max_chars:
        return clean
    return clean[: max_chars - 15].rstrip() + "\n[truncated]"


def find_cases(
    paths: list[Path],
    target_model: str | None,
    include_unknown: bool,
    include_subagents: bool,
    cutoff: dt.datetime | None,
    patterns: list[re.Pattern[str]],
    limit: int,
    max_chars: int,
) -> tuple[list[dict[str, Any]], dict[str, Any]]:
    cases: list[dict[str, Any]] = []
    stats = {
        "files_scanned": 0,
        "files_model_skipped": 0,
        "files_date_skipped": 0,
        "unknown_model_files": 0,
        "non_user_thread_files": 0,
    }

    for path in sorted(paths):
        meta, events = read_session(path)
        timestamps = meta["timestamps"]
        session_time = min(timestamps) if timestamps else None
        if cutoff and session_time and session_time < cutoff:
            stats["files_date_skipped"] += 1
            continue
        if not include_subagents and meta.get("thread_source") not in {None, "user"}:
            stats["non_user_thread_files"] += 1
            continue
        if not meta["models"]:
            stats["unknown_model_files"] += 1
        if not model_matches(target_model, meta["models"], include_unknown):
            stats["files_model_skipped"] += 1
            continue

        stats["files_scanned"] += 1
        user_turns_seen = 0
        previous_assistant = ""
        for index, event in enumerate(events):
            if event["role"] == "assistant":
                previous_assistant = event["text"]
                continue
            if event["role"] != "user":
                continue
            user_turns_seen += 1
            if user_turns_seen == 1:
                continue

            if not previous_assistant:
                continue

            matches = [pat.pattern for pat in patterns if pat.search(event["text"])]
            if not matches:
                continue

            next_assistant = ""
            for later in events[index + 1 :]:
                if later["role"] == "assistant":
                    next_assistant = later["text"]
                    break

            cases.append(
                {
                    "case_id": f"case-{len(cases) + 1:03d}",
                    "session_id": meta["session_id"],
                    "path": str(path),
                    "line": event["line"],
                    "timestamp": event["timestamp"],
                    "models": sorted(meta["models"]),
                    "matches": matches[:5],
                    "user_text": truncate(event["text"], max_chars),
                    "previous_assistant": truncate(previous_assistant, max_chars),
                    "next_assistant": truncate(next_assistant, max_chars),
                }
            )
            if len(cases) >= limit:
                return cases, stats
    return cases, stats


def session_paths(codex_home: Path) -> list[Path]:
    sessions_dir = codex_home / "sessions"
    if not sessions_dir.exists():
        return []
    return sorted(sessions_dir.glob("**/*.jsonl"))


def emit_markdown(cases: list[dict[str, Any]], stats: dict[str, Any], model: str | None) -> None:
    print("# Steering Candidate Collection")
    print()
    print(f"- Target model: {model or 'unfiltered'}")
    print(f"- Cases: {len(cases)}")
    print(f"- Session files scanned: {stats['files_scanned']}")
    print(f"- Session files skipped by model: {stats['files_model_skipped']}")
    print(f"- Session files skipped by date: {stats['files_date_skipped']}")
    print(f"- Session files without model metadata: {stats['unknown_model_files']}")
    print(f"- Non-user thread files skipped: {stats['non_user_thread_files']}")
    print()
    for case in cases:
        print(f"## {case['case_id']}")
        print()
        print(f"- Session: {case['session_id'] or 'unknown'}")
        print(f"- File: `{case['path']}`")
        print(f"- Line: {case['line']}")
        print(f"- Timestamp: {case['timestamp'] or 'unknown'}")
        print(f"- Models: {', '.join(case['models']) or 'unknown'}")
        print(f"- Matched patterns: `{'; '.join(case['matches'])}`")
        print()
        print("### User steering")
        print()
        print(case["user_text"])
        print()
        print("### Previous assistant context")
        print()
        print(case["previous_assistant"] or "[none captured]")
        print()
        print("### Next assistant context")
        print()
        print(case["next_assistant"] or "[none captured]")
        print()


def main() -> int:
    args = parse_args()
    codex_home = Path(args.codex_home).expanduser()
    paths = session_paths(codex_home)
    target_model = args.model
    if target_model == "auto":
        target_model = infer_newest_model(paths, args.include_subagents)
    cutoff = cutoff_from_since(args.since)
    patterns = compile_patterns(args.keywords)
    cases, stats = find_cases(
        paths=paths,
        target_model=target_model,
        include_unknown=args.include_unknown_model,
        include_subagents=args.include_subagents,
        cutoff=cutoff,
        patterns=patterns,
        limit=args.limit,
        max_chars=args.max_chars,
    )

    if args.format == "json":
        print(
            json.dumps(
                {"target_model": target_model, "stats": stats, "cases": cases},
                indent=2,
                ensure_ascii=False,
            )
        )
    else:
        emit_markdown(cases, stats, target_model)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
