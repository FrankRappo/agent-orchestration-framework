#!/bin/bash
# Идемпотентный старт RAM-сторожа v3. Дёргается откуда угодно и сколько угодно раз:
#   - [boot] command в /etc/wsl.conf (после запуска WSL);
#   - cron (@reboot + keepalive каждые 2 минуты);
#   - /etc/profile.d/zz-ram-guard.sh (любой вход в шелл, в т.ч. сессия Claude Code).
# Если демон уже жив — тихо выходит. Заодно поднимает cron, если он не запущен
# (в этой WSL нет systemd, после ребута cron сам не стартует, а на нём висит
# projecta_exch_mirror и keepalive сторожа).
set -u

GUARD=/work/settings/claude/ram_guard_v3.sh
STATE=/run/ram_guard_v3
PIDFILE=$STATE/daemon.pid
LOG=/work/settings/claude/ram_guard_v3.log

[ "$(id -u)" = "0" ] || exit 0          # сторож нужен от root (kill чужих деревьев)

mkdir -p "$STATE" 2>/dev/null

# --- cron (в WSL без systemd после ребута мёртв) ---
pgrep -x cron >/dev/null 2>&1 || service cron start >/dev/null 2>&1

# --- сам сторож ---
if [ -f "$PIDFILE" ]; then
  pid=$(cat "$PIDFILE" 2>/dev/null)
  if [ -n "${pid:-}" ] && kill -0 "$pid" 2>/dev/null; then
    case "$(ps -o args= -p "$pid" 2>/dev/null)" in *ram_guard_v3*) exit 0;; esac
  fi
fi
# подстраховка: демон мог остаться без pid-файла
if pgrep -f 'ram_guard_v3\.sh loop' >/dev/null 2>&1; then exit 0; fi

setsid nohup bash "$GUARD" loop >>"$LOG" 2>&1 &
sleep 1
exit 0
