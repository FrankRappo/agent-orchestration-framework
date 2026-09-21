#!/usr/bin/env python3
"""Summarize the append-only GLM task usage ledger."""

from __future__ import annotations

import argparse
from collections import defaultdict
import json
from pathlib import Path
import re


FIELDS = (
    "model_request_count",
    "input_tokens",
    "output_tokens",
    "total_tokens",
    "cache_read_tokens",
    "cache_write_tokens",
    "reasoning_tokens",
    "web_fetch_requests",
    "web_search_requests",
)


def read_entries(path: Path) -> list[dict]:
    if not path.is_file():
        return []
    entries = []
    for line in path.read_text(encoding="utf-8", errors="replace").splitlines():
        try:
            value = json.loads(line)
        except json.JSONDecodeError:
            continue
        if isinstance(value, dict):
            entries.append(value)
    return entries


def read_log_entries(log_dir: Path) -> list[dict]:
    entries: list[dict] = []
    decoder = json.JSONDecoder()
    launch_re = re.compile(r"launch task=(\S+).* model=(\S+)")
    for path in sorted(log_dir.glob("T*.log")):
        text = path.read_text(encoding="utf-8", errors="replace")
        launch = launch_re.search(text)
        task = launch.group(1) if launch else path.stem
        model = launch.group(2) if launch else "unknown"
        index = 0
        while index < len(text):
            start = text.find("{", index)
            if start < 0:
                break
            try:
                value, length = decoder.raw_decode(text[start:])
                index = start + length
            except json.JSONDecodeError:
                index = start + 1
                continue
            usage = value.get("usage") if isinstance(value, dict) else None
            if not isinstance(usage, dict):
                continue
            def number(name: str) -> int:
                raw = usage.get(name, 0)
                return int(raw) if isinstance(raw, (int, float)) else 0
            entries.append({
                "timestamp": int(path.stat().st_mtime),
                "task": task,
                "model": model,
                "provider": "unknown",
                "session_id": value.get("sessionId"),
                "model_request_count": number("modelRequestCount"),
                "input_tokens": number("inputTokens"),
                "output_tokens": number("outputTokens"),
                "total_tokens": number("totalTokens"),
                "cache_read_tokens": number("cacheReadTokens"),
                "cache_write_tokens": number("cacheWriteTokens"),
                "reasoning_tokens": number("reasoningTokens"),
                "web_fetch_requests": number("webFetchRequests"),
                "web_search_requests": number("webSearchRequests"),
                "source": str(path),
            })
    return entries


def aggregate(entries: list[dict]) -> dict:
    totals = {field: 0 for field in FIELDS}
    by_model: dict[str, dict[str, int]] = defaultdict(lambda: {field: 0 for field in FIELDS})
    for entry in entries:
        model = str(entry.get("model") or "unknown")
        for field in FIELDS:
            value = int(entry.get(field) or 0)
            totals[field] += value
            by_model[model][field] += value
    return {
        "schema_version": 1,
        "entry_count": len(entries),
        "totals": totals,
        "by_model": dict(sorted(by_model.items())),
        "latest": entries[-1] if entries else None,
    }


def human(summary: dict) -> str:
    totals = summary["totals"]
    lines = [
        f"GLM task usage entries={summary['entry_count']}",
        "  requests={model_request_count} input={input_tokens} output={output_tokens} "
        "cache_read={cache_read_tokens} reasoning={reasoning_tokens} total={total_tokens}".format(**totals),
    ]
    for model, values in summary["by_model"].items():
        lines.append(
            f"  {model}: requests={values['model_request_count']} input={values['input_tokens']} "
            f"output={values['output_tokens']} cache_read={values['cache_read_tokens']} "
            f"total={values['total_tokens']}"
        )
    return "\n".join(lines)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("ledger", type=Path)
    parser.add_argument("--logs-dir", type=Path)
    parser.add_argument("--json", action="store_true")
    args = parser.parse_args()
    entries = read_entries(args.ledger)
    source = "ledger"
    if not entries and args.logs_dir:
        entries = read_log_entries(args.logs_dir)
        source = "logs-fallback"
    summary = aggregate(entries)
    summary["source"] = source
    print(json.dumps(summary, ensure_ascii=False, indent=2) if args.json else human(summary))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
