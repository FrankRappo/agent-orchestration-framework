#!/bin/bash
# ============================================================================
# RAM-СТОРОЖ v3 (machine-wide, WSL 6Gi) — 2026-07-29
#
# Почему v3 (разбор OOM 2026-07-29 07:49-08:01):
#   v2 (global_ram_guard.sh) видел ТОЛЬКО claude пользователя agentuser с cwd под
#   /work/projecta|/work/projectb, а omx/codex ловил шаткой маской pgrep.
#   В инциденте память держали: codex/omx под ROOT, Chrome с вкладками claude.ai,
#   claude-сессия agentuser в /work/projecte и интерактивные сессии под root —
#   НИ ОДИН из них в список кандидатов не попадал. Лог v2 честно писал
#   "STOP sub-agent PGIDs:" (пустой список) и четыре тика подряд
#   "безопасных кандидатов на kill нет", пока avail сползал 907Mi -> 106Mi,
#   после чего VM пришлось перезагружать. Плюс после ребута не осталось
#   НИКАКИХ следов, кто именно съел память.
#
# Что изменено:
#   1. Видит ВСЕ процессы всех пользователей, а не только agentuser/два каталога.
#   2. Считает RSS ДЕРЕВА процессов (Chrome/claude/codex = десятки процессов),
#      бьёт корень дерева, а не 20-мегабайтный хелпер.
#   3. Пишет снапшот топ-потребителей в отдельный лог -> после любого фриза
#      видно, кто виноват.
#   4. Явный protect-лист (VPN, tg-бот, saver, сам сторож, cron, sshd) и файл
#      ram_guard_protect_pids для «не трогать эту сессию».
#   5. Состояние в /run (tmpfs, чистится ребутом) -> протухших файлов нет.
#   6. Демон с собственным циклом: не зависит от tmux, поднимается из cron,
#      из /etc/profile.d и из [boot] в /etc/wsl.conf.
#
# Режимы:
#   ram_guard_v3.sh loop     — демон (по умолчанию через ram_guard_v3_start.sh)
#   ram_guard_v3.sh once     — один тик (для отладки)
#   ram_guard_v3.sh status   — состояние сторожа + топ потребителей
#   ram_guard_v3.sh top      — только топ потребителей
#   ram_guard_v3.sh stop     — остановить демон
#
# Документация: /work/settings/docs/RAM_GUARD.md
# ============================================================================
set -u

CONF=/work/settings/claude/ram_guard_v3.conf
[ -r "$CONF" ] && . "$CONF"

# ---------- пороги (KB MemAvailable) ----------
: "${SOFT_KB:=1400000}"    # ниже -> пауза codex/omx + снапшоты топа
: "${CRIT_KB:=800000}"     # ниже -> пауза batch-агентов claude (обратимо)
: "${EMERG_KB:=450000}"    # ниже -> реальный kill дерева по приоритету
: "${RESUME_KB:=1800000}"  # выше -> снять все паузы (гистерезис)
: "${INTERVAL:=10}"        # секунд между тиками
: "${MAX_PAUSE:=180}"      # дольше держать агента в SIGSTOP нельзя (stall-killer супервизора)
: "${MIN_KILL_KB:=120000}" # не убивать дерево легче этого (нет смысла)
: "${MIN_KILL_TTY_KB:=350000}"  # порог для интерактивной claude-сессии (последняя очередь)
: "${PSI_THRASH:=25}"      # some avg10 выше -> считаем thrash, эскалация на шаг раньше
: "${TG_CHAT:=YOUR_TELEGRAM_CHAT_ID}"
: "${TG_MIN_GAP:=300}"     # сек между TG-сообщениями одного уровня

LOG=${LOG:-/work/settings/claude/ram_guard_v3.log}
TOPLOG=${TOPLOG:-/work/settings/claude/ram_guard_top.log}
MAXLOG=${MAXLOG:-5242880}
STATE=${STATE:-/run/ram_guard_v3}
PIDFILE=$STATE/daemon.pid
PROTECT_FILE=${PROTECT_FILE:-/work/settings/claude/ram_guard_protect_pids}
COMPAT_FLAG=/tmp/ram_paused          # его читают супервизоры (HOW_TO_RUN 8.9.1) — сохраняем
TG=${TG:-/work/tg/bot.py}

# процессы, которые НЕ трогаем никогда (ни STOP, ни KILL)
: "${PROTECT_RE:=xray|sing-box|sshd|/usr/sbin/cron|systemd|/sbin/init|dbus|agetty|bot\.py|claude_saver|ram_guard|rustdesk|Xvfb|x11vnc|tmux: server|wslservice|docker}"

mkdir -p "$STATE" 2>/dev/null

now(){ date +%s; }
stamp(){ date '+%F %T'; }
rotate(){ local f=$1; [ -f "$f" ] || return 0; local s; s=$(stat -c%s "$f" 2>/dev/null||echo 0); [ "$s" -gt "$MAXLOG" ] && mv -f "$f" "$f.1"; }
say(){ rotate "$LOG"; echo "[$(stamp)] $*" >> "$LOG"; }
toplog(){ rotate "$TOPLOG"; echo "$*" >> "$TOPLOG"; }

tg(){ # tg <level> <text> — с рейт-лимитом по уровню
  local lvl=$1; shift
  local f=$STATE/tg_$lvl last=0 n; n=$(now)
  [ -f "$f" ] && last=$(cat "$f" 2>/dev/null || echo 0)
  [ $((n-last)) -lt "$TG_MIN_GAP" ] && return 0
  echo "$n" > "$f"
  [ -x "$TG" ] || [ -f "$TG" ] || return 0
  python3 "$TG" send "$TG_CHAT" "$*" >/dev/null 2>&1 &
}

# ---------------------------------------------------------------- снимок ps
declare -A P_PPID P_PGID P_USER P_RSS P_TTY P_COMM P_ARGS P_KIDS TREE SELF_ANC CLASS HAS_SPECIAL
ALLPIDS=()
snapshot(){
  P_PPID=(); P_PGID=(); P_USER=(); P_RSS=(); P_TTY=(); P_COMM=(); P_ARGS=(); P_KIDS=(); TREE=(); SELF_ANC=(); CLASS=(); HAS_SPECIAL=(); ALLPIDS=()
  local pid ppid pgid user rss tty comm args
  while read -r pid ppid pgid user rss tty comm args; do
    [ -z "${pid:-}" ] && continue
    P_PPID[$pid]=$ppid; P_PGID[$pid]=$pgid; P_USER[$pid]=$user
    P_RSS[$pid]=$rss;   P_TTY[$pid]=$tty;   P_COMM[$pid]=$comm
    P_ARGS[$pid]=${args:-}
    P_KIDS[$ppid]="${P_KIDS[$ppid]:-} $pid"
    ALLPIDS+=("$pid")
  done < <(ps -eo pid=,ppid=,pgid=,user=,rss=,tty=,comm=,args= 2>/dev/null)

  # RSS деревьев одним проходом: каждый процесс добавляет свой RSS всем предкам.
  # (без рекурсии в subshell — иначе мемоизация теряется и тик становится дорогим)
  local p d
  for pid in "${ALLPIDS[@]}"; do TREE[$pid]=${P_RSS[$pid]:-0}; done
  for pid in "${ALLPIDS[@]}"; do
    p=${P_PPID[$pid]:-0}; d=0
    while [ "${p:-0}" -gt 1 ] 2>/dev/null && [ -n "${P_COMM[$p]:-}" ] && [ "$d" -lt 24 ]; do
      TREE[$p]=$(( ${TREE[$p]:-0} + ${P_RSS[$pid]:-0} ))
      p=${P_PPID[$p]:-0}; d=$((d+1))
    done
  done

  # классы считаем ОДИН раз за тик (class_of через $(...) на каждый pid = сотни subshell)
  for pid in "${ALLPIDS[@]}"; do CLASS[$pid]=$(_class_compute "$pid"); done

  # HAS_SPECIAL: в поддереве есть процесс осмысленного класса (chrome/codex/claude).
  # Нужно, чтобы обёртка-bash не считалась самостоятельной жертвой класса other:
  # убив её, мы бы прибили дерево claude-сессии в обход приоритетов.
  for pid in "${ALLPIDS[@]}"; do
    case "${CLASS[$pid]}" in other|system) continue;; esac
    p=${P_PPID[$pid]:-0}; d=0
    while [ "${p:-0}" -gt 1 ] 2>/dev/null && [ -n "${P_COMM[$p]:-}" ] && [ "$d" -lt 24 ]; do
      HAS_SPECIAL[$p]=1; p=${P_PPID[$p]:-0}; d=$((d+1))
    done
  done

  # предки самого сторожа — трогать нельзя
  p=$$; d=0
  while [ "${p:-0}" -gt 1 ] 2>/dev/null && [ "$d" -lt 24 ]; do
    SELF_ANC[$p]=1; p=${P_PPID[$p]:-0}; d=$((d+1))
  done
}

tree_rss(){ echo "${TREE[$1]:-0}"; }

protected(){ # protected <pid>
  local pid=$1 line
  [ "$pid" -le 2 ] 2>/dev/null && return 0
  [ -n "${SELF_ANC[$pid]:-}" ] && return 0
  printf '%s %s' "${P_COMM[$pid]:-}" "${P_ARGS[$pid]:-}" | grep -qiE "$PROTECT_RE" && return 0
  if [ -r "$PROTECT_FILE" ]; then
    while read -r line; do
      line=${line%%#*}; line=$(echo "$line" | tr -d ' ')
      [ -z "$line" ] && continue
      [ "$line" = "$pid" ] && return 0
    done < "$PROTECT_FILE"
  fi
  return 1
}

_class_compute(){ # вычисление класса: system|codex|chrome|claude_batch|claude_tty|other
  local pid=$1
  local c=${P_COMM[$pid]:-}
  local a=${P_ARGS[$pid]:-}
  # init, kthreadd и служебные процессы WSL (SessionLeader/Relay/plan9) — класс system.
  # Иначе всё дерево машины схлопывается в один SessionLeader и жертвой становится
  # ЦЕЛАЯ WSL-сессия вместо конкретного Chrome/codex/claude.
  [ "$pid" -le 2 ] 2>/dev/null && { echo system; return; }
  case "$c" in SessionLeader*|Relay*|init*|plan9*|wsl*) echo system; return;; esac
  case "$c" in
    codex|omx) echo codex; return;;
    chrome|chromium|chromium-browse|chrome_crashpad) echo chrome; return;;
    claude) [ "${P_TTY[$pid]:-?}" = "?" ] && echo claude_batch || echo claude_tty; return;;
  esac
  # маски по cmdline — НАМЕРЕННО узкие: широкая маска (*/codex*) цепляет любую
  # чужую команду, где в аргументах встретился путь /root/.codex
  case "$a" in
    *oh-my-codex*|*dist/cli/omx*|*/bin/codex*|*/bin/omx*) echo codex; return;;
    *google-chrome*|*chromium*) echo chrome; return;;
  esac
  echo other
}

class_of(){ echo "${CLASS[$1]:-other}"; }

is_root_of_class(){ # корень дерева своего класса (у родителя класс другой)
  local pid=$1 cls=$2
  local par=${P_PPID[$pid]:-1}
  [ -z "${P_COMM[$par]:-}" ] && return 0
  [ "${CLASS[$par]:-other}" = "$cls" ] && return 1
  # обёртка вокруг чужого специализированного дерева самостоятельной жертвой не считается
  [ "$cls" = other ] && [ -n "${HAS_SPECIAL[$pid]:-}" ] && return 1
  return 0
}

# roots_of <class> -> строки "treeRSS pid comm"
roots_of(){
  local want=$1 pid cls
  for pid in "${ALLPIDS[@]}"; do
    [ -z "${P_COMM[$pid]:-}" ] && continue
    cls=${CLASS[$pid]:-other}
    [ "$cls" = "$want" ] || continue
    is_root_of_class "$pid" "$cls" || continue
    protected "$pid" && continue
    echo "$(tree_rss "$pid") $pid ${P_COMM[$pid]}"
  done | sort -rn
}

top_snapshot(){ # топ-8 деревьев по RSS в отдельный лог (посмертная улика)
  local n avail=$1 state=$2 line
  toplog "=== $(stamp) avail=$((avail/1024))Mi state=$state ==="
  {
    local pid cls
    for pid in "${ALLPIDS[@]}"; do
      [ -z "${P_COMM[$pid]:-}" ] && continue
      cls=${CLASS[$pid]:-other}
      [ "$cls" = system ] && continue
      is_root_of_class "$pid" "$cls" || continue
      echo "$(tree_rss "$pid") $pid $cls ${P_USER[$pid]:-?} ${P_COMM[$pid]}"
    done | sort -rn | head -8
  } | while read -r rss pid cls user comm; do
      toplog "    $((rss/1024))Mi  pid=$pid  $cls  $user  $comm"
    done
}

# ------------------------------------------------------------- пауза/резюм
pause_tree(){ # pause_tree <pid> <class>
  local pid=$1 cls=$2
  local pg=${P_PGID[$pid]:-}
  [ -n "$pg" ] && kill -STOP -- -"$pg" 2>/dev/null
  kill -STOP "$pid" 2>/dev/null
  echo "$pid ${P_COMM[$pid]:-?} $pg $(now)" >> "$STATE/paused_$cls"
}
resume_class(){ # resume_class <class>
  local f=$STATE/paused_$1 pid comm pg ts
  [ -f "$f" ] || return 0
  while read -r pid comm pg ts; do
    [ -z "${pid:-}" ] && continue
    # проверка личности: PID мог быть переиспользован
    local cur; cur=$(ps -o comm= -p "$pid" 2>/dev/null | tr -d ' ')
    [ -n "$cur" ] && [ "$cur" != "$comm" ] && continue
    [ -n "${pg:-}" ] && kill -CONT -- -"$pg" 2>/dev/null
    kill -CONT "$pid" 2>/dev/null
  done < "$f"
  rm -f "$f"
  say "CONT $1 (снял паузу)"
}
paused(){ [ -s "$STATE/paused_$1" ]; }

kill_tree(){ # kill_tree <pid> — сначала потомки, потом корень
  local pid=$1 k
  for k in ${P_KIDS[$pid]:-}; do kill_tree "$k"; done
  kill -9 "$pid" 2>/dev/null
}

emergency_kill(){ # одна жертва за тик, по приоритету классов
  local avail=$1 cls line rss pid comm minkb
  # АБСОЛЮТНЫЙ предохранитель: что бы ни стояло в конфиге и что бы ни насчитала
  # эскалация по PSI — при реально свободной памяти НИКОГО не убиваем.
  # (29.07 тестовый конфиг с "всегда EMERG" снёс живой Chrome при 4.6 Gi свободных.)
  local real; real=$(awk '/MemAvailable/{print $2}' /proc/meminfo)
  if [ "${real:-0}" -gt "${HARD_SANITY_KB:-2000000}" ]; then
    say "EMERGENCY отменён предохранителем: реально свободно $((real/1024))Mi (> $(( ${HARD_SANITY_KB:-2000000} /1024))Mi)"
    return 1
  fi
  for cls in codex chrome claude_batch other claude_tty; do
    minkb=$MIN_KILL_KB
    [ "$cls" = claude_tty ] && minkb=$MIN_KILL_TTY_KB
    [ "$cls" = other ] && minkb=$((MIN_KILL_KB*2))
    line=$(roots_of "$cls" | head -1)
    [ -z "$line" ] && continue
    rss=$(echo "$line" | awk '{print $1}')
    pid=$(echo "$line" | awk '{print $2}')
    comm=$(echo "$line" | awk '{print $3}')
    [ "$rss" -lt "$minkb" ] && continue
    kill_tree "$pid"
    say "EMERGENCY KILL дерево pid=$pid ($cls $comm rss=$((rss/1024))Mi) — avail=$((avail/1024))Mi"
    tg emerg "RAM-сторож: EMERGENCY avail=$((avail/1024))Mi — убито дерево $cls ($comm, pid=$pid, $((rss/1024))Mi). Подробности: /work/settings/claude/ram_guard_top.log"
    return 0
  done
  say "EMERGENCY: avail=$((avail/1024))Mi, но кандидатов выше порога нет (см. ram_guard_top.log)"
  tg emerg "RAM-сторож: EMERGENCY avail=$((avail/1024))Mi и НЕТ кандидатов на kill. Смотри /work/settings/claude/ram_guard_top.log"
  return 1
}

psi10(){ awk '/^some/{split($2,a,"="); printf "%.0f", a[2]; exit}' /proc/pressure/memory 2>/dev/null || echo 0; }

tick(){
  local avail swapfree psi state n
  avail=$(awk '/MemAvailable/{print $2}' /proc/meminfo)
  swapfree=$(awk '/SwapFree/{print $2}' /proc/meminfo)
  psi=$(psi10); [ -z "$psi" ] && psi=0
  n=$(now)
  snapshot

  # thrash-эскалация: сильное давление памяти = считаем на ступень хуже
  local eff=$avail
  [ "$psi" -ge "$PSI_THRASH" ] && eff=$((avail*2/3))

  if   [ "$eff" -lt "$EMERG_KB" ]; then state=EMERG
  elif [ "$eff" -lt "$CRIT_KB"  ]; then state=CRIT
  elif [ "$eff" -lt "$SOFT_KB"  ]; then state=SOFT
  else state=OK; fi

  # ---- OK: снять все паузы (гистерезис по RESUME_KB) ----
  if [ "$avail" -ge "$RESUME_KB" ]; then
    paused codex        && resume_class codex
    paused claude_batch && { resume_class claude_batch; rm -f "$COMPAT_FLAG"; }
  fi

  # ---- SOFT: морозим codex/omx (дёшево, обратимо, без супервизора) ----
  if [ "$state" != OK ] && ! paused codex; then
    local line pid
    while read -r line; do
      [ -z "$line" ] && continue
      pid=$(echo "$line" | awk '{print $2}')
      pause_tree "$pid" codex
    done < <(roots_of codex)
    if paused codex; then
      say "STOP codex/omx ($(wc -l < "$STATE/paused_codex") дерев) — avail=$((avail/1024))Mi state=$state"
    fi
  fi

  # ---- CRIT: пауза batch-агентов claude (любой пользователь, любой cwd) ----
  if { [ "$state" = CRIT ] || [ "$state" = EMERG ]; } && ! paused claude_batch; then
    local line pid
    while read -r line; do
      [ -z "$line" ] && continue
      pid=$(echo "$line" | awk '{print $2}')
      pause_tree "$pid" claude_batch
    done < <(roots_of claude_batch)
    if paused claude_batch; then
      date '+%F %T' > "$COMPAT_FLAG"   # супервизоры не считают тишину jsonl столлом
      say "STOP claude batch-агентов ($(wc -l < "$STATE/paused_claude_batch")) — avail=$((avail/1024))Mi"
      tg crit "RAM-сторож: avail=$((avail/1024))Mi — batch-агенты claude на паузе до ${MAX_PAUSE}с, codex заморожен."
    fi
  fi

  # ---- EMERG: реальный kill (пауза RSS не освобождает) ----
  [ "$state" = EMERG ] && emergency_kill "$avail"

  # ---- лимит паузы агентов: не дольше MAX_PAUSE (иначе stall-killer супервизора) ----
  if paused claude_batch; then
    local oldest; oldest=$(awk '{print $4}' "$STATE/paused_claude_batch" | sort -n | head -1)
    [ -z "$oldest" ] && oldest=$n
    if [ $((n-oldest)) -ge "$MAX_PAUSE" ] || [ "$avail" -ge "$RESUME_KB" ]; then
      resume_class claude_batch; rm -f "$COMPAT_FLAG"
    fi
  fi

  # ---- логи ----
  local lastsnap=0 snapf=$STATE/last_snap
  [ -f "$snapf" ] && lastsnap=$(cat "$snapf" 2>/dev/null || echo 0)
  if [ "$state" != OK ]; then
    say "avail=$((avail/1024))Mi swapfree=$((swapfree/1024))Mi psi10=$psi state=$state codex_paused=$(paused codex && echo y || echo n) agents_paused=$(paused claude_batch && echo y || echo n)"
    if [ $((n-lastsnap)) -ge 30 ]; then top_snapshot "$avail" "$state"; echo "$n" > "$snapf"; fi
  elif [ $((n-lastsnap)) -ge 600 ]; then
    top_snapshot "$avail" OK; echo "$n" > "$snapf"
  fi
}

case "${1:-loop}" in
  once) tick ;;
  loop)
    echo $$ > "$PIDFILE"
    say "старт демона pid=$$ (SOFT=$((SOFT_KB/1024))Mi CRIT=$((CRIT_KB/1024))Mi EMERG=$((EMERG_KB/1024))Mi RESUME=$((RESUME_KB/1024))Mi interval=${INTERVAL}s)"
    trap 'say "демон остановлен (signal)"; rm -f "$PIDFILE"; exit 0' TERM INT
    while true; do tick; sleep "$INTERVAL"; done
    ;;
  status)
    if [ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null; then
      echo "демон: ЖИВ pid=$(cat "$PIDFILE")"
    else
      echo "демон: НЕ ЗАПУЩЕН (поднять: bash /work/settings/claude/ram_guard_v3_start.sh)"
    fi
    awk '/MemAvailable|SwapFree/{printf "%s %d Mi\n", $1, $2/1024}' /proc/meminfo
    echo "psi some avg10: $(psi10)"
    for c in codex claude_batch; do paused "$c" && echo "на паузе: $c -> $(cat "$STATE/paused_$c")"; done
    snapshot; top_snapshot "$(awk '/MemAvailable/{print $2}' /proc/meminfo)" STATUS
    tail -12 "$TOPLOG"
    ;;
  top)
    snapshot; top_snapshot "$(awk '/MemAvailable/{print $2}' /proc/meminfo)" MANUAL; tail -10 "$TOPLOG"
    ;;
  dry) # что сторож ВЫБРАЛ БЫ в аварии — без единого сигнала процессам
    snapshot
    echo "порядок жертв (берётся первый подходящий сверху вниз):"
    for c in codex chrome claude_batch other claude_tty; do
      minkb=$MIN_KILL_KB
      [ "$c" = claude_tty ] && minkb=$MIN_KILL_TTY_KB
      [ "$c" = other ] && minkb=$((MIN_KILL_KB*2))
      line=$(roots_of "$c" | head -1)
      if [ -z "$line" ]; then
        echo "  $c: кандидатов нет"
      else
        rss=$(echo "$line" | awk '{print $1}'); pid=$(echo "$line" | awk '{print $2}'); comm=$(echo "$line" | awk '{print $3}')
        if [ "$rss" -ge "$minkb" ]; then
          echo "  $c: ВЫБРАН pid=$pid $comm $((rss/1024))Mi (порог $((minkb/1024))Mi)"
        else
          echo "  $c: pid=$pid $comm $((rss/1024))Mi — ниже порога $((minkb/1024))Mi, пропуск"
        fi
      fi
    done
    ;;
  stop)
    [ -f "$PIDFILE" ] && kill -TERM "$(cat "$PIDFILE")" 2>/dev/null && echo "остановлен" || echo "не запущен"
    ;;
  *) echo "usage: $0 [loop|once|status|top|dry|stop]"; exit 2 ;;
esac
