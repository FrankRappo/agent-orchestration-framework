#!/usr/bin/env bash
# Periodically persist normalized GLM/ZCode and Codex usage snapshots.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MONITOR="${QUOTA_MONITOR:-$ROOT/quota_monitor.py}"
STATE_DIR="${QUOTA_STATE_DIR:-/work/glm/limits}"
INTERVAL="${QUOTA_INTERVAL_SECONDS:-300}"
NOTIFY_CMD="${NOTIFY_CMD:-}"
ONCE="${ONCE:-0}"

mkdir -p "$STATE_DIR"
SNAPSHOT="$STATE_DIR/latest.json"
LEVEL_FILE="$STATE_DIR/alert-level"

notify(){
  [[ -n "$NOTIFY_CMD" ]] && $NOTIFY_CMD "$*" >/dev/null 2>&1 || true
}

while :; do
  tmp="$STATE_DIR/.latest.$$.json"
  if python3 "$MONITOR" --json > "$tmp"; then
    mv "$tmp" "$SNAPSHOT"
    level="$(python3 - "$SNAPSHOT" <<'PY'
import json, sys
rank = {"ok": 0, "warning": 1, "high": 2, "critical": 3}
data = json.load(open(sys.argv[1], encoding="utf-8"))
levels = [str(x.get("status", "ok")) for x in data.get("buckets", [])]
print(max(levels, key=lambda x: rank.get(x, 0), default="unknown"))
PY
)"
    previous="$(cat "$LEVEL_FILE" 2>/dev/null || true)"
    printf '%s\n' "$level" > "$LEVEL_FILE"
    if [[ "$level" != "$previous" && "$level" =~ ^(warning|high|critical)$ ]]; then
      notify "Agent quota level changed: $level. Snapshot: $SNAPSHOT"
    fi
  else
    echo "[$(date '+%F %T')] quota monitor failed" >&2
  fi
  [[ "$ONCE" == 1 ]] && exit 0
  sleep "$INTERVAL"
done
