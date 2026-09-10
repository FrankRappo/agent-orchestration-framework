#!/bin/bash
# Сторож ОЧЕРЕДИ: держит живым сам claude-оркестратор и поднимает его только тогда,
# когда памяти реально хватает. Шаблон для копирования в проект.
# Версия: 2026-08-12.
#
# Зачем нужен отдельный слой.
#   RAM-сторож v3 (claude/ram_guard_v3.sh) при EMERG убивает одно дерево-жертву. Кто кого
#   поднимает после этого:
#     - агент умер          -> его поднимает супервизор (в нём RAM-гейт wait_for_ram);
#     - супервизор умер     -> таск без отчёта возвращается в очередь, оркестратор стартует
#                              его заново, но только когда MemAvailable >= RAM_MIN_KB;
#     - умер сам оркестратор -> поднимать НЕКОМУ. Эту дыру и закрывает данный скрипт.
#
# Запуск (от root, чтобы пережить чистку сессий пользователя):
#   tmux new-session -d -s <proj>_keeper "PROJECT_DIR=/work/<project> SESSION=<proj>_orch \
#     RUNNER=/work/<project>/orch/_run_orch.sh bash /work/settings/claude/orchestrator_keeper.template.sh"
#
# Остановить: tmux kill-session -t =<proj>_keeper
set -u

PROJECT_DIR="${PROJECT_DIR:?need PROJECT_DIR}"
SESSION="${SESSION:?need SESSION}"                 # имя tmux-сессии оркестратора
RUNNER="${RUNNER:-$PROJECT_DIR/orch/_run_orch.sh}" # обёртка, экспортирующая PROJECT_DIR/MAX_PARALLEL/NOTIFY_CMD
ORCH_USER="${ORCH_USER:-agentuser}"                     # под ним живут tmux/jsonl/claude-auth
LOG="${LOG:-$PROJECT_DIR/logs/orch_keeper.log}"
MIN_KB="${MIN_KB:-1200000}"                        # ниже этого MemAvailable оркестратор не поднимаем
PAUSE_FLAG="${PAUSE_FLAG:-/tmp/ram_paused}"        # флаг паузы RAM-сторожа
POLL="${POLL:-60}"
MAX_PARALLEL="${MAX_PARALLEL:-}"                   # пусто -> берётся из RUNNER
NOTIFY_CMD="${NOTIFY_CMD:-}"                       # команда с ОДНИМ аргументом-сообщением
TG_GAP="${TG_GAP:-1800}"                           # не чаще одного сообщения в 30 минут

mkdir -p "$(dirname "$LOG")"
log(){ echo "[$(date '+%F %T')] $*" >> "$LOG"; }
avail_kb(){ awk '/MemAvailable/{print $2}' /proc/meminfo; }
as_user(){ runuser -u "$ORCH_USER" -- env -i HOME="/home/$ORCH_USER" \
  PATH="/home/$ORCH_USER/.local/bin:/usr/local/bin:/usr/bin:/bin" SHELL=/bin/bash "$@"; }
alive(){ as_user tmux has-session -t "=$SESSION" 2>/dev/null; }
launch(){ as_user tmux new-session -d -s "$SESSION" -c "$PROJECT_DIR" \
  "${MAX_PARALLEL:+MAX_PARALLEL=$MAX_PARALLEL }bash $RUNNER"; }

last_tg=0
notify(){ [ -n "$NOTIFY_CMD" ] || return 0
  local now; now=$(date +%s); [ $((now - last_tg)) -lt "$TG_GAP" ] && return 0
  last_tg=$now; $NOTIFY_CMD "$1" >/dev/null 2>&1; return 0; }

log "keeper start session=$SESSION project=$PROJECT_DIR min_kb=$MIN_KB poll=${POLL}s"
while true; do
  if alive; then sleep "$POLL"; continue; fi

  a="$(avail_kb)"
  if [ -f "$PAUSE_FLAG" ]; then
    log "оркестратор мёртв, RAM-сторож держит паузу — жду (avail=${a}KB)"
    notify "Очередь $SESSION: оркестратор упал, RAM-сторож в паузе. Подниму, как освободится память."
    sleep "$POLL"; continue
  fi
  if [ "${a:-0}" -lt "$MIN_KB" ]; then
    log "оркестратор мёртв, памяти мало (avail=${a}KB < ${MIN_KB}KB) — жду"
    notify "Очередь $SESSION: оркестратор упал, памяти мало (${a}KB). Подниму позже автоматически."
    sleep "$POLL"; continue
  fi

  log "оркестратор мёртв, памяти хватает (avail=${a}KB) — поднимаю"
  if launch; then
    log "оркестратор поднят"
    notify "Очередь $SESSION: оркестратор перезапущен автоматически (avail=${a}KB)."
  else
    log "не удалось поднять оркестратор"
  fi
  sleep "$POLL"
done
