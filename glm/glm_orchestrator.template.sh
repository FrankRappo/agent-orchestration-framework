#!/usr/bin/env bash
# Dynamic queue for headless GLM workers. One process owns the controller lock.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="${PROJECT_DIR:?need PROJECT_DIR}"
TASK_DIR="${TASK_DIR:-$PROJECT_DIR/tasks}"
REPORT_DIR="${REPORT_DIR:-$PROJECT_DIR/reports}"
LOG_DIR="${LOG_DIR:-$PROJECT_DIR/logs}"
STATE_DIR="${STATE_DIR:-$PROJECT_DIR/state/glm}"
ORCH_DIR="${ORCH_DIR:-$PROJECT_DIR/orch}"
OLOG="${OLOG:-$LOG_DIR/glm_orchestrator.log}"
SUPERVISOR="${SUPERVISOR:-$ROOT/glm_supervisor.template.sh}"
METADATA="${METADATA:-$ROOT/task_metadata.py}"
POLICY="${MODEL_POLICY:-$ROOT/model_policy.json}"
QUOTA_MONITOR="${QUOTA_MONITOR:-$ROOT/../common/quota_monitor.py}"
CONTROLLER="${CONTROLLER:-manual}"
TASK_AUTHOR="${TASK_AUTHOR:-$CONTROLLER}"
MAX_PARALLEL="${MAX_PARALLEL:-1}"
POLL="${POLL:-10}"
IDLE_EXIT="${IDLE_EXIT:-0}"
QUOTA_POLICY="${QUOTA_POLICY:-warn}"
QUOTA_RESERVE_PERCENT="${QUOTA_RESERVE_PERCENT:-15}"
QUOTA_MAX_AGE="${QUOTA_MAX_AGE:-21600}"
GLM_BIN="${GLM_BIN:-glm}"
TASKS="${TASKS:-}"

STATUS_RE='^[[:space:]]*[*#`>[:space:]]*STATUS:[[:space:]]*(SUCCESS|FAIL|BLOCKED|PARTIAL)[*`[:space:]]*$'

mkdir -p "$TASK_DIR" "$REPORT_DIR" "$LOG_DIR" "$STATE_DIR" "$ORCH_DIR"
exec >> "$OLOG" 2>&1
log(){ echo "[$(date '+%F %T')] $*"; }

command -v flock >/dev/null 2>&1 || { log "FATAL: flock is required"; exit 2; }
exec 9> "$STATE_DIR/controller.lock"
if ! flock -n 9; then
  log "FATAL: another controller owns $STATE_DIR/controller.lock"
  exit 3
fi

project_hash="$(printf '%s' "$PROJECT_DIR" | sha256sum | cut -c1-8)"
python3 - "$ORCH_DIR/run.json" "$CONTROLLER" "$TASK_AUTHOR" "$PROJECT_DIR" "$$" <<'PY'
import json, os, sys, time
path, controller, author, project, pid = sys.argv[1:]
data = {"schema_version": 1, "controller": controller, "task_author": author,
        "executor": "glm", "project": project, "pid": int(pid), "started_at": int(time.time())}
tmp = path + ".tmp"
with open(tmp, "w", encoding="utf-8") as f:
    json.dump(data, f, ensure_ascii=False, indent=2); f.write("\n")
os.replace(tmp, path)
PY

discover_tasks(){
  if [[ -n "$TASKS" ]]; then printf '%s\n' $TASKS
  else find "$TASK_DIR" -maxdepth 1 -type f -name 'T*.md' -printf '%f\n' | sed 's/\.md$//' | sort
  fi
}

task_file(){
  local task="$1" exact="$TASK_DIR/$task.md"
  [[ -f "$exact" ]] && { printf '%s\n' "$exact"; return; }
  find "$TASK_DIR" -maxdepth 1 -type f -name "$task*.md" | sort | head -1
}

report_file(){
  local task="$1" exact="$REPORT_DIR/report_$task.md" tf declared prefix alias
  [[ -f "$exact" ]] && { printf '%s\n' "$exact"; return; }
  tf="$(task_file "$task")"
  declared="$(grep -aoE 'reports/report_[A-Za-z0-9_.-]+\.md' "$tf" 2>/dev/null | head -1 || true)"
  [[ -n "$declared" ]] && { printf '%s\n' "$PROJECT_DIR/$declared"; return; }
  prefix="${task%%_*}"
  alias="$(find "$REPORT_DIR" -maxdepth 1 -type f \( -name "report_$task*.md" -o -name "report_$prefix*.md" \) | sort | head -1)"
  printf '%s\n' "${alias:-$exact}"
}

report_status(){
  local report="$1"
  [[ -f "$report" ]] || return 0
  grep -aE "$STATUS_RE" "$report" 2>/dev/null | tail -1 \
    | sed -E 's/^[^S]*STATUS:[[:space:]]*(SUCCESS|FAIL|BLOCKED|PARTIAL).*/\1/'
}

session_name(){
  local task="$1" safe
  safe="$(printf '%s' "$task" | tr -cs 'A-Za-z0-9_-' '_')"
  printf 'glm_%s_%s_sup\n' "$project_hash" "${safe:0:80}"
}

tmux_alive(){ tmux has-session -t "=$1" 2>/dev/null; }

active_count(){
  local count=0 file session
  for file in "$STATE_DIR"/*.session; do
    [[ -f "$file" ]] || continue
    session="$(cat "$file" 2>/dev/null || true)"
    [[ -n "$session" ]] && tmux_alive "$session" && count=$((count + 1))
  done
  printf '%s\n' "$count"
}

lock_active(){
  local wanted="$1" file session held
  [[ "$wanted" == none ]] && return 1
  for file in "$STATE_DIR"/*.lock; do
    [[ -f "$file" ]] || continue
    held="$(cat "$file" 2>/dev/null || true)"
    [[ "$held" == "$wanted" ]] || continue
    session="$(cat "${file%.lock}.session" 2>/dev/null || true)"
    [[ -n "$session" ]] && tmux_alive "$session" && return 0
  done
  return 1
}

quota_allows(){
  local model="$1" rc=0 output decision
  local -a quota_args=(--json --admit-provider zcode --admit-model "$model"
    --reserve-percent "$QUOTA_RESERVE_PERCENT" --max-age "$QUOTA_MAX_AGE")
  [[ "$QUOTA_POLICY" == enforce ]] && quota_args+=(--fail-closed)
  output="$(python3 "$QUOTA_MONITOR" "${quota_args[@]}" 2>&1)" || rc=$?
  decision="$(printf '%s' "$output" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("admission",{}).get("decision","unknown"))' 2>/dev/null || echo error)"
  case "$decision" in
    allow) return 0 ;;
    deny) log "QUOTA-DEFER model=$model reserve=${QUOTA_RESERVE_PERCENT}%"; return 1 ;;
    unknown)
      if [[ "$QUOTA_POLICY" == enforce ]]; then
        log "QUOTA-UNKNOWN enforce mode; deferring model=$model"
        return 1
      fi
      log "QUOTA-WARN unknown/stale snapshot; allowing model=$model in warn mode"
      return 0
      ;;
    *) log "QUOTA-WARN monitor rc=$rc parse=$decision; allowing because monitor failure is not proof of exhaustion"; return 0 ;;
  esac
}

start_task(){
  local task="$1" tf report metadata complexity provider model mode resource no_respawn max_respawn max_runtime session
  tf="$(task_file "$task")"; report="$(report_file "$task")"
  metadata="$(python3 "$METADATA" --policy "$POLICY" "$tf")" || { log "invalid metadata task=$task"; return 1; }
  IFS=$'\t' read -r complexity provider model mode resource no_respawn max_respawn max_runtime <<< "$metadata"
  [[ "$no_respawn" == true ]] && max_respawn=0
  quota_allows "$model" || return 1
  lock_active "$resource" && { log "waiting resource-lock=$resource task=$task"; return 1; }
  session="$(session_name "$task")"
  tmux_alive "$session" && return 0
  printf '%s\n' "$session" > "$STATE_DIR/$task.session"
  printf '%s\n' "$resource" > "$STATE_DIR/$task.lock"
  printf '%s\n' "$(date +%s)" > "$STATE_DIR/$task.queued"
  log "starting task=$task session=$session complexity=$complexity model=$model mode=$mode lock=$resource controller=$CONTROLLER"
  tmux new-session -d -s "$session" -c "$PROJECT_DIR" \
    -e "TASK=$task" -e "PROJECT_DIR=$PROJECT_DIR" -e "TASK_FILE=$tf" -e "REPORT=$report" \
    -e "LOG=$LOG_DIR/$task.log" -e "STATE_DIR=$STATE_DIR" -e "PROVIDER_ID=$provider" \
    -e "MODEL_ID=$model" -e "MODE=$mode" -e "CONTROLLER=$CONTROLLER" \
    -e "USAGE_LEDGER=$LOG_DIR/glm_usage.jsonl" \
    -e "MAX_RESPAWN=$max_respawn" -e "MAX_RUNTIME_SECONDS=$max_runtime" -e "POLL=$POLL" \
    -e "GLM_BIN=$GLM_BIN" -e "NOTIFY_CMD=${NOTIFY_CMD:-}" \
    bash "$SUPERVISOR"
}

cleanup_finished(){
  local file task session report status
  for file in "$STATE_DIR"/*.session; do
    [[ -f "$file" ]] || continue
    task="$(basename "$file" .session)"; session="$(cat "$file" 2>/dev/null || true)"
    [[ -n "$session" ]] && tmux_alive "$session" && continue
    report="$(report_file "$task")"; status="$(report_status "$report")"
    if [[ -n "$status" ]]; then
      log "finished task=$task status=$status report=$report"
      printf -- '- [%s] %s — %s\n' "$([[ "$status" == SUCCESS ]] && echo x || echo '~')" "$task" "$status" >> "$ORCH_DIR/progress.md"
    else
      log "session ended without terminal report task=$task; eligible for relaunch"
    fi
    rm -f "$file" "$STATE_DIR/$task.lock" "$STATE_DIR/$task.queued"
  done
}

all_terminal(){
  local task report
  for task in $(discover_tasks); do
    report="$(report_file "$task")"
    [[ -n "$(report_status "$report")" ]] || return 1
  done
  return 0
}

[[ -f "$ORCH_DIR/progress.md" ]] || printf '# GLM queue progress\n' > "$ORCH_DIR/progress.md"
log "orchestrator start controller=$CONTROLLER author=$TASK_AUTHOR max_parallel=$MAX_PARALLEL project=$PROJECT_DIR"

while :; do
  cleanup_finished
  if all_terminal && (( $(active_count) == 0 )); then
    # A fast worker can die between the first cleanup pass and this check.
    # Reap its state before a one-shot queue exits.
    cleanup_finished
    if [[ "$IDLE_EXIT" == 1 ]]; then
      touch "$REPORT_DIR/ALL_DONE"
      log "ALL DONE"
      exit 0
    fi
    sleep "$POLL"
    continue
  fi
  for task in $(discover_tasks); do
    (( $(active_count) < MAX_PARALLEL )) || break
    tf="$(task_file "$task")"; [[ -f "$tf" ]] || continue
    [[ -n "$(report_status "$(report_file "$task")")" ]] && continue
    session="$(session_name "$task")"; tmux_alive "$session" && continue
    start_task "$task" || true
  done
  sleep "$POLL"
done
