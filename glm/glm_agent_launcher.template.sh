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
EFFECTIVE_MODE="$MODE"
if [[ "${GLM_HEADLESS_AUTO_APPROVE:-1}" == 1 && "$MODE" =~ ^(build|edit)$ ]]; then
  EFFECTIVE_MODE=yolo
fi
CONTROLLER="${CONTROLLER:-manual}"
GLM_BIN="${GLM_BIN:-glm}"
GLM_PATH_STYLE="${GLM_PATH_STYLE:-native}"
GLM_DISALLOWED_TOOLS="${GLM_DISALLOWED_TOOLS:-}"
USAGE_LEDGER="${USAGE_LEDGER:-$(dirname "$LOG")/glm_usage.jsonl}"

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
if [[ "$GLM_PATH_STYLE" == windows ]] && command -v wslpath >/dev/null 2>&1; then
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
args=(--cwd "$PROJECT_DIR" --mode "$EFFECTIVE_MODE" --surface terminal --no-color --json)
if [[ -n "$GLM_DISALLOWED_TOOLS" ]]; then
  args+=(--disallowed-tools "$GLM_DISALLOWED_TOOLS")
fi

printf '[%s] launch task=%s controller=%s provider=%s model=%s requested_mode=%s effective_mode=%s\n' \
  "$(date '+%F %T')" "$TASK" "$CONTROLLER" "$PROVIDER_ID" "$MODEL_ID" "$MODE" "$EFFECTIVE_MODE" >> "$LOG"
response_file="$STATE_DIR/$TASK.response.json"
set +e
"$GLM_BIN" "${args[@]}" --prompt "$prompt" > "$response_file" 2>> "$LOG"
rc=$?
set -e
cat "$response_file" >> "$LOG"
printf '\n' >> "$LOG"

python3 - "$response_file" "$USAGE_LEDGER" "$TASK" "$MODEL_ID" "$PROVIDER_ID" <<'PY'
import fcntl, json, os, sys, time
response_path, ledger_path, task, model, provider = sys.argv[1:]
text = open(response_path, encoding="utf-8", errors="replace").read()
decoder = json.JSONDecoder()
objects = []
index = 0
while index < len(text):
    start = text.find("{", index)
    if start < 0:
        break
    try:
        value, length = decoder.raw_decode(text[start:])
        objects.append(value)
        index = start + length
    except json.JSONDecodeError:
        index = start + 1
usage = next((item.get("usage") for item in reversed(objects)
              if isinstance(item, dict) and isinstance(item.get("usage"), dict)), None)
if usage:
    def number(source, camel, default=0):
        value = source.get(camel, default)
        return int(value) if isinstance(value, (int, float)) else default
    entry = {
        "timestamp": int(time.time()),
        "task": task,
        "model": model,
        "provider": provider,
        "session_id": next((item.get("sessionId") for item in reversed(objects)
                            if isinstance(item, dict) and item.get("sessionId")), None),
        "model_request_count": number(usage, "modelRequestCount"),
        "input_tokens": number(usage, "inputTokens"),
        "output_tokens": number(usage, "outputTokens"),
        "total_tokens": number(usage, "totalTokens"),
        "cache_read_tokens": number(usage, "cacheReadTokens"),
        "cache_write_tokens": number(usage, "cacheWriteTokens"),
        "reasoning_tokens": number(usage, "reasoningTokens"),
        "web_fetch_requests": number(usage, "webFetchRequests"),
        "web_search_requests": number(usage, "webSearchRequests"),
    }
    os.makedirs(os.path.dirname(ledger_path), exist_ok=True)
    with open(ledger_path, "a", encoding="utf-8") as handle:
        fcntl.flock(handle, fcntl.LOCK_EX)
        handle.write(json.dumps(entry, ensure_ascii=False, separators=(",", ":")) + "\n")
        handle.flush()
        os.fsync(handle.fileno())
        fcntl.flock(handle, fcntl.LOCK_UN)
PY

exit "$rc"
