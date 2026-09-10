#!/bin/bash
# chain_tasks.template.sh — НАДЁЖНАЯ ПОСЛЕДОВАТЕЛЬНАЯ цепочка тасков поверх claude-оркестратора.
#
# Зачем: сериализация оркестратора через Resource-Lock + MAX_PARALLEL НЕ железобетонна при спайке
# добавления нескольких активных .md-тасков одного lock (см. GOTCHAS #6 — гонка, два агента разом).
# Watcher гарантирует строгий порядок: держим все таски цепочки КРОМЕ первого как `.md.staged`
# (оркестратор их игнорирует), и активируем следующий (`.staged -> .md`) ТОЛЬКО когда предыдущий
# ПОЛНОСТЬЮ завершён: отчёт содержит строку `STATUS:` И tmux-сессия таска (`claude_<task>...`) закрыта.
# Тогда активен-и-запускаем в любой момент максимум ОДИН таск цепочки → двух разом быть не может.
#
# Использование:
#   - первый таск цепочки — обычный активный `.md` (оркестратор его подхватит штатно);
#   - остальные — `<task>.md.staged` в том же tasks/;
#   - запустить watcher:
#     TASK_DIR=/work/<proj>/orch/live/tasks REPORT_DIR=/work/<proj>/orch/live/reports \
#       CHAIN="T43_money_safety_pay T46_doc_operator_instruction T47_1c_nomenclature_enable" \
#       tmux new-session -d -s <proj>_chain "bash /work/settings/claude/chain_tasks.template.sh"
#
# ENV:
#   TASK_DIR      каталог tasks/            (обяз.)
#   REPORT_DIR    каталог reports/          (обяз.)
#   CHAIN         упорядоченный список basename тасков через пробел, БЕЗ .md
#                 (первый — активный .md, остальные — .staged)     (обяз.)
#   AGENT_USER    под кем живут tmux-сессии агентов (по умолч. agentuser)
#   REPORT_PREFIX префикс отчёта -> $REPORT_DIR/<prefix><task>.md   (по умолч. report_)
#   LOG           лог-файл                 (по умолч. $TASK_DIR/../logs/chain.log)
#   POLL          интервал опроса, с       (по умолч. 60)
#
# Запуск: из-под root ИЛИ agentuser (mv/chmod над tasks/ + `runuser -u $AGENT_USER tmux ls` для проверки сессий).
set -u
TASK_DIR="${TASK_DIR:?need TASK_DIR}"
REPORT_DIR="${REPORT_DIR:?need REPORT_DIR}"
CHAIN="${CHAIN:?need CHAIN (ordered task basenames, space-separated)}"
AGENT_USER="${AGENT_USER:-agentuser}"
REPORT_PREFIX="${REPORT_PREFIX:-report_}"
LOG="${LOG:-$TASK_DIR/../logs/chain.log}"
POLL="${POLL:-60}"
STATUS_RE='STATUS:[[:space:]]*(SUCCESS|FAIL|BLOCKED|PARTIAL)'

log(){ echo "[$(date '+%F %T')] $*" >>"$LOG"; }
report_done(){ grep -qaE "$STATUS_RE" "$REPORT_DIR/${REPORT_PREFIX}$1.md" 2>/dev/null; }
tmux_gone(){ ! runuser -u "$AGENT_USER" -- tmux ls 2>/dev/null | grep -q "claude_$1"; }
activate(){ local st="$TASK_DIR/$1.md.staged"; [ -f "$st" ] || return 1
  mv "$st" "$TASK_DIR/$1.md" && chmod a+r "$TASK_DIR/$1.md" && log "activated $1 (.staged -> .md)"; }

read -r -a TASKS <<<"$CHAIN"
mkdir -p "$(dirname "$LOG")"
log "=== chain START: ${TASKS[*]} ==="
while true; do
  pending=0
  # активировать TASKS[i], когда TASKS[i-1] полностью завершён и TASKS[i] ещё .staged
  for ((i=1; i<${#TASKS[@]}; i++)); do
    cur="${TASKS[$i]}"; prev="${TASKS[$((i-1))]}"
    if [ -f "$TASK_DIR/$cur.md.staged" ]; then
      pending=1
      if report_done "$prev" && tmux_gone "$prev"; then
        log "$prev finished (report+session gone) -> activate $cur"
        activate "$cur"
      fi
    fi
  done
  [ "$pending" -eq 0 ] && { log "all chain tasks activated -> exit"; break; }
  sleep "$POLL"
done
