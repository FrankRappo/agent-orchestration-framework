#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
SUP_PID=""
CHILD_PID=""
cleanup(){
  [ -z "$CHILD_PID" ] || kill -CONT "$CHILD_PID" 2>/dev/null || true
  [ -z "$CHILD_PID" ] || kill "$CHILD_PID" 2>/dev/null || true
  [ -z "$SUP_PID" ] || kill "$SUP_PID" 2>/dev/null || true
  rm -rf "$TMP"
}
trap cleanup EXIT

assert_eq(){
  [ "$1" = "$2" ] || { printf 'assertion failed: expected %s, got %s\n' "$2" "$1" >&2; exit 1; }
}

test_transport_overlay(){
  local package="$TMP/package"
  mkdir -p "$package/src/scripts" "$package/dist/scripts"
  cat > "$package/package.json" <<'JSON'
{"type":"module"}
JSON
  cat > "$package/src/scripts/codex-native-hook.ts" <<'TS'
type CodexHookPayload = Record<string, unknown>;
interface NativeHookDispatchOptions {}
interface NativeHookDispatchResult {}
export async function dispatchCodexNativeHook(
  payload: CodexHookPayload,
  options: NativeHookDispatchOptions = {},
): Promise<NativeHookDispatchResult> {
  return payload as NativeHookDispatchResult;
}
TS
  cat > "$package/dist/scripts/codex-native-hook.js" <<'JS'
const TERMINAL_MODE_PHASES = new Set(["complete", "completed", "failed", "cancelled"]);
export async function dispatchCodexNativeHook(payload, options = {}) {
    return payload.tool_name;
}
JS

  "$ROOT/install_omx_conductor_recovery.sh" install --package-root "$package" --backup-root "$TMP/backup"
  "$ROOT/install_omx_conductor_recovery.sh" check --package-root "$package"
  "$ROOT/install_omx_conductor_recovery.sh" install --package-root "$package"
  while read -r input expected; do
    assert_eq "$("$ROOT/install_omx_conductor_recovery.sh" normalize "$input")" "$expected"
  done <<'CASES'
collaborationspawn_agent collaboration.spawn_agent
collaborationclose_agent collaboration.close_agent
collaborationsend_message collaboration.send_message
collaborationfollowup_task collaboration.followup_task
collaborationwait_agent collaboration.wait_agent
collaborationinterrupt_agent collaboration.interrupt_agent
collaborationlist_agents collaboration.list_agents
collaboration.spawn_agent collaboration.spawn_agent
multi_agent_v1.spawn_agent multi_agent_v1.spawn_agent
CASES
  assert_eq "$(node --input-type=module - "$package/dist/scripts/codex-native-hook.js" <<'JS'
import { pathToFileURL } from 'node:url';
const hook = await import(pathToFileURL(process.argv[2]));
process.stdout.write(await hook.dispatchCodexNativeHook({tool_name: 'collaborationspawn_agent'}));
JS
)" "collaboration.spawn_agent"
  test -f "$TMP/backup/src/scripts/codex-native-hook.ts"
  test -f "$TMP/backup/dist/scripts/codex-native-hook.js"
}

wait_for(){
  local attempts="$1" command="$2"
  for _ in $(seq 1 "$attempts"); do
    eval "$command" && return 0
    sleep 0.25
  done
  return 1
}

test_pause_resume_checkpoint(){
  local project="$TMP/project" state="$TMP/state" logs="$TMP/logs"
  mkdir -p "$project" "$state" "$logs"
  : > "$TMP/task.md"
  cat > "$TMP/dummy-launcher.sh" <<'SH'
#!/usr/bin/env bash
set -u
echo $$ > "$PID_FILE"
trap 'exit 0' TERM INT
while true; do
  printf 'heartbeat %s\n' "$(date +%s)" >> "$LOG"
  sleep 0.2
done
SH
  chmod +x "$TMP/dummy-launcher.sh"

  TASK=T-PAUSE PROJECT_DIR="$project" TASK_FILE="$TMP/task.md" REPORT="$TMP/report.md" \
    STATE_DIR="$state" LOG_DIR="$logs" LAUNCHER="$TMP/dummy-launcher.sh" \
    POLL=1 STALL_LIMIT=2 MAX_RESPAWN=0 \
    bash "$ROOT/codex_supervisor.template.sh" &
  SUP_PID=$!
  wait_for 40 "test -s '$state/T-PAUSE.pid'"
  CHILD_PID="$(cat "$state/T-PAUSE.pid")"
  kill -STOP "$CHILD_PID"
  wait_for 40 "grep -q '\"status\": \"paused\"' '$state/T-PAUSE.supervisor-state.json' 2>/dev/null"
  sleep 3
  kill -0 "$CHILD_PID"
  assert_eq "$(ps -o stat= -p "$CHILD_PID" | awk '{print substr($1,1,1)}')" "T"

  kill -CONT "$CHILD_PID"
  wait_for 40 "grep -q '\"resumed_at_epoch\": [0-9]' '$state/T-PAUSE.supervisor-state.json' 2>/dev/null"
  wait_for 40 "grep -q 'RESUMED:' '$logs/T-PAUSE_supervisor.log' 2>/dev/null"
  printf 'STATUS: SUCCESS\n' > "$TMP/report.md"
  wait "$SUP_PID"
  SUP_PID=""
  kill "$CHILD_PID" 2>/dev/null || true
  CHILD_PID=""
  grep -q 'PAUSED:' "$logs/T-PAUSE_supervisor.log"
  grep -q 'RESUMED:' "$logs/T-PAUSE_supervisor.log"
  ! grep -q 'STALL:' "$logs/T-PAUSE_supervisor.log"
  ! grep -q 'kill -CONT' "$ROOT/codex_supervisor.template.sh"
}

test_transport_overlay
test_pause_resume_checkpoint
printf 'PASS: transport overlay and pause/resume checkpoint regression tests\n'
