#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

python3 "$ROOT/common/tests/test_quota_monitor.py"
bash "$ROOT/glm/tests/test_glm_framework.sh"

while IFS= read -r script; do
  bash -n "$script"
done < <(find "$ROOT/common" "$ROOT/glm" -type f -name '*.sh' | sort)

python3 -m py_compile \
  "$ROOT/common/quota_monitor.py" \
  "$ROOT/glm/task_metadata.py" \
  "$ROOT/common/tests/test_quota_monitor.py"

echo "run_glm_tests: PASS"
