#!/bin/bash
# ============================================================================
# ОЖИДАТЕЛЬ УСЛОВИЙ → ЗАПУСК ОЧЕРЕДИ ОРКЕСТРАТОРА  (переиспользуемый шаблон)
#
# Происхождение: /work/projecta/orch/live/wait_and_launch_T194.sh, коммит d24f954 (07.08.2026).
# Обобщён в шаблон фреймворка задачей T200 — проектная специфика вынесена в переменные
# окружения, в проекте остаётся ТОЛЬКО вызов с параметрами.
#
# Что делает:
#   1) ждёт DELAY_SEC (окно, в которое трогать целевую систему нельзя);
#   2) циклом раз в RECHECK_SEC проверяет:
#        - канал до целевой машины жив                (REACH_CMD, непустой вывод = жив);
#        - на целевой машине НИКТО НЕ РАБОТАЕТ        (BUSY_CMD, печатает `CLI=<число>`);
#        - свободен слот исполнителя (их не больше MAX_EXECUTORS);
#        - хватает RAM (RAM_MIN_MB);
#   3) как только всё сошлось — поднимает очередь оркестратора и выходит.
#
# ============================================================================
# 🔴 ТРИ ПРАВИЛА, КОТОРЫЕ НЕЛЬЗЯ «УПРОСТИТЬ» ОБРАТНО
# Они выстраданы потерянной ночью 06→07.08.2026: ожидатель 34 раза подряд решил «подожду
# ещё 15 минут» и не запустил НИЧЕГО. Утром магазин открылся с тремя нерабочими кассами —
# час торговли ушёл на аварию, которую ночная волна закрыла бы в тишине.
#
#   1. НЕВОЗМОЖНОСТЬ ПРОВЕРИТЬ ≠ «УСЛОВИЕ НЕ ВЫПОЛНЕНО».
#      Пустой/нечитаемый ответ пробы — это ДЕФЕКТ ПРОБЫ, а не признак занятости.
#      Два нечитаемых замера подряд (UNREAD_LIMIT) → ЗАПУСКАЕМ, а не ждём.
#      Именно здесь была потеряна ночь: проба ломалась на вложенных кавычках через ssh
#      и всегда возвращала пустоту, а логика трактовала это как «занято».
#
#   2. ЖЁСТКИЙ ДЕДЛАЙН, ПОСЛЕ КОТОРОГО СТАРТ БЕЗУСЛОВНЫЙ.
#      Ожидание не может длиться вечно: ночное окно невозвратно, бездействие ночью
#      дороже ошибки. После DEADLINE_HHMM очередь стартует, что бы ни показали пробы.
#
#   3. ПИНГ В TELEGRAM — ЭТО ЖУРНАЛ, А НЕ ПЛАН.
#      Ночью владелец СПИТ, сообщение никто не прочитает. Никакая ветка логики не имеет
#      права заканчиваться на «отправил пинг и жду ответа». Пинг только сопровождает
#      действие, которое скрипт уже совершил сам.
#
# 🔴 Следствие для того, кто будет править этот файл: любая новая проверка обязана уметь
#    различать «условие не выполнено» и «я не смог проверить», и второе НЕ должно приводить
#    к бесконечному ожиданию.
# ============================================================================
#
# ЗАПУСК (от root, сессия под agentuser):
#   runuser -u agentuser -- tmux new-session -d -s <proj>_waiter \
#     "PROJECT_DIR=/work/<proj>/orch/live TASKS_ALL='T01 T02' \
#      REACH_CMD='bash /work/remote_tools/srv_ssh.sh hostname' \
#      bash /work/settings/claude/wait_conditions_and_launch.template.sh"
# Останов: runuser -u agentuser -- tmux kill-session -t =<proj>_waiter
#
# ---------------------------------------------------------------------------
# ПЕРЕМЕННЫЕ (все со значениями по умолчанию, кроме PROJECT_DIR/TASKS_ALL)
#   PROJECT_DIR      каталог оркестратора проекта (обязательно)
#   ORCH_RUNNER      раннер очереди           (по умолчанию $PROJECT_DIR/_run_orch.sh)
#   STATE_DIR        каталог state-файлов     (по умолчанию $PROJECT_DIR/state)
#   TASKS_ALL        полная очередь, порядок = порядок выполнения (обязательно)
#   TASKS_FALLBACK   урезанная очередь, если канал до целевой машины мёртв (пусто = не запускать)
#   SESSION_NAME     имя tmux-сессии очереди
#   DELAY_SEC        пауза до первой проверки
#   RECHECK_SEC      интервал между проверками
#   MAX_TRIES        сколько всего проверок
#   DEADLINE_HHMM    HHMM: после него старт БЕЗУСЛОВНЫЙ (см. правило 2)
#   DEADLINE_END     HHMM: конец ночного окна, дедлайн действует в [DEADLINE_HHMM, DEADLINE_END)
#   RAM_MIN_MB       минимум MemAvailable для старта
#   MAX_EXECUTORS    сколько исполнителей допустимо ОДНОВРЕМЕННО
#   EXECUTOR_PAT     pgrep-паттерн исполнителя
#   REACH_CMD        проверка «канал жив»: непустой stdout = жив. Пусто = снять REACH_CMD.
#   REACH_FAIL_LIMIT сколько подряд провалов канала → запустить TASKS_FALLBACK
#   BUSY_CMD         проверка занятости: stdout должен содержать `CLI=<число>`.
#                    Пусто = проверку занятости не делать вовсе.
#   UNREAD_LIMIT     сколько нечитаемых замеров подряд → ЗАПУСКАЕМ (см. правило 1)
#   CHOWN_PATHS      каталоги, которые вернуть agentuser перед стартом (через пробел, можно пусто)
#   LOG              журнал ожидателя
#   NOTIFY_CMD       команда TG-пинга; пусто = не слать. ЖУРНАЛ, НЕ ПЛАН (см. правило 3)
# ---------------------------------------------------------------------------
set -u

PROJECT_DIR="${PROJECT_DIR:?PROJECT_DIR обязателен}"
ORCH_RUNNER="${ORCH_RUNNER:-$PROJECT_DIR/_run_orch.sh}"
STATE_DIR="${STATE_DIR:-$PROJECT_DIR/state}"
TASKS_ALL="${TASKS_ALL:?TASKS_ALL обязателен}"
TASKS_FALLBACK="${TASKS_FALLBACK:-}"
SESSION_NAME="${SESSION_NAME:-orch_waiter_queue}"
DELAY_SEC="${DELAY_SEC:-0}"
RECHECK_SEC="${RECHECK_SEC:-900}"
MAX_TRIES="${MAX_TRIES:-40}"
DEADLINE_HHMM="${DEADLINE_HHMM:-0100}"
DEADLINE_END="${DEADLINE_END:-0600}"
RAM_MIN_MB="${RAM_MIN_MB:-1500}"
MAX_EXECUTORS="${MAX_EXECUTORS:-2}"
EXECUTOR_PAT="${EXECUTOR_PAT:-claude --dangerously}"
REACH_CMD="${REACH_CMD:-}"
REACH_FAIL_LIMIT="${REACH_FAIL_LIMIT:-2}"
BUSY_CMD="${BUSY_CMD:-}"
UNREAD_LIMIT="${UNREAD_LIMIT:-2}"
CHOWN_PATHS="${CHOWN_PATHS:-}"
LOG="${LOG:-$PROJECT_DIR/logs/waiter.log}"
NOTIFY_CMD="${NOTIFY_CMD:-}"

mkdir -p "$(dirname "$LOG")" 2>/dev/null
log(){ echo "[$(date '+%F %T')] $*" >> "$LOG"; }
notify(){ [ -n "$NOTIFY_CMD" ] && $NOTIFY_CMD "$1" >/dev/null 2>&1 || true; }

# 🔴 ВТОРОЙ ПЕРЕКОС ТОГО ЖЕ СЧЁТЧИКА (найден 09.08.2026, GOTCHAS #11).
# `pgrep -u agentuser -f "claude --dangerously"` считает исполнителем и САМ процесс-оркестратор:
# он тоже `claude --dangerously-skip-permissions`. При MAX_EXECUTORS=2 и ОДНОМ реальном
# исполнителе счётчик даёт 2, `2 < 2` ложно, «слот свободен» не наступает НИКОГДА —
# тот же симптом, что чинили 08.08, но по другой причине. Замер 09.08: шаблонная проба
# дала 4 при двух реальных исполнителях.
# 🔴 -x к pgrep НЕ добавлять: дефолтный EXECUTOR_PAT — префикс, точное совпадение не найдёт ничего.
# 🔴 PPid берём из /proc/PID/status, а НЕ полем $4 из /proc/PID/stat: если имя процесса
# содержит пробел («tmux: server»), поля stat съезжают и цепочка предков обрывается.
self_chain(){ local p=$$; while [ "$p" -gt 1 ]; do echo "$p"; p=$(awk '/^PPid:/{print $2}' /proc/$p/status 2>/dev/null); [ -n "$p" ] || break; done; }
# 🔴 ТРЕТИЙ ПЕРЕКОС ТОГО ЖЕ СЧЁТЧИКА (12.08.2026, GOTCHAS #14): `pgrep` по пользователю
# считает исполнителей ВСЕХ проектов. Идёт волна соседнего проекта — наш ожидатель видит
# «слот занят» и не стартует, хотя своя очередь пуста. EXECUTOR_SCOPE=own считает только
# своих (живые сессии из своего STATE_DIR); умолчание `all` = прежнее поведение.
# Защита от OOM не ослабляется: гейты по памяти и диску считают машину целиком.
EXECUTOR_SCOPE="${EXECUTOR_SCOPE:-all}"
count_own_executors(){
  local n=0 s sess
  for s in "$STATE_DIR"/*.session; do [ -f "$s" ] || continue
    sess=$(cat "$s" 2>/dev/null)
    [ -n "$sess" ] && tmux has-session -t "=$sess" 2>/dev/null && n=$((n+1))
  done
  echo "$n"
}
count_executors(){   # всегда одно число и код 0
  if [ "$EXECUTOR_SCOPE" = own ]; then count_own_executors; return 0; fi
  local excl; excl=$(printf '%s\n' $(self_chain) $EXCLUDE_PIDS)
  pgrep -u agentuser -f "$EXECUTOR_PAT" 2>/dev/null | grep -v -x -F "$excl" | wc -l | tr -d " "
}

launch_queue(){   # $1 — список тасков, $2 — причина
  local tasks="$1" why="$2" t p
  for p in $CHOWN_PATHS; do chown -R agentuser:agentuser "$p" 2>/dev/null; done
  for t in $tasks; do
    rm -f "$STATE_DIR/$t".lock "$STATE_DIR/$t".pid "$STATE_DIR/$t".session \
          "$STATE_DIR/$t".started "$STATE_DIR/$t".ambiguous 2>/dev/null
  done
  tmux kill-session -t "=$SESSION_NAME" 2>/dev/null
  # MAX_PARALLEL=1 — строго последовательно, порядок списка = порядок выполнения.
  tmux new-session -d -s "$SESSION_NAME" -c "$PROJECT_DIR" \
    "MAX_PARALLEL=1 TASKS='$tasks' bash $ORCH_RUNNER"
  sleep 30
  if tmux has-session -t "=$SESSION_NAME" 2>/dev/null; then
    log "очередь поднята: [$tasks] ($why)"
    notify "Очередь запущена: $tasks. Причина: $why. Порядок строго последовательный."
  else
    log "🔴 очередь НЕ поднялась: [$tasks]"
    notify "Очередь НЕ поднялась ($tasks) - нужна ручная проверка."
  fi
}

log "старт ожидателя: очередь=[$TASKS_ALL], первая проверка через ${DELAY_SEC}s, интервал ${RECHECK_SEC}s, дедлайн $DEADLINE_HHMM"
[ "$DELAY_SEC" -gt 0 ] && sleep "$DELAY_SEC"

try=0; unread=0; unreach=0
while [ "$try" -lt "$MAX_TRIES" ]; do
  try=$((try+1))
  NOWHM=$(date +%H%M); NOWHM=$((10#$NOWHM))

  # ---------- 0. ПРАВИЛО 2: жёсткий дедлайн, старт безусловный ----------
  if [ "$NOWHM" -ge "$((10#$DEADLINE_HHMM))" ] && [ "$NOWHM" -lt "$((10#$DEADLINE_END))" ]; then
    log "🔴 ДЕДЛАЙН $DEADLINE_HHMM пройден (сейчас $NOWHM) — стартуем БЕЗУСЛОВНО, ждать больше нельзя"
    launch_queue "$TASKS_ALL" "дедлайн $DEADLINE_HHMM: ночное окно уходит"
    exit 0
  fi

  # ---------- 1. канал до целевой машины жив? ----------
  HN="ПРОВЕРКА ОТКЛЮЧЕНА"
  if [ -n "$REACH_CMD" ]; then
    HN="$(eval "$REACH_CMD" 2>/dev/null | tr -d '\r' | grep -v '^$' | tail -1)"
    if [ -z "$HN" ]; then
      unreach=$((unreach+1))
      log "попытка $try: канал НЕ отвечает (${unreach}/${REACH_FAIL_LIMIT})"
      if [ "$unreach" -ge "$REACH_FAIL_LIMIT" ]; then
        if [ -n "$TASKS_FALLBACK" ]; then
          log "канал мёртв ${unreach} раз подряд → поднимаю урезанную очередь [$TASKS_FALLBACK]"
          launch_queue "$TASKS_FALLBACK" "канал до целевой машины не отвечает"
        else
          # Правило 1 в общем виде: не смогли проверить — не повод стоять всю ночь.
          log "канал мёртв ${unreach} раз подряд, TASKS_FALLBACK не задан → поднимаю полную очередь"
          launch_queue "$TASKS_ALL" "канал не отвечает, ждать дальше дороже"
        fi
        exit 0
      fi
      sleep "$RECHECK_SEC"; continue
    fi
    unreach=0
  fi

  # ---------- 2. на целевой машине кто-то работает? ----------
  if [ -n "$BUSY_CMD" ]; then
    BUSY_RAW="$(eval "$BUSY_CMD" 2>/dev/null | tr -d '\r' | grep -o 'CLI=[0-9]*' | tail -1)"
    CLI="$(echo "$BUSY_RAW" | sed -n 's/.*CLI=\([0-9]*\).*/\1/p')"
    CLI="${CLI:-нечитаемо}"

    if [ "$CLI" = "нечитаемо" ]; then
      # 🔴 ПРАВИЛО 1. Невозможность прочитать — дефект пробы, а не признак занятости.
      unread=$((unread+1))
      log "попытка $try: '$HN' отвечает, но занятость прочитать не удалось ('$BUSY_RAW') — ДЕФЕКТ ПРОБЫ (${unread}/${UNREAD_LIMIT})"
      if [ "$unread" -ge "$UNREAD_LIMIT" ]; then
        log "проба занятости не читается ${unread} раз подряд — НЕ ЖДЁМ, запускаем очередь"
        launch_queue "$TASKS_ALL" "занятость прочитать не удалось, дефект пробы — идём работать"
        exit 0
      fi
      sleep "$RECHECK_SEC"; continue
    fi
    unread=0

    if [ "$CLI" -gt 0 ]; then
      log "попытка $try: '$HN' ЗАНЯТ — клиентов: $CLI. Ждём ${RECHECK_SEC}s"
      sleep "$RECHECK_SEC"; continue
    fi
  else
    CLI="проверка отключена"
  fi

  # ---------- 3. свободен ли слот исполнителя ----------
  # 🔴 НЕ возвращать к `pgrep -fc … || echo 0` (разбор 08.08.2026): при НУЛЕ процессов
  # `pgrep -c` печатает "0" И отдаёт код 1, срабатывает `|| echo 0`, и в переменной
  # оказывается "0\n0" — двустрочное значение. Арифметическое сравнение ниже падает,
  # условие «слот свободен» НИКОГДА не выполняется, и ожидатель стартует только по
  # дедлайну. С FORCE_AFTER_DEADLINE=0 он не стартует вовсе: 08.08 цепочка лояльности
  # так простояла 5 часов при полностью свободной машине.
  # 🔴 И НЕ возвращать к голому `pgrep … | wc -l` (разбор 09.08.2026, GOTCHAS #11): он считает
  # исполнителем сам процесс-оркестратор. Считать только через count_executors().
  RUN=$(count_executors)
  if [ "${RUN:-0}" -ge "$MAX_EXECUTORS" ]; then
    log "попытка $try: уже работает исполнителей: $RUN (лимит $MAX_EXECUTORS) — ждём ${RECHECK_SEC}s"
    sleep "$RECHECK_SEC"; continue
  fi

  # ---------- 4. RAM-гейт ----------
  AVAIL_MB=$(awk '/MemAvailable/{print int($2/1024)}' /proc/meminfo)
  if [ "${AVAIL_MB:-0}" -lt "$RAM_MIN_MB" ]; then
    log "попытка $try: цель свободна, но RAM available=${AVAIL_MB}Mi < ${RAM_MIN_MB}Mi — ждём ${RECHECK_SEC}s"
    sleep "$RECHECK_SEC"; continue
  fi

  # ---------- 5. запуск ----------
  log "УСЛОВИЯ СОШЛИСЬ: '$HN', занятость=$CLI, исполнителей=$RUN, RAM=${AVAIL_MB}Mi"
  launch_queue "$TASKS_ALL" "цель свободна ('$HN'), занятость $CLI"
  exit 0
done

# 🔴 ПРАВИЛО 2 в вырожденном виде: MAX_TRIES исчерпан ВНЕ ночного окна. Пинг здесь —
# журнал того, что уже произошло; планом «жду ответа владельца» он быть не может.
log "🔴 сдаюсь после $MAX_TRIES попыток — условия так и не сошлись"
notify "Ожидатель: за отведённое время условия не сошлись. Очередь [$TASKS_ALL] не запускалась."
exit 1
