#!/bin/bash
# ============================================================================
# ОЖИДАТЕЛЬ СЛОТА ИСПОЛНИТЕЛЯ → ЗАПУСК ОЧЕРЕДИ  (переиспользуемый шаблон)
#
# Происхождение: /work/projecta/orch/live/wait_slot_and_launch_T200.sh.
# Обобщён в шаблон фреймворка задачей T200 — проектная специфика в переменных окружения.
#
# Зачем: исполнителей на машине допустимо не больше MAX_EXECUTORS (по умолчанию ДВА,
# HOW_TO_RUN §10.1 п.9 — иначе OOM). Этот ожидатель дожидается освобождения слота
# и достаточного MemAvailable, после чего поднимает очередь оркестратора и выходит.
#
# ============================================================================
# 🔴 ПРАВИЛА, КОТОРЫЕ НЕЛЬЗЯ «УПРОСТИТЬ» ОБРАТНО (урок ночи 06→07.08.2026)
#   1. Невозможность ПРОВЕРИТЬ ≠ «условие не выполнено». Не сумели прочитать состояние —
#      это дефект пробы. Здесь пробы локальные (pgrep + /proc/meminfo) и врать не умеют,
#      поэтому вырожденный случай прикрыт дедлайном ниже: любая новая УДАЛЁННАЯ проверка,
#      которую сюда добавят, обязана считать нечитаемый ответ поводом ИДТИ, а не ждать.
#   2. Жёсткий дедлайн, после которого старт БЕЗУСЛОВНЫЙ. Ожидание не может длиться вечно:
#      ночное окно невозвратно, бездействие ночью дороже ошибки.
#      MAX_WAIT_MIN истёк → при FORCE_AFTER_DEADLINE=1 (по умолчанию) очередь СТАРТУЕТ.
#   3. Пинг в Telegram — журнал, а не план: ночью владелец спит и сообщение никто не прочтёт.
#      Ни одна ветка не имеет права закончиться на «пингнул и жду ответа».
# ============================================================================
#
# ЗАПУСК (от root, сессия под agentuser):
#   runuser -u agentuser -- tmux new-session -d -s <proj>_slotwaiter \
#     "PROJECT_DIR=/work/<proj>/orch/live TASKS='T200 T201' \
#      bash /work/settings/claude/wait_slot_and_launch.template.sh"
# Останов: runuser -u agentuser -- tmux kill-session -t =<proj>_slotwaiter
#
# ---------------------------------------------------------------------------
# ПЕРЕМЕННЫЕ
#   PROJECT_DIR   каталог оркестратора проекта (обязательно)
#   TASKS         очередь, порядок = порядок выполнения (обязательно)
#   ORCH_RUNNER   раннер очереди       (по умолчанию $PROJECT_DIR/_run_orch.sh)
#   STATE_DIR     каталог state-файлов (по умолчанию $PROJECT_DIR/state)
#   SESSION_NAME  имя tmux-сессии очереди
#   RECHECK       интервал проверки, с
#   MAX_WAIT_MIN  сколько всего ждать, мин
#   FORCE_AFTER_DEADLINE  1 = по истечении MAX_WAIT_MIN запустить ВСЁ РАВНО (правило 2);
#                         0 = выйти с кодом 1 и оставить задачу на ручной запуск
#   RAM_MIN_MB    минимум MemAvailable
#   MAX_EXECUTORS сколько исполнителей допустимо одновременно
#   EXECUTOR_PAT  pgrep-паттерн исполнителя
#   LOG           журнал
#   NOTIFY_CMD    команда TG-пинга; пусто = не слать. ЖУРНАЛ, НЕ ПЛАН.
# ---------------------------------------------------------------------------
set -u

PROJECT_DIR="${PROJECT_DIR:?PROJECT_DIR обязателен}"
TASKS="${TASKS:?TASKS обязателен}"
ORCH_RUNNER="${ORCH_RUNNER:-$PROJECT_DIR/_run_orch.sh}"
STATE_DIR="${STATE_DIR:-$PROJECT_DIR/state}"
SESSION_NAME="${SESSION_NAME:-orch_slot_queue}"
RECHECK="${RECHECK:-120}"
MAX_WAIT_MIN="${MAX_WAIT_MIN:-180}"
FORCE_AFTER_DEADLINE="${FORCE_AFTER_DEADLINE:-1}"
RAM_MIN_MB="${RAM_MIN_MB:-1800}"
MAX_EXECUTORS="${MAX_EXECUTORS:-2}"
EXECUTOR_PAT="${EXECUTOR_PAT:-claude --dangerously}"
LOG="${LOG:-$PROJECT_DIR/logs/slotwaiter.log}"
NOTIFY_CMD="${NOTIFY_CMD:-}"

mkdir -p "$(dirname "$LOG")" 2>/dev/null
log(){ echo "[$(date '+%F %T')] $*" >> "$LOG"; }
notify(){ [ -n "$NOTIFY_CMD" ] && $NOTIFY_CMD "$1" >/dev/null 2>&1 || true; }

# 🔴 ВТОРОЙ ПЕРЕКОС ТОГО ЖЕ СЧЁТЧИКА (найден 09.08.2026, GOTCHAS #11).
# `pgrep -u agentuser -f "claude --dangerously"` считает исполнителем и САМ процесс-оркестратор:
# он тоже `claude --dangerously-skip-permissions`. При MAX_EXECUTORS=2 и ОДНОМ реальном
# исполнителе счётчик даёт 2, `2 < 2` ложно, и «слот свободен» не наступает НИКОГДА —
# ровно тот симптом, что чинили 08.08, но по другой причине. Замер 09.08: шаблонная проба
# дала 4 при двух реальных исполнителях.
# Лечение: вычитаем собственную цепочку предков (в ней и запустивший нас claude-оркестратор)
# плюс всё, что вызывающий передал в EXCLUDE_PIDS.
# 🔴 -x к pgrep НЕ добавлять: дефолтный EXECUTOR_PAT — префикс ("claude --dangerously"),
# при точном совпадении он не найдёт ничего и перекос сменится на обратный.
# 🔴 PPid берём из /proc/PID/status, а НЕ полем $4 из /proc/PID/stat: если имя процесса
# содержит пробел (например «tmux: server»), поля stat съезжают и в $4 оказывается буква
# состояния — цепочка предков обрывается с «S: integer expression expected».
self_chain(){ local p=$$; while [ "$p" -gt 1 ]; do echo "$p"; p=$(awk '/^PPid:/{print $2}' /proc/$p/status 2>/dev/null); [ -n "$p" ] || break; done; }
# 🔴 ТРЕТИЙ ПЕРЕКОС ТОГО ЖЕ СЧЁТЧИКА (найден 12.08.2026, GOTCHAS #14).
# `pgrep` по пользователю считает исполнителей ВСЕХ проектов сразу. Если на машине идёт
# волна СОСЕДНЕГО проекта, наш ожидатель видит «слот занят» и не стартует — сколько бы
# наша собственная очередь ни простаивала. Кейс PROJECTA 12.08: параллельно шла чужая волна из
# двух исполнителей, наша очередь была пуста, и таск с ПРИВЯЗКОЙ К ОКНУ (машину включают
# только в рабочее время) чуть не потерял день.
# EXECUTOR_SCOPE=own — считать только СВОИХ, по живым сессиям из своего STATE_DIR.
# EXECUTOR_SCOPE=all — прежнее поведение (по умолчанию, чтобы ничего не сломать).
# 🔴 Защита от OOM при этом НЕ ослабляется: гейты по памяти и по диску считают машину ЦЕЛИКОМ,
# и именно они, а не счётчик слотов, отвечают за то, чтобы не уронить машину.
EXECUTOR_SCOPE="${EXECUTOR_SCOPE:-all}"
count_own_executors(){   # свои = живые tmux-сессии, записанные в наш STATE_DIR
  local n=0 s sess
  for s in "$STATE_DIR"/*.session; do [ -f "$s" ] || continue
    sess=$(cat "$s" 2>/dev/null)
    [ -n "$sess" ] && tmux has-session -t "=$sess" 2>/dev/null && n=$((n+1))
  done
  echo "$n"
}
count_executors(){   # всегда одно число и код 0 — сравнение ниже не должно падать
  if [ "$EXECUTOR_SCOPE" = own ]; then count_own_executors; return 0; fi
  local excl; excl=$(printf '%s\n' $(self_chain) $EXCLUDE_PIDS)
  pgrep -u agentuser -f "$EXECUTOR_PAT" 2>/dev/null | grep -v -x -F "$excl" | wc -l | tr -d " "
}

launch_queue(){   # $1 — причина
  local why="$1" t
  for t in $TASKS; do
    rm -f "$STATE_DIR/$t".lock "$STATE_DIR/$t".pid "$STATE_DIR/$t".session \
          "$STATE_DIR/$t".started "$STATE_DIR/$t".ambiguous 2>/dev/null
  done
  tmux kill-session -t "=$SESSION_NAME" 2>/dev/null
  tmux new-session -d -s "$SESSION_NAME" -c "$PROJECT_DIR" \
    "MAX_PARALLEL=1 TASKS='$TASKS' bash $ORCH_RUNNER"
  sleep 25
  if tmux has-session -t "=$SESSION_NAME" 2>/dev/null; then
    log "очередь поднята ($why)"
    notify "Очередь запущена: $TASKS. Причина: $why."
  else
    log "🔴 очередь НЕ поднялась ($why)"
    notify "Очередь НЕ поднялась ($TASKS) - нужна ручная проверка."
  fi
}

log "жду свободный слот под [$TASKS] (максимум ${MAX_WAIT_MIN} мин, лимит исполнителей $MAX_EXECUTORS)"
start=$(date +%s)
while true; do
  # 🔴 НЕ возвращать к `pgrep -fc … || echo 0` (разбор 08.08.2026): при НУЛЕ процессов
  # `pgrep -c` печатает "0" И отдаёт код 1, срабатывает `|| echo 0`, и в переменной
  # оказывается "0\n0" — двустрочное значение. Арифметическое сравнение ниже падает,
  # условие «слот свободен» НИКОГДА не выполняется, и ожидатель стартует только по
  # дедлайну. С FORCE_AFTER_DEADLINE=0 он не стартует вовсе: 08.08 цепочка лояльности
  # так простояла 5 часов при полностью свободной машине.
  # 🔴 И НЕ возвращать к голому `pgrep … | wc -l` (разбор 09.08.2026, GOTCHAS #11): он считает
  # исполнителем сам процесс-оркестратор. Считать только через count_executors().
  run=$(count_executors)
  avail=$(awk '/MemAvailable/{print int($2/1024)}' /proc/meminfo)
  if [ "${run:-9}" -lt "$MAX_EXECUTORS" ] && [ "${avail:-0}" -ge "$RAM_MIN_MB" ]; then
    log "слот свободен (исполнителей=$run, RAM=${avail}Mi) — запускаю"
    launch_queue "слот свободен: исполнителей=$run, RAM=${avail}Mi"
    exit 0
  fi
  now=$(date +%s); mins=$(( (now-start)/60 ))
  if [ "$mins" -ge "$MAX_WAIT_MIN" ]; then
    # 🔴 ПРАВИЛО 2: дедлайн. Молча выйти и оставить задачу «на ручной запуск» ночью =
    # потерять окно целиком, потому что рук ночью нет.
    if [ "$FORCE_AFTER_DEADLINE" = "1" ]; then
      log "🔴 ждал ${mins} мин (лимит ${MAX_WAIT_MIN}) — стартую БЕЗУСЛОВНО: бездействие дороже"
      launch_queue "дедлайн ${MAX_WAIT_MIN} мин: слот так и не освободился, ждать дальше дороже"
      exit 0
    fi
    log "🔴 ждал ${mins} мин, слот не освободился, FORCE_AFTER_DEADLINE=0 — выхожу"
    notify "Ожидатель слота: за ${mins} мин слот не освободился. Очередь [$TASKS] не запускалась."
    exit 1
  fi
  log "занято: исполнителей=$run RAM=${avail}Mi — жду ${RECHECK}s (прошло ${mins} мин)"
  sleep "$RECHECK"
done
