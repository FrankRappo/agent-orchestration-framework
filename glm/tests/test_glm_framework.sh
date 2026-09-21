#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
project="$WORK/project"
mkdir -p "$project"/{tasks,reports,logs,state/glm,orch}
sessions=()
cleanup(){
  for session in "${sessions[@]}"; do tmux kill-session -t "=$session" 2>/dev/null || true; done
  rm -rf "$WORK"
}
trap cleanup EXIT

cat > "$WORK/fake-glm" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
case " ${*:-} " in
  *' --version '*) echo '0.test'; exit 0 ;;
  *' doctor '*) echo '{"cli":{"name":"fake"}}'; exit 0 ;;
esac
printf '{"result":"fake worker completed","model":"%s"}\n' "${GLM_TASK_MODEL:-unknown}"
if [[ "${GLM_TASK_ID:-}" == CONTROLLER_PLAN ]]; then
  mkdir -p "$GLM_TASK_PROJECT/tasks"
  cat > "$GLM_TASK_PROJECT/tasks/T01_generated.md" <<'EOF'
# generated task
Complexity: low
Model: auto
Mode: build
Resource-Lock: none

Write `reports/report_T01.md` as the required report.
EOF
fi
cat > "$GLM_TASK_REPORT" <<EOF
# Fake report

model=${GLM_TASK_MODEL:-unknown}

STATUS: SUCCESS
EOF
SH
chmod +x "$WORK/fake-glm"

cat > "$WORK/fake-quota" <<'SH'
#!/usr/bin/env bash
echo '{"admission":{"decision":"allow"},"buckets":[]}'
SH
chmod +x "$WORK/fake-quota"

cat > "$project/tasks/T01_low.md" <<'EOF'
# T01 low-risk fixture
Complexity: low
Model: auto
Mode: build
Resource-Lock: none

Write `reports/report_T01.md` as the required report.
EOF

metadata="$(python3 "$ROOT/task_metadata.py" --policy "$ROOT/model_policy.json" "$project/tasks/T01_low.md")"
IFS=$'\t' read -r complexity provider model mode resource no_respawn max_respawn max_runtime <<< "$metadata"
[[ "$complexity" == low ]]
[[ "$provider" == account:zai-individual-coding-plan ]]
[[ "$model" == GLM-5.3-Flash ]]
[[ "$mode" == build ]]

cat > "$project/tasks/T02_invalid.md" <<'EOF'
# invalid model fixture
Complexity: low
Model: does-not-exist
EOF
if python3 "$ROOT/task_metadata.py" --policy "$ROOT/model_policy.json" "$project/tasks/T02_invalid.md" >/dev/null 2>&1; then
  echo "invalid model was accepted" >&2
  exit 1
fi
rm "$project/tasks/T02_invalid.md"

timeout 35s env PROJECT_DIR="$project" IDLE_EXIT=1 MAX_PARALLEL=1 POLL=1 \
  GLM_BIN="$WORK/fake-glm" QUOTA_MONITOR="$WORK/fake-quota" QUOTA_POLICY=enforce \
  bash "$ROOT/glm_orchestrator.template.sh"

grep -q '^STATUS: SUCCESS$' "$project/reports/report_T01.md"
grep -q 'model=GLM-5.3-Flash' "$project/reports/report_T01.md"
[[ -f "$project/reports/ALL_DONE" ]]
grep -q 'ALL DONE' "$project/logs/glm_orchestrator.log"

# Unified dispatcher: Codex owns task authoring while GLM is the executor.
project2="$WORK/project-dispatch"
mkdir -p "$project2/tasks"
cp "$project/tasks/T01_low.md" "$project2/tasks/T01_low.md"
quota_session="quota_test_$$"
GLM_BIN="$WORK/fake-glm" QUOTA_WATCH_SESSION="$quota_session" POLL=1 \
  bash "$ROOT/../common/orchestrate.template.sh" start \
    --project "$project2" --controller codex --idle-exit --quota-policy warn
main_session="agent_orch_$(printf '%s' "$project2" | sha256sum | cut -c1-8)"
sessions+=("$quota_session" "$main_session")
for _ in $(seq 1 30); do
  tmux has-session -t "=$main_session" 2>/dev/null || break
  sleep 1
done
if tmux has-session -t "=$main_session" 2>/dev/null; then
  echo "dispatcher session did not finish" >&2
  exit 1
fi
grep -q '^STATUS: SUCCESS$' "$project2/reports/report_T01.md"
[[ -f "$project2/reports/ALL_DONE" ]]
[[ ! -f "$project2/state/glm/T01_low.session" ]]

# GLM-owned route: planner creates tasks, then the same queue executes them.
project3="$WORK/project-glm-controller"
mkdir -p "$project3"
printf 'Implement a harmless fixture.\n' > "$project3/GOAL.md"
quota_session3="quota_test_glm_$$"
GLM_BIN="$WORK/fake-glm" QUOTA_WATCH_SESSION="$quota_session3" POLL=1 \
  bash "$ROOT/../common/orchestrate.template.sh" start \
    --project "$project3" --controller glm --goal "$project3/GOAL.md" \
    --idle-exit --quota-policy warn
main_session3="agent_orch_$(printf '%s' "$project3" | sha256sum | cut -c1-8)"
sessions+=("$quota_session3" "$main_session3")
for _ in $(seq 1 45); do
  tmux has-session -t "=$main_session3" 2>/dev/null || break
  sleep 1
done
if tmux has-session -t "=$main_session3" 2>/dev/null; then
  echo "GLM-controller session did not finish" >&2
  exit 1
fi
[[ -f "$project3/tasks/T01_generated.md" ]]
grep -q '^STATUS: SUCCESS$' "$project3/orch/controller_report.md"
grep -q '^STATUS: SUCCESS$' "$project3/reports/report_T01.md"
[[ -f "$project3/reports/ALL_DONE" ]]

echo "test_glm_framework: PASS"
