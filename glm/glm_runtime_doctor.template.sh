#!/usr/bin/env bash
# Validate the installed GLM CLI. --live sends one tiny no-tools prompt.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GLM_BIN="${GLM_BIN:-glm}"
LIVE=0
[[ "${1:-}" == --live ]] && LIVE=1

failed=0
for command in python3 tmux flock "$GLM_BIN"; do
  if ! command -v "$command" >/dev/null 2>&1; then
    echo "FAIL missing command: $command"
    failed=1
  fi
done
[[ "$failed" -eq 0 ]] || exit 2

echo "GLM version: $($GLM_BIN --version)"
$GLM_BIN doctor --json --no-color
python3 "$ROOT/task_metadata.py" --policy "$ROOT/model_policy.json" "$ROOT/task.template.md" --json >/dev/null
echo "Static framework checks: OK"

[[ "$LIVE" -eq 1 ]] || {
  echo "Live model call: NOT RUN (use --live)."
  exit 0
}

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
config="$tmp/provider.json"
python3 - "$config" <<'PY'
import json, sys
json.dump({"schemaVersion":1,"config":{"providerConfigRules":{"providerRules":[]},
"modelConfigRules":{"providerModelRules":[],"manualProviderModelRules":[]},
"defaultModelSelection":{"providerId":"account:zai-start-plan","modelId":"GLM-5.3-Flash"}}},
open(sys.argv[1],"w",encoding="utf-8"),indent=2)
PY
runtime_config="$config"
command -v wslpath >/dev/null 2>&1 && runtime_config="$(wslpath -w "$config")"
export ZCODE_PERSONAL_PROVIDER_CONFIG_FILE="$runtime_config"
case ":${WSLENV:-}:" in
  *:ZCODE_PERSONAL_PROVIDER_CONFIG_FILE:*) ;;
  *) export WSLENV="${WSLENV:+$WSLENV:}ZCODE_PERSONAL_PROVIDER_CONFIG_FILE" ;;
esac

output="$($GLM_BIN --cwd "$tmp" --mode plan --surface terminal --no-color --json \
  --disallowed-tools 'Bash Edit Write' \
  --prompt 'Do not use tools. Reply with exactly GLM_RUNTIME_OK.' 2>&1)" || {
    printf '%s\n' "$output" >&2
    echo "FAIL live GLM call. Run: glm login" >&2
    exit 3
  }
printf '%s\n' "$output" | grep -q 'GLM_RUNTIME_OK' || {
  echo "FAIL live GLM response did not contain the marker" >&2
  exit 4
}
echo "Live model call: OK"
