#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ACTION="${1:-install}"
shift || true

case "$ACTION" in
  install|check|normalize) ;;
  *) printf 'Usage: %s {install|check|normalize} [arguments]\n' "$0" >&2; exit 2 ;;
esac

exec python3 "$SCRIPT_DIR/overlays/omx_conductor_recovery.py" "$ACTION" "$@"
