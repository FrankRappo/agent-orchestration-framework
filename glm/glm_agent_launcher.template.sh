#!/usr/bin/env bash
# Run one headless GLM/ZCode task. The supervisor owns retries and timeouts.
set -euo pipefail

PROJECT_DIR="${PROJECT_DIR:?need PROJECT_DIR}"
TASK="${TASK:?need TASK}"
TASK_FILE="${TASK_FILE:?need TASK_FILE}"
REPORT="${REPORT:?need REPORT}"
LOG="${LOG:?need LOG}"
STATE_DIR="${STATE_DIR:?need STATE_DIR}"
PROVIDER_ID="${PROVIDER_ID:?need PROVIDER_ID}"
MODEL_ID="${MODEL_ID:?need MODEL_ID}"
MODE="${MODE:-build}"
CONTROLLER="${CONTROLLER:-manual}"
GLM_BIN="${GLM_BIN:-glm}"
GLM_DISALLOWED_TOOLS="${GLM_DISALLOWED_TOOLS:-}"

mkdir -p "$STATE_DIR" "$(dirname "$REPORT")" "$(dirname "$LOG")"
PROMPT_FILE="$STATE_DIR/$TASK.prompt.md"
PROVIDER_CONFIG="$STATE_DIR/$TASK.provider.json"

tmp_prompt="$PROMPT_FILE.tmp.$$"
{
  cat <<PREAMBLE
You are an autonomous GLM coding worker controlled by the $CONTROLLER orchestrator.
Read the complete task before acting. Stay inside its scope. Preserve unrelated
changes. Do not push, deploy, or run destructive git commands. Continue until the
task is complete, genuinely blocked, or safely partial.

You MUST write the report to this exact path:
$REPORT

The final line of that report MUST be exactly one of:
STATUS: SUCCESS
STATUS: FAIL
STATUS: BLOCKED
STATUS: PARTIAL

Do not claim SUCCESS without verification evidence.

--- TASK BELOW ---
PREAMBLE
  cat "$TASK_FILE"
} > "$tmp_prompt"
mv "$tmp_prompt" "$PROMPT_FILE"

python3 - "$PROVIDER_CONFIG" "$PROVIDER_ID" "$MODEL_ID" <<'PY'
import json, sys
path, provider, model = sys.argv[1:]
data = {
    "schemaVersion": 1,
    "config": {
        "providerConfigRules": {"providerRules": []},
        "modelConfigRules": {"providerModelRules": [], "manualProviderModelRules": []},
        "defaultModelSelection": {"providerId": provider, "modelId": model},
    },
}
with open(path + ".tmp", "w", encoding="utf-8") as handle:
    json.dump(data, handle, ensure_ascii=False, indent=2)
    handle.write("\n")
import os
os.replace(path + ".tmp", path)
PY

provider_runtime_path="$PROVIDER_CONFIG"
if command -v wslpath >/dev/null 2>&1 && [[ "$GLM_BIN" == "glm" || "$GLM_BIN" == */glm ]]; then
  provider_runtime_path="$(wslpath -w "$PROVIDER_CONFIG")"
fi
export ZCODE_PERSONAL_PROVIDER_CONFIG_FILE="$provider_runtime_path"
case ":${WSLENV:-}:" in
  *:ZCODE_PERSONAL_PROVIDER_CONFIG_FILE:*) ;;
  *) export WSLENV="${WSLENV:+$WSLENV:}ZCODE_PERSONAL_PROVIDER_CONFIG_FILE" ;;
esac

export GLM_TASK_ID="$TASK" GLM_TASK_REPORT="$REPORT" GLM_TASK_MODEL="$MODEL_ID"
export GLM_TASK_PROJECT="$PROJECT_DIR" GLM_TASK_FILE="$TASK_FILE"
prompt="$(cat "$PROMPT_FILE")"
args=(--cwd "$PROJECT_DIR" --mode "$MODE" --surface terminal --no-color --json)
if [[ -n "$GLM_DISALLOWED_TOOLS" ]]; then
  args+=(--disallowed-tools "$GLM_DISALLOWED_TOOLS")
fi

{
  printf '[%s] launch task=%s controller=%s provider=%s model=%s mode=%s\n' \
    "$(date '+%F %T')" "$TASK" "$CONTROLLER" "$PROVIDER_ID" "$MODEL_ID" "$MODE"
  "$GLM_BIN" "${args[@]}" --prompt "$prompt"
} >> "$LOG" 2>&1
