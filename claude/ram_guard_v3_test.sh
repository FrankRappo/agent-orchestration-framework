#!/bin/bash
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
GUARD=$HERE/ram_guard_v3.sh
TEST_TMP=$(mktemp -d)
GROUPS_TO_CLEAN=()

cleanup(){
  local pg
  for pg in "${GROUPS_TO_CLEAN[@]:-}"; do
    kill -CONT -- -"$pg" 2>/dev/null || true
    kill -TERM -- -"$pg" 2>/dev/null || true
  done
  rm -rf "$TEST_TMP"
}
trap cleanup EXIT

export CONF=/dev/null
export STATE=$TEST_TMP/state
export LOG=$TEST_TMP/guard.log
export TOPLOG=$TEST_TMP/top.log
export PROTECT_FILE=$TEST_TMP/protected
export COMPAT_FLAG=$TEST_TMP/compat
export TG=$TEST_TMP/no-telegram
export RAM_GUARD_LIB_ONLY=1
mkdir -p "$STATE"
# shellcheck source=ram_guard_v3.sh
. "$GUARD"

fail(){ echo "FAIL: $*" >&2; exit 1; }

wait_for_state(){
  local pid=$1 want=$2 state i
  for i in $(seq 1 100); do
    state=$(pid_state "$pid")
    [[ "$state" = "$want"* ]] && return 0
    sleep 0.02
  done
  fail "pid=$pid state=${state:-gone}, expected $want"
}

wait_not_stopped(){
  local pid=$1 state i
  for i in $(seq 1 100); do
    state=$(pid_state "$pid")
    [[ -n "$state" && "$state" != T* && "$state" != t* ]] && return 0
    sleep 0.02
  done
  fail "pid=$pid remained stopped"
}

spawn_tree(){
  local info=$1 root child i
  setsid bash -c 'sleep 300 & child=$!; echo "$$ $child" > "$1"; wait "$child"' _ "$info" &
  for i in $(seq 1 100); do [ -s "$info" ] && break; sleep 0.02; done
  [ -s "$info" ] || fail "tree did not start"
  read -r root child < "$info"
  echo "$root $child"
}

echo "1..3"

# Интерактивный режим: лидер job остаётся живым, STOP получает только потомок.
read -r tty_root tty_child < <(spawn_tree "$TEST_TMP/tty-tree")
GROUPS_TO_CLEAN+=("$tty_root")
snapshot
P_TTY[$tty_root]=pts/test
pause_tree "$tty_root" codex || fail "tty tree was not paused"
wait_for_state "$tty_child" T
tty_root_state=$(pid_state "$tty_root")
[[ "$tty_root_state" != T* && "$tty_root_state" != t* ]] || fail "tty root was stopped"
resume_class codex || fail "tty tree did not resume"
wait_not_stopped "$tty_child"
echo "ok 1 - tty-safe pause keeps job leader foreground-capable"

# Headless-дерево можно остановить целиком и надёжно вернуть из STOP.
read -r batch_root batch_child < <(spawn_tree "$TEST_TMP/batch-tree")
GROUPS_TO_CLEAN+=("$batch_root")
snapshot
P_TTY[$batch_root]='?'
pause_tree "$batch_root" claude_batch || fail "batch tree was not paused"
wait_for_state "$batch_root" T
wait_for_state "$batch_child" T
resume_class claude_batch || fail "batch tree did not resume"
wait_not_stopped "$batch_root"
wait_not_stopped "$batch_child"
echo "ok 2 - headless tree pauses and resumes exactly"

# TERM/EXIT демона обязан снять уже записанную паузу.
snapshot
P_TTY[$batch_root]='?'
pause_tree "$batch_root" claude_batch || fail "batch tree was not paused for cleanup test"
wait_for_state "$batch_root" T
RAM_GUARD_LIB_ONLY=0 SOFT_KB=0 CRIT_KB=0 EMERG_KB=0 RESUME_KB=999999999 INTERVAL=60 \
  bash "$GUARD" loop &
daemon=$!
for i in $(seq 1 100); do [ -s "$PIDFILE" ] && break; sleep 0.02; done
[[ "$(daemon_pid)" = "$daemon" ]] || fail "daemon pid validation failed"
kill -TERM "$daemon"
wait "$daemon" 2>/dev/null || true
wait_not_stopped "$batch_root"
wait_not_stopped "$batch_child"
[ ! -e "$PIDFILE" ] || fail "daemon pidfile survived cleanup"
echo "ok 3 - daemon exit resumes tracked processes and removes pidfile"
