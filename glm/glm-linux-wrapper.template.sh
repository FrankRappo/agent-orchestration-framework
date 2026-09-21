#!/usr/bin/env bash
# Native Linux ZCode CLI from the official ZCode .deb package.
set -euo pipefail

ZCODE_BIN="${ZCODE_LINUX_BIN:-/opt/ZCode/zcode}"
ZCODE_CLI="${ZCODE_LINUX_CLI:-/opt/ZCode/resources/glm/zcode.cjs}"
BUILTIN_PROVIDER="${ZCODE_LINUX_BUILTIN_PROVIDER:-/opt/ZCode/resources/config/provider/zcode-builtin.json}"
RUN_AS_USER="${GLM_LINUX_USER:-agentuser}"
RUN_AS_HOME="${GLM_LINUX_HOME:-/home/$RUN_AS_USER}"

[[ -x "$ZCODE_BIN" ]] || { echo "glm-linux: missing $ZCODE_BIN" >&2; exit 127; }
[[ -r "$ZCODE_CLI" ]] || { echo "glm-linux: missing $ZCODE_CLI" >&2; exit 127; }
[[ -r "$BUILTIN_PROVIDER" ]] || { echo "glm-linux: missing $BUILTIN_PROVIDER" >&2; exit 127; }

export ELECTRON_RUN_AS_NODE=1
export ZCODE_BUILTIN_PROVIDER_CONFIG_FILE="$BUILTIN_PROVIDER"

if [[ "$EUID" -eq 0 && "${GLM_LINUX_KEEP_ROOT:-0}" != 1 ]]; then
  launch_cwd="$PWD"
  if ! runuser -u "$RUN_AS_USER" -- test -x "$launch_cwd" 2>/dev/null; then
    launch_cwd=/work
  fi
  cd "$launch_cwd"
  env_args=(
    "HOME=$RUN_AS_HOME"
    "PATH=/usr/local/bin:/usr/bin:/bin"
    "ELECTRON_RUN_AS_NODE=1"
    "ZCODE_BUILTIN_PROVIDER_CONFIG_FILE=$BUILTIN_PROVIDER"
  )
  for name in ZCODE_PERSONAL_PROVIDER_CONFIG_FILE ZCODE_DATA_BASE_DIR ZCODE_DYNAMIC_WORKFLOW_MODE; do
    [[ -n "${!name:-}" ]] && env_args+=("$name=${!name}")
  done
  exec runuser -u "$RUN_AS_USER" -- env "${env_args[@]}" "$ZCODE_BIN" "$ZCODE_CLI" "$@"
fi

exec "$ZCODE_BIN" "$ZCODE_CLI" "$@"
