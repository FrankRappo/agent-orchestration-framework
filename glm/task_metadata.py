#!/usr/bin/env python3
"""Resolve validated GLM task headers and model policy as TSV or JSON."""

from __future__ import annotations

import argparse
import json
from pathlib import Path
import re


HEADER_RE = re.compile(r"^[ \t]*(?P<key>[A-Za-z][A-Za-z-]*):[ \t]*(?P<value>[^#\r\n]+?)?[ \t]*$")


def headers(path: Path) -> dict[str, str]:
    values: dict[str, str] = {}
    in_comment = False
    for raw in path.read_text(encoding="utf-8").splitlines():
        line = raw.strip()
        if line.startswith("<!--"):
            in_comment = True
        if not in_comment:
            match = HEADER_RE.match(raw)
            if match and match.group("value"):
                values.setdefault(match.group("key").lower(), match.group("value").strip())
        if "-->" in line:
            in_comment = False
    return values


def boolean(value: str | None) -> bool:
    return (value or "").strip().lower() in {"1", "true", "yes", "on"}


def integer(value: str | None, default: int, minimum: int = 0) -> int:
    try:
        parsed = int((value or "").strip())
    except ValueError:
        return default
    return parsed if parsed >= minimum else default


def sanitize_lock(value: str | None) -> str:
    result = re.sub(r"[^A-Za-z0-9_.-]", "-", (value or "none").strip())
    return result[:80] or "none"


def resolve(task: Path, policy_path: Path) -> dict[str, object]:
    policy = json.loads(policy_path.read_text(encoding="utf-8"))
    values = headers(task)
    complexity = values.get("complexity", str(policy.get("default_complexity", "medium"))).lower()
    mapping = policy["complexity_models"]
    if complexity not in mapping:
        complexity = str(policy.get("default_complexity", "medium"))
    requested = values.get("model", "auto")
    model = mapping[complexity] if requested.lower() in {"", "auto", "inherit"} else requested
    allowed = {str(item).lower(): str(item) for item in policy.get("allowed_models", [])}
    if model.lower() not in allowed:
        raise SystemExit(f"unsupported model in {task}: {model}")
    model = allowed[model.lower()]
    mode = values.get("mode", "yolo").lower()
    if mode not in {"build", "edit", "plan", "yolo"}:
        raise SystemExit(f"unsupported mode in {task}: {mode}")
    provider = values.get("provider", str(policy["provider_id"]))
    if not re.fullmatch(r"[A-Za-z0-9:._/-]+", provider):
        raise SystemExit(f"unsafe provider id in {task}: {provider}")
    return {
        "complexity": complexity,
        "provider_id": provider,
        "model_id": model,
        "mode": mode,
        "resource_lock": sanitize_lock(values.get("resource-lock")),
        "no_respawn": boolean(values.get("no-respawn")),
        "max_respawn": integer(values.get("max-respawn"), 3),
        "max_runtime_seconds": integer(values.get("max-runtime-seconds"), 7200, 60),
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("task", type=Path)
    parser.add_argument("--policy", type=Path, default=Path(__file__).with_name("model_policy.json"))
    parser.add_argument("--json", action="store_true")
    args = parser.parse_args()
    data = resolve(args.task, args.policy)
    if args.json:
        print(json.dumps(data, ensure_ascii=False, indent=2))
    else:
        fields = (
            "complexity",
            "provider_id",
            "model_id",
            "mode",
            "resource_lock",
            "no_respawn",
            "max_respawn",
            "max_runtime_seconds",
        )
        print("\t".join(str(data[name]).lower() if isinstance(data[name], bool) else str(data[name]) for name in fields))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
