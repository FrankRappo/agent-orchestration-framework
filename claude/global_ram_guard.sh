#!/bin/bash
# ============================================================================
# УСТАРЕЛ 2026-07-29. Использовать /work/settings/claude/ram_guard_v3.sh
# (документация /work/settings/docs/RAM_GUARD.md). Оставлен только для отката.
#
# Почему: в OOM 29.07 этот сторож не смог сделать ничего — он ищет кандидатов
# только среди `ps -u agentuser` с comm=claude и cwd под /work/projecta|/work/projectb,
# codex ловит нестойкой pgrep-маской и бьёт ОДИН процесс вместо дерева.
# Память держали codex/omx под root, Chrome и claude-сессия в /work/projecte —
# ни один в список не попадал: «безопасных кандидатов на kill нет», ребут VM.
# ============================================================================
# ГЛОБАЛЬНЫЙ RAM-сторож (anti-freeze) — версия 2026-06-20, тюнинг 2026-07-15.
# 2026-07-15 (после OOM на PROJECTA T11): CRIT_KB 350→500, CRIT_TICKS_NEED 2→1, добавлен EMERGENCY hard-kill
#   (<EMERG_KB=250Mi) — т.к. kill -STOP не освобождает RSS и при резком спайке kernel OOM обгонял сторожа.
# Пишется после фриза 2026-06-20: на 6Gi WSL крутились ДВА оркестратора
# (projectb projectg + projecta T0-ADMIN) + omx (oh-my-codex) + 2 chromium-стека.
# Старый per-project ram_guard душил ТОЛЬКО projectb → projecta и omx добили RAM до
# ~113Mi → swap-thrash → вся VM колом (kernel OOM-killer под thrash не успевает).
#
# ОТЛИЧИЕ ОТ /work/settings/claude/ram_guard.template.sh:
#   тот — per-project, пауза ТОЛЬКО своих sub-агентов, чтобы отдать RAM ЧУЖОМУ
#   важному соседу (его НЕ трогаем). Здесь ВСЁ — СВОЁ (projectb + projecta + omx),
#   чужого нет → задача сторожа чисто «не дать VM замёрзнуть». Поэтому он
#   global и видит ВСЕ свои тяжёлые процессы, с приоритетами:
#     omx (Codex, без супервизора) — жертвуем ПЕРВЫМ;
#     активный sub-агент оркестратора — пауза ТОЛЬКО в аварии и НЕНАДОЛГО.
#
# Тики (один прогон = один tick, цикл — снаружи в tmux):
#   tmux new-session -d -s global_ram_guard \
#     "bash -c 'while true; do bash /work/settings/claude/global_ram_guard.sh; sleep 15; done'"
# Снять: tmux kill-session -t global_ram_guard
# Документация: HOW_TO_RUN.md §8.9.
# ============================================================================
set -u

# ====== ПОРОГИ (KB MemAvailable) ======
PAUSE_KB=700000        # < этого → пауза omx (дёшево, обратимо, без супервизора)
RESUME_KB=1100000      # > этого → всё снять с паузы (гистерезис)
CRIT_KB=500000         # 2026-07-15: 350→500. < этого + CRIT_TICKS_NEED → аварийная пауза sub-агента (раньше, чем kernel OOM)
EMERG_KB=250000        # 2026-07-15 NEW: < этого → HARD kill (-9) самого жирного БЕЗОПАСНОГО кандидата.
                       #   Зачем: kill -STOP (пауза) НЕ освобождает RSS — страницы остаются, при ~250Mi kernel OOM
                       #   всё равно бьёт кого попало и морозит VM. Освободить память можно только реальным kill.
MAX_PRIMARY_PAUSE=180  # сек: дольше держать sub-агента в паузе НЕЛЬЗЯ (иначе stall-killer супервизора)
CRIT_TICKS_NEED=1      # 2026-07-15: 2→1. действовать с первого крит-тика (спайк ~750Mi/тик обгонял 2-тик задержку → OOM 15.07)
CHAT_ID=YOUR_TELEGRAM_CHAT_ID
# ======================================

LOG=/work/settings/global_ram_guard.log
OMX_STATE=/tmp/global_ram_omx_paused        # PIDs запауженного omx
PRIM_STATE=/tmp/ram_paused                  # ФЛАГ для pause-aware супервизоров (они его проверяют!)
PRIM_PIDS=/tmp/global_ram_primary_pgids     # PGIDs запауженного агента
PRIM_TS=/tmp/global_ram_primary_ts          # когда запаузили агента
CRIT_CNT=/tmp/global_ram_crit_ticks
TG="python3 /work/tg/bot.py send $CHAT_ID"

avail=$(awk '/MemAvailable/{print $2}' /proc/meminfo)
now=$(date +%s)
logline(){ echo "[$(date '+%F %T')] avail=${avail}KB $*" >> "$LOG"; }

# --- собрать omx (oh-my-codex / Codex) node-процессы ---
omx_pids=$(pgrep -f 'oh-my-codex|dist/cli/omx|[ ]codex' 2>/dev/null | tr '\n' ' ')

# --- собрать СВОИ sub-агенты оркестраторов: claude(agentuser) с cwd под /work ---
# (orchestrator/supervisor — bash, не claude; этот сторож-процесс — bash; pgrep self-match не грозит)
prim_pgids=""
for pid in $(ps -u agentuser -o pid=,comm= 2>/dev/null | awk '$2=="claude"{print $1}'); do
  cwd=$(readlink "/proc/$pid/cwd" 2>/dev/null)
  case "$cwd" in
    /work/projecta|/work/projecta/*|/work/projectb|/work/projectb/*)
      pg=$(ps -o pgid= -p "$pid" 2>/dev/null | tr -d ' ')
      [ -n "$pg" ] && prim_pgids="$prim_pgids $pg" ;;
  esac
done
prim_pgids=$(echo $prim_pgids | tr ' ' '\n' | sort -u | tr '\n' ' ')

omx_is_paused(){ [ -f "$OMX_STATE" ]; }
prim_is_paused(){ [ -f "$PRIM_STATE" ]; }

cont_omx(){
  [ -f "$OMX_STATE" ] || return 0
  for p in $(cat "$OMX_STATE" 2>/dev/null); do kill -CONT "$p" 2>/dev/null; done
  rm -f "$OMX_STATE"; logline "→ CONT omx"
}
cont_prim(){
  [ -f "$PRIM_STATE" ] || return 0
  for g in $(cat "$PRIM_PIDS" 2>/dev/null); do kill -CONT -- -"$g" 2>/dev/null; kill -CONT "$g" 2>/dev/null; done
  rm -f "$PRIM_STATE" "$PRIM_PIDS" "$PRIM_TS"; logline "→ CONT sub-agent (resume)"
}

# ============ 1. ЗДОРОВО: avail >= RESUME_KB → снять все паузы ============
if [ "$avail" -ge "$RESUME_KB" ]; then
  prim_is_paused && cont_prim
  omx_is_paused  && cont_omx
  echo 0 > "$CRIT_CNT"
  exit 0
fi

# ============ счётчик критических тиков ============
if [ "$avail" -lt "$CRIT_KB" ]; then
  c=$(cat "$CRIT_CNT" 2>/dev/null); [ -z "$c" ] && c=0; c=$((c+1)); echo "$c" > "$CRIT_CNT"
else
  echo 0 > "$CRIT_CNT"; c=0
fi

# ============ 2. ПОД PAUSE_KB → паузим omx (первый кандидат) ============
if [ "$avail" -lt "$PAUSE_KB" ] && [ -n "$omx_pids" ] && ! omx_is_paused; then
  for p in $omx_pids; do kill -STOP "$p" 2>/dev/null; done
  echo "$omx_pids" > "$OMX_STATE"
  logline "→ STOP omx PIDs:$omx_pids (отдаю RAM оркестратору)"
fi

# ============ 2.5 EMERGENCY: avail<EMERG_KB → HARD kill самого жирного БЕЗОПАСНОГО кандидата ============
# Пауза (kill -STOP) НЕ освобождает RSS; при <EMERG_KB нужно реально освободить память, иначе kernel OOM
# заморозит VM (инцидент 15.07: 1013→259Mi за 2.5 мин, guard не успел). Кандидаты — только транзиентные
# тяжёлые: omx, chromium/chrome, agentuser-claude суб-агенты под /work/projecta|/work/projectb. НИКОГДА не бьём:
# VPN (xray/sing-box), tg-bot, session-saver, root-оркестратор, сам сторож.
if [ "$avail" -lt "$EMERG_KB" ]; then
  kill_cands="$omx_pids $(pgrep -f 'chromium|chrome' 2>/dev/null | tr '\n' ' ')"
  for pid in $(ps -u agentuser -o pid=,comm= 2>/dev/null | awk '$2=="claude"{print $1}'); do
    cwd=$(readlink "/proc/$pid/cwd" 2>/dev/null)
    case "$cwd" in
      /work/projecta|/work/projecta/*|/work/projectb|/work/projectb/*) kill_cands="$kill_cands $pid" ;;
    esac
  done
  victim=$(for p in $kill_cands; do
             r=$(awk '/^VmRSS:/{print $2}' "/proc/$p/status" 2>/dev/null)
             [ -n "$r" ] && echo "$r $p"
           done | sort -rn | head -1)
  vpid=$(echo "$victim" | awk '{print $2}')
  vrss=$(echo "$victim" | awk '{print $1}')
  if [ -n "$vpid" ]; then
    vcmd=$(ps -o comm= -p "$vpid" 2>/dev/null)
    kill -9 "$vpid" 2>/dev/null
    logline "→ EMERGENCY KILL -9 pid=$vpid ($vcmd rss=$((vrss/1024))Mi) — avail=$((avail/1024))Mi < EMERG (реально освобождаю RAM)"
    $TG "🔴 RAM-сторож: EMERGENCY (avail=$((avail/1024))Mi) — hard-kill $vcmd pid=$vpid (rss=$((vrss/1024))Mi), чтобы не заморозить VM." 2>&1 | tail -1
  else
    logline "→ EMERGENCY: avail=$((avail/1024))Mi < EMERG, но безопасных кандидатов на kill нет"
  fi
fi

# ============ 3. АВАРИЯ: avail<CRIT_KB ≥CRIT_TICKS_NEED тиков → пауза sub-агента ============
if [ "$avail" -lt "$CRIT_KB" ] && [ "$c" -ge "$CRIT_TICKS_NEED" ] && [ -n "$prim_pgids" ] && ! prim_is_paused; then
  for g in $prim_pgids; do kill -STOP -- -"$g" 2>/dev/null; done
  echo "$prim_pgids" > "$PRIM_PIDS"
  date '+%F %T' > "$PRIM_STATE"        # супервизоры видят этот файл → не считают тишину jsonl столлом
  echo "$now" > "$PRIM_TS"
  logline "→ STOP sub-agent PGIDs:$prim_pgids (АВАРИЯ ${avail}KB ${c} тиков)"
  $TG "🟡 RAM-сторож: авария (avail=$((avail/1024))Mi) — sub-агент на ПАУЗЕ ≤${MAX_PRIMARY_PAUSE}с, omx заморожен. Авто-возобновление при восстановлении." 2>&1 | tail -1
fi

# ============ 4. ОГРАНИЧЕНИЕ ПАУЗЫ АГЕНТА: не дольше MAX_PRIMARY_PAUSE / при отпускании RAM ============
if prim_is_paused; then
  ts=$(cat "$PRIM_TS" 2>/dev/null); [ -z "$ts" ] && ts="$now"
  held=$((now - ts))
  if [ "$held" -ge "$MAX_PRIMARY_PAUSE" ] || [ "$avail" -ge "$PAUSE_KB" ]; then
    cont_prim
  fi
fi

logline "tick (omx_paused=$(omx_is_paused && echo y || echo n) prim_paused=$(prim_is_paused && echo y || echo n) crit=$c)"
exit 0
