#!/usr/bin/env python3
"""Install/check the Codex Conductor flattened-transport compatibility overlay."""

from __future__ import annotations

import argparse
import datetime as dt
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys


ALIASES = {
    "collaborationspawn_agent": "collaboration.spawn_agent",
    "collaborationclose_agent": "collaboration.close_agent",
    "collaborationsend_message": "collaboration.send_message",
    "collaborationfollowup_task": "collaboration.followup_task",
    "collaborationwait_agent": "collaboration.wait_agent",
    "collaborationinterrupt_agent": "collaboration.interrupt_agent",
    "collaborationlist_agents": "collaboration.list_agents",
}

MARKER = "OMX_CONDUCTOR_FLATTENED_TRANSPORT_COMPAT_V1"

TS_HELPER = f'''// {MARKER}
const NATIVE_FLATTENED_COLLABORATION_TOOL_ALIASES = new Map<string, string>({json.dumps(list(ALIASES.items()))} as Array<[string, string]>);

export function normalizeNativeToolTransportName(toolName: string): string {{
  const trimmed = toolName.trim();
  return NATIVE_FLATTENED_COLLABORATION_TOOL_ALIASES.get(trimmed) ?? trimmed;
}}

function normalizeNativeToolTransportPayload(payload: CodexHookPayload): CodexHookPayload {{
  const rawToolName = typeof payload.tool_name === "string"
    ? payload.tool_name
    : typeof payload.toolName === "string"
      ? payload.toolName
      : "";
  const normalizedToolName = normalizeNativeToolTransportName(rawToolName);
  if (!normalizedToolName || normalizedToolName === payload.tool_name) return payload;
  return {{ ...payload, tool_name: normalizedToolName }};
}}
'''

JS_HELPER = f'''// {MARKER}
const NATIVE_FLATTENED_COLLABORATION_TOOL_ALIASES = new Map({json.dumps(list(ALIASES.items()))});
export function normalizeNativeToolTransportName(toolName) {{
    const trimmed = toolName.trim();
    return NATIVE_FLATTENED_COLLABORATION_TOOL_ALIASES.get(trimmed) ?? trimmed;
}}
function normalizeNativeToolTransportPayload(payload) {{
    const rawToolName = typeof payload.tool_name === "string"
        ? payload.tool_name
        : typeof payload.toolName === "string"
            ? payload.toolName
            : "";
    const normalizedToolName = normalizeNativeToolTransportName(rawToolName);
    if (!normalizedToolName || normalizedToolName === payload.tool_name)
        return payload;
    return {{ ...payload, tool_name: normalizedToolName }};
}}
'''


def default_package_root() -> Path:
    npm_root = subprocess.check_output(["npm", "root", "-g"], text=True).strip()
    return Path(npm_root) / "oh-my-codex"


def patched_text(path: Path, text: str) -> str:
    if MARKER in text:
        return text
    if path.suffix == ".ts":
        type_anchor = "type CodexHookPayload = Record<string, unknown>;\n"
        dispatch_anchor = "export async function dispatchCodexNativeHook(\n  payload: CodexHookPayload,\n  options: NativeHookDispatchOptions = {},\n): Promise<NativeHookDispatchResult> {\n"
        helper = TS_HELPER
    else:
        type_anchor = 'const TERMINAL_MODE_PHASES = new Set(["complete", "completed", "failed", "cancelled"]);\n'
        dispatch_anchor = "export async function dispatchCodexNativeHook(payload, options = {}) {\n"
        helper = JS_HELPER
    if text.count(type_anchor) != 1:
        raise RuntimeError(f"expected one helper anchor in {path}, found {text.count(type_anchor)}")
    if text.count(dispatch_anchor) != 1:
        raise RuntimeError(f"expected one dispatch anchor in {path}, found {text.count(dispatch_anchor)}")
    text = text.replace(type_anchor, type_anchor + "\n" + helper + "\n", 1)
    text = text.replace(dispatch_anchor, dispatch_anchor + "  payload = normalizeNativeToolTransportPayload(payload);\n", 1)
    return text


def target_paths(package_root: Path) -> list[Path]:
    return [
        package_root / "src/scripts/codex-native-hook.ts",
        package_root / "dist/scripts/codex-native-hook.js",
    ]


def check(package_root: Path) -> None:
    for path in target_paths(package_root):
        text = path.read_text(encoding="utf-8")
        if MARKER not in text:
            raise RuntimeError(f"overlay marker missing: {path}")
        if "payload = normalizeNativeToolTransportPayload(payload);" not in text:
            raise RuntimeError(f"dispatch normalization missing: {path}")
    print(f"overlay OK: {package_root}")


def install(package_root: Path, backup_root: Path | None) -> None:
    targets = target_paths(package_root)
    for path in targets:
        if not path.is_file():
            raise RuntimeError(f"OMX hook file not found: {path}")
    changes = [(path, patched_text(path, path.read_text(encoding="utf-8"))) for path in targets]
    changes = [(path, text) for path, text in changes if text != path.read_text(encoding="utf-8")]
    if not changes:
        check(package_root)
        print("overlay already installed; no files changed")
        return

    timestamp = dt.datetime.now(dt.timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    backup_dir = backup_root or package_root / ".omx-backups" / f"conductor-recovery-{timestamp}"
    backup_dir.mkdir(parents=True, exist_ok=False)
    for path, _ in changes:
        relative = path.relative_to(package_root)
        destination = backup_dir / relative
        destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(path, destination)

    for path, text in changes:
        temporary = path.with_name(f".{path.name}.omx-overlay-{os.getpid()}")
        temporary.write_text(text, encoding="utf-8")
        os.replace(temporary, path)

    check(package_root)
    print(f"backup: {backup_dir}")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("action", choices=("install", "check", "normalize"))
    parser.add_argument("tool_name", nargs="?")
    parser.add_argument("--package-root", type=Path)
    parser.add_argument("--backup-root", type=Path)
    args = parser.parse_args()
    if args.action == "normalize":
        if args.tool_name is None:
            parser.error("normalize requires tool_name")
        print(ALIASES.get(args.tool_name.strip(), args.tool_name.strip()))
        return 0
    package_root = (args.package_root or default_package_root()).resolve()
    if args.action == "install":
        install(package_root, args.backup_root)
    else:
        check(package_root)
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, RuntimeError, subprocess.CalledProcessError) as error:
        print(f"ERROR: {error}", file=sys.stderr)
        raise SystemExit(1)
