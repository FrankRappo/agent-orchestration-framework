#!/usr/bin/env bash
# Unified entrypoint: Codex-authored or GLM-authored tasks, GLM workers.
set -euo pipefail

COMMON_ROOT="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
SETTINGS_ROOT="$(cd "$COMMON_ROOT/.." && pwd)"
GLM_ROOT="$SETTINGS_ROOT/glm"
ORCHESTRATOR="$GLM_ROOT/glm_orchestrator.template.sh"
GLM_CONTROLLER="$GLM_ROOT/glm_controller.template.sh"
QUOTA_MONITOR="$COMMON_ROOT/quota_monitor.py"
QUOTA_WATCH="$COMMON_ROOT/quota_watch.template.sh"
QUOTA_WATCH_SESSION="${QUOTA_WATCH_SESSION:-agent_quota_watch}"

usage(){ cat <<'EOF'
Usage:
  orchestrate start --project DIR --controller glm|codex|manual [--goal FILE]
                    [--max-parallel N] [--idle-exit] [--quota-policy warn|enforce]
  orchestrate status --project DIR
  orchestrate attach --project DIR
  orchestrate stop --project DIR
  orchestrate limits [--json]
  orchestrate usage --project DIR [--json]
  orchestrate doctor [--live]

controller=glm   GLM decomposes --goal when tasks/ is empty, then controls the queue.
controller=codex Tasks are prepared by Codex; the shared queue runs GLM workers.
controller=manual Tasks are prepared by the user; the shared queue runs GLM workers.
EOF
}

command_name="${1:-}"
[[ -n "$command_name" ]] || { usage; exit 2; }
shift

PROJECT_DIR=""
CONTROLLER=""
GOAL_FILE=""
MAX_PARALLEL=1
IDLE_EXIT=0
QUOTA_POLICY=warn
LIVE=0
AS_JSON=0

while (($#)); do
  case "$1" in
    --project) PROJECT_DIR="${2:?missing --project value}"; shift 2 ;;
    --controller) CONTROLLER="${2:?missing --controller value}"; shift 2 ;;
    --goal) GOAL_FILE="${2:?missing --goal value}"; shift 2 ;;
    --max-parallel) MAX_PARALLEL="${2:?missing --max-parallel value}"; shift 2 ;;
    --quota-policy) QUOTA_POLICY="${2:?missing --quota-policy value}"; shift 2 ;;
    --idle-exit) IDLE_EXIT=1; shift ;;
    --live) LIVE=1; shift ;;
    --json) AS_JSON=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage; exit 2 ;;
  esac
done

project_session(){
  local hash
  hash="$(printf '%s' "$PROJECT_DIR" | sha256sum | cut -c1-8)"
  printf 'agent_orch_%s\n' "$hash"
}

require_project(){
  [[ -n "$PROJECT_DIR" ]] || { echo "--project is required" >&2; exit 2; }
  PROJECT_DIR="$(readlink -f "$PROJECT_DIR")"
  [[ -d "$PROJECT_DIR" ]] || { echo "Project directory not found: $PROJECT_DIR" >&2; exit 2; }
}

case "$command_name" in
  doctor)
    if [[ "$LIVE" -eq 1 ]]; then exec bash "$GLM_ROOT/glm_runtime_doctor.template.sh" --live
    else exec bash "$GLM_ROOT/glm_runtime_doctor.template.sh"
    fi
    ;;
  limits)
    [[ "$AS_JSON" -eq 1 ]] && exec python3 "$QUOTA_MONITOR" --json
    exec python3 "$QUOTA_MONITOR"
    ;;
  usage)
    require_project
    report="$COMMON_ROOT/glm_usage_report.py"
    [[ "$AS_JSON" -eq 1 ]] && exec python3 "$report" "$PROJECT_DIR/logs/glm_usage.jsonl" --logs-dir "$PROJECT_DIR/logs" --json
    exec python3 "$report" "$PROJECT_DIR/logs/glm_usage.jsonl" --logs-dir "$PROJECT_DIR/logs"
    ;;
  start)
    require_project
    CONTROLLER="${CONTROLLER:-glm}"
    [[ "$CONTROLLER" =~ ^(glm|codex|manual)$ ]] || { echo "Invalid controller: $CONTROLLER" >&2; exit 2; }
    [[ "$MAX_PARALLEL" =~ ^[1-9][0-9]*$ ]] || { echo "Invalid --max-parallel" >&2; exit 2; }
    [[ "$QUOTA_POLICY" =~ ^(warn|enforce)$ ]] || { echo "Invalid --quota-policy" >&2; exit 2; }
    mkdir -p "$PROJECT_DIR"/{tasks,reports,logs,state/glm,orch}
    if [[ "$CONTROLLER" != glm ]] && ! find "$PROJECT_DIR/tasks" -maxdepth 1 -type f -name 'T*.md' -print -quit | grep -q .; then
      echo "$CONTROLLER controller requires prepared tasks/T*.md files" >&2
      exit 3
    fi
    if [[ "$CONTROLLER" == glm && ! -f "$GOAL_FILE" ]] && ! find "$PROJECT_DIR/tasks" -maxdepth 1 -type f -name 'T*.md' -print -quit | grep -q .; then
      echo "GLM controller requires --goal FILE when tasks/ is empty" >&2
      exit 3
    fi
    session="$(project_session)"
    tmux has-session -t "=$session" 2>/dev/null && { echo "Already running: $session" >&2; exit 4; }
    if ! tmux has-session -t "=$QUOTA_WATCH_SESSION" 2>/dev/null; then
      tmux new-session -d -s "$QUOTA_WATCH_SESSION" -c "$PROJECT_DIR" \
        -e "NOTIFY_CMD=${NOTIFY_CMD:-}" \
        -e "QUOTA_STATE_DIR=${QUOTA_STATE_DIR:-/work/glm/limits}" \
        bash "$QUOTA_WATCH"
    fi
    runner="$ORCHESTRATOR"
    author="$CONTROLLER"
    if [[ "$CONTROLLER" == glm ]]; then runner="$GLM_CONTROLLER"; fi
    tmux new-session -d -s "$session" -c "$PROJECT_DIR" \
      -e "PROJECT_DIR=$PROJECT_DIR" -e "CONTROLLER=$CONTROLLER" -e "TASK_AUTHOR=$author" \
      -e "GOAL_FILE=$GOAL_FILE" -e "MAX_PARALLEL=$MAX_PARALLEL" -e "IDLE_EXIT=$IDLE_EXIT" \
      -e "QUOTA_POLICY=$QUOTA_POLICY" -e "GLM_BIN=${GLM_BIN:-glm}" \
      -e "GLM_PATH_STYLE=${GLM_PATH_STYLE:-native}" -e "POLL=${POLL:-10}" \
      bash "$runner"
    python3 - "$PROJECT_DIR/orch/launch.json" "$session" "$CONTROLLER" "$author" <<'PY'
import json, os, sys, time
path, session, controller, author = sys.argv[1:]
data={"schema_version":1,"session":session,"controller":controller,"task_author":author,
      "executor":"glm","launched_at":int(time.time())}
tmp=path+".tmp"
with open(tmp,"w",encoding="utf-8") as f: json.dump(data,f,indent=2); f.write("\n")
os.replace(tmp,path)
PY
    echo "Started session=$session controller=$CONTROLLER executor=glm project=$PROJECT_DIR"
    ;;
  status)
    require_project
    session="$(project_session)"
    if tmux has-session -t "=$session" 2>/dev/null; then echo "orchestrator: RUNNING ($session)"
    else echo "orchestrator: STOPPED ($session)"
    fi
    [[ -f "$PROJECT_DIR/orch/launch.json" ]] && cat "$PROJECT_DIR/orch/launch.json"
    for report in "$PROJECT_DIR"/reports/report_*.md; do
      [[ -f "$report" ]] || continue
      status="$(grep -aE 'STATUS:[[:space:]]*(SUCCESS|FAIL|BLOCKED|PARTIAL)' "$report" | tail -1 || true)"
      printf '%s: %s\n' "$(basename "$report")" "${status:-NO TERMINAL STATUS}"
    done
    ;;
  attach)
    require_project
    exec tmux attach -t "=$(project_session)"
    ;;
  stop)
    require_project
    session="$(project_session)"
    tmux kill-session -t "=$session" 2>/dev/null || true
    hash="${session#agent_orch_}"
    while IFS= read -r worker; do
      [[ -n "$worker" ]] && tmux kill-session -t "=$worker" 2>/dev/null || true
    done < <(tmux list-sessions -F '#{session_name}' 2>/dev/null | grep -E "^glm_${hash}_.*_sup$" || true)
    echo "Stopped $session and its GLM worker sessions"
    ;;
  *) usage; exit 2 ;;
esac
