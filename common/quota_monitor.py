#!/usr/bin/env python3
"""Read local ZCode and Codex usage snapshots without exposing credentials.

The monitor deliberately consumes application/session logs instead of credential
files.  It is safe to run from cron/tmux and produces one normalized snapshot for
admission control, status pages, and alerts.
"""

from __future__ import annotations

import argparse
import datetime as dt
import glob
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import time
from typing import Any, Iterable


TAIL_BYTES = 8 * 1024 * 1024


def read_tail(path: Path, limit: int = TAIL_BYTES) -> str:
    with path.open("rb") as handle:
        handle.seek(0, os.SEEK_END)
        size = handle.tell()
        handle.seek(max(0, size - limit))
        data = handle.read()
    if size > limit:
        _, _, data = data.partition(b"\n")
    return data.decode("utf-8", errors="replace")


def parse_iso(value: Any) -> int | None:
    if not isinstance(value, str) or not value:
        return None
    try:
        return int(dt.datetime.fromisoformat(value.replace("Z", "+00:00")).timestamp())
    except ValueError:
        return None


def severity(used_percent: float) -> str:
    if used_percent >= 95:
        return "critical"
    if used_percent >= 85:
        return "high"
    if used_percent >= 70:
        return "warning"
    return "ok"


def window_name(minutes: int | None = None, period: str | None = None) -> str:
    if period:
        normalized = period.strip().lower()
        aliases = {"day": "daily", "week": "weekly", "month": "monthly"}
        return aliases.get(normalized, normalized)
    if minutes == 300:
        return "five_hour"
    if minutes == 10080:
        return "weekly"
    if minutes is not None and 40320 <= minutes <= 44640:
        return "monthly"
    return f"{minutes}m" if minutes is not None else "unknown"


def percent(used: float, limit: float) -> float:
    return round((used / limit * 100.0), 2) if limit > 0 else 0.0


def newest_files(patterns: Iterable[str], limit: int = 40) -> list[Path]:
    candidates: dict[str, Path] = {}
    for pattern in patterns:
        for raw in glob.glob(os.path.expanduser(pattern), recursive=True):
            path = Path(raw)
            if path.is_file():
                candidates[str(path)] = path
    return sorted(candidates.values(), key=lambda p: p.stat().st_mtime, reverse=True)[:limit]


def extract_json_after(line: str, marker: str) -> dict[str, Any] | None:
    index = line.find(marker)
    if index < 0:
        return None
    start = line.find("{", index + len(marker))
    if start < 0:
        return None
    try:
        value = json.loads(line[start:])
    except json.JSONDecodeError:
        return None
    return value if isinstance(value, dict) else None


def default_zcode_patterns() -> list[str]:
    explicit = os.environ.get("ZCODE_DESKTOP_LOG_GLOB")
    if explicit:
        return [explicit]
    return [
        "/mnt/c/Users/*/.zcode/v2/logs/*.log",
        os.path.expanduser("~/.zcode/v2/logs/*.log"),
    ]


def discover_zcode_home(explicit: str | None) -> Path | None:
    if explicit:
        home = Path(explicit).expanduser()
        return home if (home / ".zcode" / "v2" / "credentials.json").is_file() else None
    current = Path.home()
    if (current / ".zcode" / "v2" / "credentials.json").is_file():
        return current
    candidates = sorted(
        Path("/home").glob("*/.zcode/v2/credentials.json"),
        key=lambda path: path.stat().st_mtime,
        reverse=True,
    )
    return candidates[0].parents[2] if candidates else None


def parse_zcode_live(helper: Path, home: Path | None) -> tuple[list[dict[str, Any]], list[dict[str, Any]], str | None]:
    node = shutil.which("node")
    if not node or home is None or not helper.is_file():
        return [], [], "live_zcode_unavailable"
    command = [
        node,
        str(helper),
        "--home",
        str(home),
        "--username",
        home.name,
        "--platform",
        "linux",
    ]
    try:
        result = subprocess.run(command, capture_output=True, text=True, timeout=25, check=False)
    except (OSError, subprocess.TimeoutExpired) as error:
        return [], [], f"live_zcode_failed:{type(error).__name__}"
    if result.returncode != 0:
        message = result.stderr.strip().splitlines()[-1] if result.stderr.strip() else f"rc={result.returncode}"
        return [], [], f"live_zcode_failed:{message[:240]}"
    try:
        payload = json.loads(result.stdout)
    except json.JSONDecodeError:
        return [], [], "live_zcode_invalid_json"
    buckets = payload.get("buckets", []) if isinstance(payload, dict) else []
    plans = payload.get("plans", []) if isinstance(payload, dict) else []
    return (
        [item for item in buckets if isinstance(item, dict)],
        [item for item in plans if isinstance(item, dict)],
        None,
    )


def parse_zcode(paths: list[Path]) -> tuple[list[dict[str, Any]], list[dict[str, Any]]]:
    latest_balance: tuple[int, dict[str, Any], str] | None = None
    latest_mcp: tuple[int, dict[str, Any], str] | None = None

    for path in paths:
        for line in read_tail(path).splitlines():
            if "[usage-stats] billing/balance" in line:
                payload = extract_json_after(line, "请求完成") or extract_json_after(line, "billing/balance")
                if payload:
                    data = payload.get("payload", {}).get("data", {})
                    observed = int(data.get("server_time") or parse_iso(line[1:24]) or path.stat().st_mtime)
                    if latest_balance is None or observed >= latest_balance[0]:
                        latest_balance = (observed, payload, str(path))
            elif "[usage-stats] 官方 MCP 额度响应" in line:
                payload = extract_json_after(line, "响应") or extract_json_after(line, "[usage-stats]")
                if payload:
                    try:
                        body = json.loads(payload.get("body", "{}"))
                    except (TypeError, json.JSONDecodeError):
                        continue
                    data = body.get("data", {}) if isinstance(body, dict) else {}
                    observed = int(data.get("server_time") or parse_iso(line[1:24]) or path.stat().st_mtime)
                    if latest_mcp is None or observed >= latest_mcp[0]:
                        latest_mcp = (observed, body, str(path))

    buckets: list[dict[str, Any]] = []
    plans: list[dict[str, Any]] = []
    if latest_balance:
        observed, payload, source = latest_balance
        data = payload.get("payload", {}).get("data", {})
        entitlement_period: dict[str, str] = {}
        for plan in data.get("plans", []):
            if not isinstance(plan, dict):
                continue
            plans.append(
                {
                    "provider": "zcode",
                    "plan_id": plan.get("plan_id"),
                    "name": plan.get("name"),
                    "status": plan.get("status"),
                    "starts_at": plan.get("starts_at"),
                    "ends_at": plan.get("ends_at"),
                    "observed_at": observed,
                    "source": source,
                }
            )
            for entitlement in plan.get("entitlements", []):
                if isinstance(entitlement, dict) and entitlement.get("entitlement_id"):
                    entitlement_period[str(entitlement["entitlement_id"])] = str(
                        entitlement.get("period") or "unknown"
                    )
        for item in data.get("balances", []):
            if not isinstance(item, dict):
                continue
            total = float(item.get("total_units") or 0)
            used = float(item.get("used_units") or 0)
            remaining = float(item.get("remaining_units") or max(0, total - used))
            used_pct = percent(used, total)
            buckets.append(
                {
                    "provider": "zcode",
                    "kind": "model",
                    "name": item.get("show_name") or item.get("entitlement_id"),
                    "model": item.get("show_name"),
                    "meter": item.get("meter"),
                    "unit": item.get("unit_type"),
                    "window": window_name(period=entitlement_period.get(str(item.get("entitlement_id")))),
                    "used": used,
                    "limit": total,
                    "remaining": remaining,
                    "used_percent": used_pct,
                    "status": severity(used_pct),
                    "period_start": item.get("period_start"),
                    "resets_at": item.get("period_end") or item.get("expires_at"),
                    "observed_at": observed,
                    "source": source,
                }
            )

    if latest_mcp:
        observed, body, source = latest_mcp
        data = body.get("data", {}) if isinstance(body, dict) else {}
        total_usage = data.get("total_usage", {}) if isinstance(data, dict) else {}
        if isinstance(total_usage, dict) and total_usage.get("limit") is not None:
            total = float(total_usage.get("limit") or 0)
            used = float(total_usage.get("used") or 0)
            remaining = float(total_usage.get("remaining") or max(0, total - used))
            used_pct = percent(used, total)
            buckets.append(
                {
                    "provider": "zcode",
                    "kind": "mcp",
                    "name": "official-mcp",
                    "model": None,
                    "meter": "mcp_usage",
                    "unit": "request",
                    "window": "daily",
                    "used": used,
                    "limit": total,
                    "remaining": remaining,
                    "used_percent": used_pct,
                    "status": severity(used_pct),
                    "resets_at": data.get("next_refresh_at"),
                    "observed_at": observed,
                    "source": source,
                    "plan_level": data.get("level"),
                }
            )
        if data.get("level"):
            plans.append(
                {
                    "provider": "zcode",
                    "plan_id": "coding-plan",
                    "name": f"Coding Plan {str(data['level']).upper()}",
                    "status": "active",
                    "level": data.get("level"),
                    "observed_at": observed,
                    "source": source,
                }
            )
    return buckets, plans


def default_codex_patterns(codex_home: str) -> list[str]:
    return [str(Path(codex_home).expanduser() / "sessions" / "**" / "*.jsonl")]


def parse_codex(paths: list[Path]) -> list[dict[str, Any]]:
    latest: tuple[int, dict[str, Any], str] | None = None
    for path in paths:
        for line in read_tail(path, 2 * 1024 * 1024).splitlines():
            try:
                event = json.loads(line)
            except json.JSONDecodeError:
                continue
            payload = event.get("payload", {}) if isinstance(event, dict) else {}
            limits = payload.get("rate_limits") if isinstance(payload, dict) else None
            if not isinstance(limits, dict):
                continue
            observed = parse_iso(event.get("timestamp")) or int(path.stat().st_mtime)
            if latest is None or observed >= latest[0]:
                latest = (observed, limits, str(path))
    if latest is None:
        return []

    observed, limits, source = latest
    buckets: list[dict[str, Any]] = []
    for label in ("primary", "secondary"):
        item = limits.get(label)
        if not isinstance(item, dict):
            continue
        used_pct = float(item.get("used_percent") or 0)
        buckets.append(
            {
                "provider": "codex",
                "kind": "rate_limit",
                "name": label,
                "model": None,
                "window": window_name(minutes=int(item.get("window_minutes") or 0)),
                "window_minutes": item.get("window_minutes"),
                "used": used_pct,
                "limit": 100.0,
                "remaining": max(0.0, 100.0 - used_pct),
                "unit": "percent",
                "used_percent": used_pct,
                "status": severity(used_pct),
                "resets_at": item.get("resets_at"),
                "observed_at": observed,
                "source": source,
                "plan_type": limits.get("plan_type"),
            }
        )
    return buckets


def normalize_model(value: str | None) -> str:
    return (value or "").strip().lower().replace("_", "-")


def admission(
    buckets: list[dict[str, Any]],
    provider: str,
    model: str | None,
    reserve_percent: float,
    max_age: int,
) -> dict[str, Any]:
    now = int(time.time())
    selected = [b for b in buckets if b.get("provider") == provider]
    if provider == "zcode" and model:
        coding_plan = [b for b in selected if b.get("kind") == "coding_plan"]
        if coding_plan:
            selected = coding_plan
        else:
            wanted = normalize_model(model)
            selected = [b for b in selected if normalize_model(b.get("model")) == wanted]
    elif provider == "codex":
        selected = [b for b in selected if b.get("kind") == "rate_limit"]

    if not selected:
        return {"decision": "unknown", "reason": "no_matching_quota_bucket", "provider": provider, "model": model}
    stale = [b for b in selected if now - int(b.get("observed_at") or 0) > max_age]
    if stale:
        return {
            "decision": "unknown",
            "reason": "quota_snapshot_stale",
            "provider": provider,
            "model": model,
            "oldest_age_seconds": max(now - int(b.get("observed_at") or 0) for b in stale),
        }
    cutoff = 100.0 - reserve_percent
    over_cutoff = [b for b in selected if float(b.get("used_percent") or 0) >= cutoff]
    # ZCode may expose multiple entitlement buckets for the same model. One
    # usable bucket is enough; Codex windows are cumulative gates, so every
    # reported window must remain below the reserve cutoff.
    is_coding_plan = provider == "zcode" and all(b.get("kind") == "coding_plan" for b in selected)
    denied = selected if provider == "zcode" and not is_coding_plan and len(over_cutoff) == len(selected) else over_cutoff
    if provider == "zcode" and not is_coding_plan and len(over_cutoff) < len(selected):
        denied = []
    return {
        "decision": "deny" if denied else "allow",
        "reason": "reserve_reached" if denied else "within_budget",
        "provider": provider,
        "model": model,
        "reserve_percent": reserve_percent,
        "buckets": selected,
    }


def human(snapshot: dict[str, Any]) -> str:
    lines = [f"quota snapshot generated_at={snapshot['generated_at']}"]
    for plan in snapshot.get("plans", []):
        if plan.get("level"):
            lines.append(f"  {plan.get('provider', '?'):<6} active plan level={str(plan['level']).upper()}")
    if not snapshot["buckets"]:
        lines.append("  no usage buckets found")
    for bucket in snapshot["buckets"]:
        reset = bucket.get("resets_at")
        reset_text = dt.datetime.fromtimestamp(reset, tz=dt.timezone.utc).isoformat() if isinstance(reset, (int, float)) else "unknown"
        lines.append(
            "  {provider:<6} {name:<20} {window:<10} used={used_percent:>6.2f}% "
            "remaining={remaining:g}/{limit:g} reset={reset} status={status}".format(
                provider=bucket.get("provider", "?"),
                name=str(bucket.get("name") or "?")[:20],
                window=bucket.get("window", "?"),
                used_percent=float(bucket.get("used_percent") or 0),
                remaining=float(bucket.get("remaining") or 0),
                limit=float(bucket.get("limit") or 0),
                reset=reset_text,
                status=bucket.get("status", "unknown"),
            )
        )
    return "\n".join(lines)


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--provider", choices=("all", "zcode", "codex"), default="all")
    parser.add_argument("--zcode-log", action="append", default=[])
    parser.add_argument("--zcode-home", default=os.environ.get("ZCODE_LIVE_HOME"))
    parser.add_argument("--zcode-helper", default=str(Path(__file__).with_name("zcode_coding_plan_quota.mjs")))
    parser.add_argument("--no-live-zcode", action="store_true")
    parser.add_argument("--codex-home", default=os.environ.get("CODEX_HOME", "~/.codex"))
    parser.add_argument("--json", action="store_true", dest="as_json")
    parser.add_argument("--admit-provider", choices=("zcode", "codex"))
    parser.add_argument("--admit-model")
    parser.add_argument("--reserve-percent", type=float, default=15.0)
    parser.add_argument("--max-age", type=int, default=21600)
    parser.add_argument("--fail-closed", action="store_true")
    return parser


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    buckets: list[dict[str, Any]] = []
    plans: list[dict[str, Any]] = []
    errors: list[str] = []
    if args.provider in ("all", "zcode"):
        zcode_paths = newest_files(args.zcode_log or default_zcode_patterns())
        zcode_buckets, plans = parse_zcode(zcode_paths)
        buckets.extend(zcode_buckets)
        if not args.no_live_zcode:
            live_buckets, live_plans, live_error = parse_zcode_live(
                Path(args.zcode_helper), discover_zcode_home(args.zcode_home)
            )
            if live_buckets:
                buckets = [
                    item for item in buckets
                    if not (item.get("provider") == "zcode" and item.get("kind") == "mcp")
                ]
                buckets.extend(live_buckets)
            if live_plans:
                plans = [item for item in plans if not item.get("level")]
                plans.extend(live_plans)
            if live_error:
                errors.append(live_error)
    if args.provider in ("all", "codex"):
        codex_paths = newest_files(default_codex_patterns(args.codex_home))
        buckets.extend(parse_codex(codex_paths))

    snapshot: dict[str, Any] = {
        "schema_version": 1,
        "generated_at": int(time.time()),
        "buckets": sorted(buckets, key=lambda b: (str(b.get("provider")), str(b.get("name")))),
        "plans": plans,
        "errors": errors,
    }
    exit_code = 0
    if args.admit_provider:
        decision = admission(buckets, args.admit_provider, args.admit_model, args.reserve_percent, args.max_age)
        snapshot["admission"] = decision
        if decision["decision"] == "deny":
            exit_code = 3
        elif decision["decision"] == "unknown" and args.fail_closed:
            exit_code = 4

    print(json.dumps(snapshot, ensure_ascii=False, indent=2) if args.as_json else human(snapshot))
    return exit_code


if __name__ == "__main__":
    raise SystemExit(main())
