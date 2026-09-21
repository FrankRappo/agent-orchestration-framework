#!/usr/bin/env bash
# Supervise one headless GLM task: terminal report contract, retries, quota waits.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TASK="${TASK:?need TASK}"
PROJECT_DIR="${PROJECT_DIR:?need PROJECT_DIR}"
TASK_FILE="${TASK_FILE:?need TASK_FILE}"
REPORT="${REPORT:?need REPORT}"
LOG="${LOG:?need LOG}"
STATE_DIR="${STATE_DIR:?need STATE_DIR}"
PROVIDER_ID="${PROVIDER_ID:?need PROVIDER_ID}"
MODEL_ID="${MODEL_ID:?need MODEL_ID}"
MODE="${MODE:-build}"
CONTROLLER="${CONTROLLER:-manual}"
LAUNCHER="${LAUNCHER:-$ROOT/glm_agent_launcher.template.sh}"
GLM_BIN="${GLM_BIN:-glm}"
MAX_RESPAWN="${MAX_RESPAWN:-3}"
MAX_RUNTIME_SECONDS="${MAX_RUNTIME_SECONDS:-7200}"
POLL="${POLL:-10}"
RATE_LIMIT_WAIT_SECONDS="${RATE_LIMIT_WAIT_SECONDS:-900}"
RATE_LIMIT_MAX_WAITS="${RATE_LIMIT_MAX_WAITS:-32}"
NOTIFY_CMD="${NOTIFY_CMD:-}"

STATUS_RE='^[[:space:]]*[*#`>[:space:]]*STATUS:[[:space:]]*(SUCCESS|FAIL|BLOCKED|PARTIAL)[*`[:space:]]*$'
RATE_LIMIT_RE='quota|usage cap|usage limit|rate.?limit|limit reached|too many requests|429|insufficient_quota|resets? at|resetAt'
AUTH_RE='sign in|not authenticated|authentication|unauthorized|coding_plan_required|select a model before continuing|model creation failed'

mkdir -p "$STATE_DIR" "$(dirname "$REPORT")" "$(dirname "$LOG")"
SLOG="$LOG.supervisor"
exec >> "$SLOG" 2>&1

log(){ echo "[$(date '+%F %T')] $*"; }
notify(){ [[ -n "$NOTIFY_CMD" ]] && $NOTIFY_CMD "$*" >/dev/null 2>&1 || true; }

report_status(){
  [[ -f "$REPORT" ]] || return 0
  grep -aE "$STATUS_RE" "$REPORT" 2>/dev/null | tail -1 \
    | sed -E 's/^[^S]*STATUS:[[:space:]]*(SUCCESS|FAIL|BLOCKED|PARTIAL).*/\1/'
}

write_blocked_report(){
  local reason="$1"
  [[ -f "$REPORT" ]] && return 0
  local tmp="$REPORT.tmp.$$"
  {
    printf '# %s blocked\n\n' "$TASK"
    printf '%s\n\n' "$reason"
    printf 'See `%s` and `%s` for evidence.\n\n' "$LOG" "$SLOG"
    printf 'STATUS: BLOCKED\n'
  } > "$tmp"
  mv "$tmp" "$REPORT"
}

terminate_tree(){
  local pid="$1"
  kill -TERM -- "-$pid" 2>/dev/null || kill -TERM "$pid" 2>/dev/null || true
  sleep 3
  kill -KILL -- "-$pid" 2>/dev/null || kill -KILL "$pid" 2>/dev/null || true
}

rate_limited(){ tail -n 120 "$LOG" 2>/dev/null | grep -aiE "$RATE_LIMIT_RE" | tail -1; }
auth_blocked(){ tail -n 120 "$LOG" 2>/dev/null | grep -aiE "$AUTH_RE" | tail -1; }

attempt=0
rate_waits=0
while :; do
  attempt=$((attempt + 1))
  started=$(date +%s)
  printf '%s\n' "$started" > "$STATE_DIR/$TASK.started"
  : > "$STATE_DIR/$TASK.running"
  log "launch attempt=$attempt task=$TASK model=$MODEL_ID mode=$MODE"

  setsid env \
    PROJECT_DIR="$PROJECT_DIR" TASK="$TASK" TASK_FILE="$TASK_FILE" REPORT="$REPORT" \
    LOG="$LOG" STATE_DIR="$STATE_DIR" PROVIDER_ID="$PROVIDER_ID" MODEL_ID="$MODEL_ID" \
    MODE="$MODE" CONTROLLER="$CONTROLLER" GLM_BIN="$GLM_BIN" \
    GLM_DISALLOWED_TOOLS="${GLM_DISALLOWED_TOOLS:-}" \
    bash "$LAUNCHER" &
  pid=$!
  printf '%s\n' "$pid" > "$STATE_DIR/$TASK.pid"

  timed_out=0
  while kill -0 "$pid" 2>/dev/null; do
    now=$(date +%s)
    if (( now - started >= MAX_RUNTIME_SECONDS )); then
      timed_out=1
      log "runtime limit ${MAX_RUNTIME_SECONDS}s reached; terminating pgid=$pid"
      terminate_tree "$pid"
      break
    fi
    sleep "$POLL"
  done
  wait "$pid" 2>/dev/null
  rc=$?
  rm -f "$STATE_DIR/$TASK.running" "$STATE_DIR/$TASK.pid"
  : > "$STATE_DIR/$TASK.finished"

  status="$(report_status)"
  if [[ -n "$status" ]]; then
    log "terminal report task=$TASK status=$status rc=$rc"
    [[ "$status" == SUCCESS ]] && exit 0
    exit 1
  fi

  auth_line="$(auth_blocked || true)"
  if [[ -n "$auth_line" ]]; then
    log "credential/configuration blocker: $auth_line"
    write_blocked_report "GLM CLI is not authenticated or has no usable model: $auth_line"
    notify "GLM task $TASK blocked by authentication/model configuration"
    exit 2
  fi

  limit_line="$(rate_limited || true)"
  if [[ -n "$limit_line" ]]; then
    rate_waits=$((rate_waits + 1))
    if (( rate_waits > RATE_LIMIT_MAX_WAITS )); then
      write_blocked_report "GLM quota remained unavailable after $RATE_LIMIT_MAX_WAITS waits."
      log "quota wait cap reached"
      exit 2
    fi
    log "quota marker: $limit_line; wait ${RATE_LIMIT_WAIT_SECONDS}s ($rate_waits/$RATE_LIMIT_MAX_WAITS)"
    notify "GLM task $TASK waiting for quota reset"
    sleep "$RATE_LIMIT_WAIT_SECONDS"
    continue
  fi

  if (( attempt > MAX_RESPAWN )); then
    reason="GLM worker failed without a terminal report after $attempt attempts (last rc=$rc"
    [[ "$timed_out" == 1 ]] && reason+=", runtime timeout"
    reason+=")."
    write_blocked_report "$reason"
    log "$reason"
    exit 1
  fi
  log "non-quota failure rc=$rc; retrying ($attempt/$MAX_RESPAWN)"
  sleep 5
done
