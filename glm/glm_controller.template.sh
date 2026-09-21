#!/usr/bin/env bash
# GLM-as-controller: turn one goal into task files, then exec the GLM queue.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="${PROJECT_DIR:?need PROJECT_DIR}"
GOAL_FILE="${GOAL_FILE:-}"
TASK_DIR="${TASK_DIR:-$PROJECT_DIR/tasks}"
REPORT_DIR="${REPORT_DIR:-$PROJECT_DIR/reports}"
LOG_DIR="${LOG_DIR:-$PROJECT_DIR/logs}"
STATE_DIR="${STATE_DIR:-$PROJECT_DIR/state/glm}"
ORCH_DIR="${ORCH_DIR:-$PROJECT_DIR/orch}"
GLM_BIN="${GLM_BIN:-glm}"
PROVIDER_ID="${GLM_PROVIDER_ID:-account:zai-individual-coding-plan}"
MODEL_ID="${GLM_CONTROLLER_MODEL:-GLM-5.3}"
FORCE_PLAN="${FORCE_PLAN:-0}"
SUPERVISOR="${SUPERVISOR:-$ROOT/glm_supervisor.template.sh}"
ORCHESTRATOR="${ORCHESTRATOR:-$ROOT/glm_orchestrator.template.sh}"

mkdir -p "$TASK_DIR" "$REPORT_DIR" "$LOG_DIR" "$STATE_DIR" "$ORCH_DIR"
exec 8> "$STATE_DIR/planner.lock"
flock -n 8 || { echo "Another GLM planner owns $STATE_DIR/planner.lock" >&2; exit 3; }

if find "$TASK_DIR" -maxdepth 1 -type f -name 'T*.md' -print -quit | grep -q . && [[ "$FORCE_PLAN" != 1 ]]; then
  echo "Existing task files found; planner skipped."
  exec env CONTROLLER=glm TASK_AUTHOR=glm bash "$ORCHESTRATOR"
fi

[[ -n "$GOAL_FILE" && -f "$GOAL_FILE" ]] || { echo "Goal file not found: ${GOAL_FILE:-<empty>}" >&2; exit 2; }

controller_task="$STATE_DIR/CONTROLLER_PLAN.md"
controller_report="$ORCH_DIR/controller_report.md"
cat > "$controller_task.tmp" <<EOF
# Controller planning task

Complexity: high
Model: $MODEL_ID
Mode: build

## Goal

$(cat "$GOAL_FILE")

## Required work

Act only as the planning controller. Inspect the repository and decompose the goal into
independent, verifiable files named `$TASK_DIR/T<NN>_<slug>.md`. Use the task contract in
`$ROOT/task.template.md`. Assign `Complexity`, `Model: auto`, `Mode`, resource locks,
acceptance gates, exact verification commands, and a unique required report path for each
task. Prefer small tasks with non-overlapping file ownership. Do not implement the product
changes in this planning turn.

Write a controller summary to `$controller_report`. Its final line must be
`STATUS: SUCCESS` only if at least one valid task file was created; otherwise use BLOCKED.
EOF
mv "$controller_task.tmp" "$controller_task"

env TASK=CONTROLLER_PLAN PROJECT_DIR="$PROJECT_DIR" TASK_FILE="$controller_task" \
  REPORT="$controller_report" LOG="$LOG_DIR/glm_controller.log" STATE_DIR="$STATE_DIR" \
  PROVIDER_ID="$PROVIDER_ID" MODEL_ID="$MODEL_ID" MODE=build CONTROLLER=glm \
  MAX_RESPAWN="${CONTROLLER_MAX_RESPAWN:-1}" MAX_RUNTIME_SECONDS="${CONTROLLER_MAX_RUNTIME_SECONDS:-3600}" \
  POLL="${POLL:-10}" GLM_BIN="$GLM_BIN" bash "$SUPERVISOR"

count="$(find "$TASK_DIR" -maxdepth 1 -type f -name 'T*.md' | wc -l)"
if [[ "$count" -eq 0 ]]; then
  echo "GLM controller produced no task files" >&2
  exit 4
fi
echo "GLM controller created $count task(s); starting queue."
exec env CONTROLLER=glm TASK_AUTHOR=glm bash "$ORCHESTRATOR"
