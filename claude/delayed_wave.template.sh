#!/bin/bash
# delayed_wave.template.sh — ОТЛОЖЕННЫЙ запуск волны задач к заданному времени.
#
# Зачем: работы, которые прерывают живой контур (деплой, рестарт агента/киоска), нельзя пускать днём.
# Владелец называет время — таймер ждёт его сам, делает преflight и поднимает очередь. Человеку не
# нужно сидеть и ждать; при этом волна НЕ стартует вслепую, если условия плохие.
#
# Запуск (от root, в своей tmux-сессии, чтобы пережить закрытие терминала):
#   tmux new-session -d -s <имя> "WAVE_AT='19:30' WAVE_TZ='Europe/Moscow' \
#     PROJECT_DIR=/work/projecta/orch/live MAX_PARALLEL=3 \
#     TASKS='T124_x T131_y T108_z' bash /work/settings/claude/delayed_wave.template.sh"
#
# Обязательное:
#   WAVE_AT      — время старта, HH:MM
#   PROJECT_DIR  — каталог оркестратора (там tasks/ reports/ state/ logs/ и _run_orch.sh)
#   TASKS        — список задач через пробел (🔴 ВСЕГДА явный, §10.1 workflow: очередь динамическая)
# Необязательное:
#   WAVE_TZ         — часовой пояс WAVE_AT (по умолчанию Europe/Moscow — владелец называет время по МСК)
#   MAX_PARALLEL    — сколько задач разом (по умолчанию 1; ставить >1 только при РАЗНЫХ Resource-Lock)
#   MIN_RAM_MI      — гейт по памяти, Mi (по умолчанию 1500)
#   SESSION         — имя tmux-сессии очереди (по умолчанию projecta_night_orch)
#   HEALTH_URL      — URL /health живой кассы для проверки saleActive (пусто — проверка пропускается)
#   HEALTH_SSH      — хелпер ssh до этой кассы (например /work/remote_tools/projecta_ssh.sh)
#   SALE_WAIT_MIN   — сколько ждать окончания продажи, минут (по умолчанию 20)
#   STOP_FILE       — стоп-кран (по умолчанию $PROJECT_DIR/ORCH_STOP): появился файл — волна отменяется
#
# Что делает в момент X:
#   1) RAM-гейт: available < MIN_RAM_MI → волна НЕ стартует (лучше не начать, чем словить OOM);
#   2) RAM-сторож v3: жив? нет — поднимает;
#   3) каналы: пробует hostname по каждому ssh-хелперу из SSH_PROBES (через запятую, "путь|имя");
#   4) 🔴 saleActive: если на живой кассе идёт продажа — ЖДЁТ её окончания, не лезет с деплоем;
#   5) права agentuser на tasks/reports/state/logs/orch;
#   6) поднимает очередь с ЯВНЫМ TASKS и MAX_PARALLEL.
#
# Идемпотентность: маркер $PROJECT_DIR/state/.delayed_wave_started — повторный запуск таймера волну
# не задвоит. Стоп-кран проверяется в цикле ожидания: `touch $STOP_FILE` отменяет волну без следов.
set -u

WAVE_AT="${WAVE_AT:?need WAVE_AT (HH:MM)}"
PROJECT_DIR="${PROJECT_DIR:?need PROJECT_DIR}"
TASKS="${TASKS:?need TASKS (явный список, §10.1)}"
WAVE_TZ="${WAVE_TZ:-Europe/Moscow}"
MAX_PARALLEL="${MAX_PARALLEL:-1}"
MIN_RAM_MI="${MIN_RAM_MI:-1500}"
SESSION="${SESSION:-projecta_night_orch}"
HEALTH_URL="${HEALTH_URL:-}"
HEALTH_SSH="${HEALTH_SSH:-}"
SALE_WAIT_MIN="${SALE_WAIT_MIN:-20}"
SSH_PROBES="${SSH_PROBES:-}"
STOP_FILE="${STOP_FILE:-$PROJECT_DIR/ORCH_STOP}"
LOG="${LOG:-$PROJECT_DIR/logs/delayed_wave.log}"
MARKER="$PROJECT_DIR/state/.delayed_wave_started"

mkdir -p "$(dirname "$LOG")" "$PROJECT_DIR/state"
log(){ echo "[$(date '+%F %T')] $*" >> "$LOG"; }

TARGET=$(TZ="$WAVE_TZ" date -d "today $WAVE_AT" '+%s')
[ "$TARGET" -le "$(date '+%s')" ] && TARGET=$(TZ="$WAVE_TZ" date -d "tomorrow $WAVE_AT" '+%s')
log "таймер поднят: старт в $WAVE_AT $WAVE_TZ (через $(( (TARGET - $(date '+%s')) / 60 )) мин), задачи: $TASKS"

while [ "$(date '+%s')" -lt "$TARGET" ]; do
  sleep 30
  [ -f "$STOP_FILE" ] && { log "СТОП-КРАН $STOP_FILE — волна отменена"; exit 0; }
done

[ -f "$MARKER" ] && { log "маркер есть — волна уже запускалась, выхожу"; exit 0; }

log "=== время X, преflight ==="
AVAIL=$(free -m | awk 'NR==2{print $7}')
log "RAM available=${AVAIL}Mi (гейт ${MIN_RAM_MI}Mi)"
[ "$AVAIL" -lt "$MIN_RAM_MI" ] && { log "СТОП: мало памяти, волна НЕ запускается"; exit 1; }

if [ -x /work/settings/claude/ram_guard_v3.sh ]; then
  bash /work/settings/claude/ram_guard_v3.sh status >> "$LOG" 2>&1 || \
    bash /work/settings/claude/ram_guard_v3_start.sh >> "$LOG" 2>&1
fi

if [ -n "$SSH_PROBES" ]; then
  IFS=',' read -ra PR <<< "$SSH_PROBES"
  for p in "${PR[@]}"; do
    sh="${p%%|*}"; nm="${p##*|}"
    log "канал $nm: $(timeout 60 bash "$sh" 'hostname' 2>&1 | tail -1)"
  done
fi

# 🔴 не лезть с деплоем в идущую продажу
if [ -n "$HEALTH_SSH" ] && [ -n "$HEALTH_URL" ]; then
  sale_now(){ timeout 60 bash "$HEALTH_SSH" "powershell -NoProfile -Command \"(Invoke-WebRequest -UseBasicParsing -TimeoutSec 10 $HEALTH_URL).Content|ConvertFrom-Json|%{\$_.saleActive}\"" 2>&1 | tail -1 | tr -d '\r'; }
  S=$(sale_now); log "saleActive=$S"
  if [ "$S" = "True" ]; then
    log "🔴 идёт продажа — жду до ${SALE_WAIT_MIN} мин"
    for _ in $(seq 1 $((SALE_WAIT_MIN * 2))); do sleep 30; S=$(sale_now); [ "$S" != "True" ] && break; done
    log "после ожидания saleActive=$S"
  fi
fi

chown -R agentuser:agentuser "$PROJECT_DIR/tasks" "$PROJECT_DIR/reports" "$PROJECT_DIR/state" \
  "$PROJECT_DIR/logs" "$PROJECT_DIR/orch" 2>/dev/null
date '+%F %T' > "$MARKER"
log "запускаю очередь: TASKS='$TASKS' MAX_PARALLEL=$MAX_PARALLEL session=$SESSION"
runuser -u agentuser -- tmux new-session -d -s "$SESSION" -c "$PROJECT_DIR" \
  "TASKS='$TASKS' MAX_PARALLEL='$MAX_PARALLEL' bash $PROJECT_DIR/_run_orch.sh"
sleep 30
grep -E "starting|waiting" "$PROJECT_DIR/logs/claude_orchestrator.log" 2>/dev/null | tail -4 >> "$LOG"
log "=== таймер отработал ==="
