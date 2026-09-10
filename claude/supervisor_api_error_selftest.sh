#!/bin/bash
# ============================================================================
# supervisor_api_error_selftest.sh — харнесс детектора «агент стоит на ошибке связи» (T263).
#
# Зачем: правка идёт в claude_supervisor.template.sh, по которому прямо сейчас работают ВСЕ
# очереди. Регресс здесь важнее самой правки, поэтому проверяем не «должно работать», а фактом:
#   A. КЛАССИФИКАТОР на образцах панели (пять случаев из таск-файла T263 + реальные строки логов).
#   B. НОЧНОЕ ОКНО (пинги ночью не шлём) — арифметика окна, включая переход через полночь.
#   C. ЦЕЛЬ tmux: доказать, что "=имя" для таргета ПАНЕЛИ не работает, а "=имя:" работает.
#   D. ИНТЕГРАЦИЯ: настоящий супервизор + подставная «панель агента» в tmux + подставной jsonl.
#      Именно здесь видно, что побудка ДОХОДИТ, попытки ограничены, а без ошибок ничего не изменилось.
#   E. РЕГРЕСС old-vs-new: структурный diff (что именно заменено) + поведение общих функций.
#
# Запуск:  bash /work/settings/claude/supervisor_api_error_selftest.sh
# Env:     SUP=<новый шаблон>  OLD=<старый шаблон для части E>  PARTS=ABCDE
# Ничего боевого не трогает: свои tmux-сессии с префиPROJECTAм t263rig_, свой временный каталог.
# ============================================================================
set -u
SUP="${SUP:-/work/settings/claude/claude_supervisor.template.sh}"
OLD="${OLD:-}"
FX="${FX:-/work/settings/claude/selftest_panes}"
PARTS="${PARTS:-ABCDE}"
WORK="$(mktemp -d /tmp/t263_selftest_XXXXXX)"
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); printf '  ok   %s\n' "$*"; }
bad(){ FAIL=$((FAIL+1)); printf '  FAIL %s\n' "$*"; }
chk(){ # chk <что> <ожидали> <получили>
  if [ "$2" = "$3" ]; then ok "$1 → $3"; else bad "$1 → ожидали «$2», получили «$3»"; fi; }
hdr(){ printf '\n== %s\n' "$*"; }
# 🔴 Уборка обязана снимать И tmux-сессии, И сами процессы супервизоров, которые харнесс поднял.
# 15.08: прерванный прогон оставил живых супервизоров, они продолжали работать по ТЕМ ЖЕ именам
# сессий и полезли в стенды следующего прогона — «побудка» прилетала в чужой стенд. Поэтому:
# имена сессий уникальны на прогон (RID), а PID'ы своих супервизоров пишем в файл и добиваем.
RID="$$"
SUPPIDS="$WORK/sup_pids"; : > "$SUPPIDS"
cleanup(){
  local pid s
  if [ -f "$SUPPIDS" ]; then
    while IFS= read -r pid; do [ -n "$pid" ] || continue; pkill -P "$pid" 2>/dev/null; kill "$pid" 2>/dev/null; done < "$SUPPIDS"
  fi
  for f in "$WORK"/*/state/rig.pid; do [ -f "$f" ] && kill "$(cat "$f" 2>/dev/null)" 2>/dev/null; done
  for s in $(tmux ls -F '#{session_name}' 2>/dev/null | grep "^t263rig_"); do tmux kill-session -t "=$s" 2>/dev/null; done
}
trap cleanup EXIT
# подчистить хвосты прошлых прогонов: эти сессии создаёт ТОЛЬКО этот харнесс
for s in $(tmux ls -F '#{session_name}' 2>/dev/null | grep "^t263rig_"); do tmux kill-session -t "=$s" 2>/dev/null; done

# --- общий приём: взять из шаблона ТОЛЬКО определения функций, без запуска агента -------------
# Режем по маркеру инициализации главного цикла и убираем перехват stdout, чтобы вывод харнесса
# не уехал в лог супервизора. Один и тот же приём для старого и нового файла — сравнение честное.
funcs_of(){
  local src out
  src="$1"; out="$2"
  grep -Fv 'exec >> "$SUPLOG" 2>&1' "$src" | sed -n '1,/^respawns=0; LAUNCH_TS=0/p' > "$out"
}
rig_env(){   # общий минимум env для источаемого шаблона
  export TASK="T263SELFTEST" PROJECT_DIR="$WORK/proj" TASK_FILE="$WORK/task.md" \
         REPORT="$WORK/proj/reports/report_T263SELFTEST.md" LOG_DIR="$WORK/proj/logs" \
         STATE_DIR="$WORK/proj/state" PANE_SESSION="t263rig_none" NOTIFY_CMD=""
  mkdir -p "$WORK/proj/reports" "$WORK/proj/logs" "$WORK/proj/state"; : > "$WORK/task.md"
}

printf 'T263 selftest: SUP=%s\n            WORK=%s\n' "$SUP" "$WORK"

# ============================================================================
# A. Классификатор на образцах панели
# ============================================================================
case "$PARTS" in *A*)
hdr "A. классификатор панели (два признака: строка в панели + тишина транскрипта)"
rig_env
funcs_of "$SUP" "$WORK/newfuncs.sh"
# shellcheck disable=SC1090
. "$WORK/newfuncs.sh"
cls(){ classify_pane "$2" < "$FX/$1"; }

# 🔴 пять случаев из §3 таск-файла
chk "панель «API Error … ENOTIMP» + тишина 200с (должна быть СРАБОТКА)" API_ERROR "$(cls pane_api_enotimp.txt 200)"
chk "та же панель + тишина 30с (агент мог только что упасть и сам повторить)" NONE "$(cls pane_api_enotimp.txt 30)"
chk "обычный вывод агента со словом error + тишина 200с" NONE "$(cls pane_agent_own_errors.txt 200)"
chk "панель с текстом лимита сессии + тишина 200с (ветка RATE-LIMIT, не API)" RATE_LIMIT "$(cls pane_rate_limit.txt 200)"
chk "пустая панель + тишина 200с (прежняя логика STALL)" NONE "$(cls pane_empty.txt 200)"
# дополнительно — по реальным строкам из логов проекта и по краю окна
chk "реальный кадр РАБОТАЮЩЕГО агента (снят с живой панели T259) + тишина 200с" NONE "$(cls pane_working_agent.txt 200)"
chk "«API Error: 529 Overloaded» (ZF-PAY/ZFISCAL) + тишина 200с" API_ERROR "$(cls pane_api_529.txt 200)"
chk "лимит сессии, в панели ЕЩЁ И строка API Error (приоритет RATE-LIMIT)" RATE_LIMIT "$(cls pane_rate_limit_with_api.txt 200)"
chk "граница окна: тишина ровно API_ERROR_QUIET (180с)" API_ERROR "$(cls pane_api_enotimp.txt 180)"
chk "граница окна: тишина 179с — ещё рано" NONE "$(cls pane_api_enotimp.txt 179)"
chk "пустая панель + тишина 0с" NONE "$(cls pane_empty.txt 0)"
;; esac

# ============================================================================
# B. Ночное окно: пинг ночью не уходит, причина остаётся в логе
# ============================================================================
case "$PARTS" in *B*)
hdr "B. ночное окно (владелец спит — ошибка связи в лог, а не в Telegram)"
H="$(TZ="$API_ERROR_NIGHT_TZ" date +%H)"; H="${H#0}"; [ -n "$H" ] || H=0
nightq(){ ( API_ERROR_NIGHT_FROM="$1" API_ERROR_NIGHT_TO="$2"; api_night_now && echo NIGHT || echo DAY ); }
chk "текущий час МСК ($H) внутри окна [$H,$(( (H+1)%24 ))) " NIGHT "$(nightq "$H" "$(( (H+1)%24 ))")"
chk "текущий час МСК ($H) вне окна [$(( (H+1)%24 )),$(( (H+2)%24 ))) " DAY "$(nightq "$(( (H+1)%24 ))" "$(( (H+2)%24 ))")"
chk "переход через полночь: окно [$H, $H) пустое — тишины нет" DAY "$(nightq "$H" "$H")"
chk "переход через полночь: окно [$(( (H+23)%24 )), $(( (H+1)%24 ))) накрывает текущий час" NIGHT "$(nightq "$(( (H+23)%24 ))" "$(( (H+1)%24 ))")"
# сам гейт пинга: notify_daytime ночью обязан МОЛЧАТЬ, а причину писать в лог
NOTIFY_LOG="$WORK/notify.log"; : > "$NOTIFY_LOG"
export NOTIFY_CMD="$WORK/fake_notify.sh"
cat > "$NOTIFY_CMD" <<EOF
#!/bin/bash
echo "\$*" >> "$NOTIFY_LOG"
EOF
chmod +x "$NOTIFY_CMD"
( API_ERROR_NIGHT_FROM="$H" API_ERROR_NIGHT_TO="$(( (H+1)%24 ))"; notify_daytime "НОЧНОЙ ПИНГ" >/dev/null )
chk "ночью notify не вызван" 0 "$(grep -c 'НОЧНОЙ ПИНГ' "$NOTIFY_LOG")"
( API_ERROR_NIGHT_FROM="$(( (H+1)%24 ))" API_ERROR_NIGHT_TO="$(( (H+2)%24 ))"; notify_daytime "ДНЕВНОЙ ПИНГ" >/dev/null )
chk "днём notify вызван" 1 "$(grep -c 'ДНЕВНОЙ ПИНГ' "$NOTIFY_LOG")"
export NOTIFY_CMD=""
;; esac

# ============================================================================
# C. Цель tmux: "=имя" против "=имя:" — почему пришлось чинить pane_tail
# ============================================================================
case "$PARTS" in *C*)
hdr "C. таргет панели tmux ($(tmux -V))"
tmux kill-session -t "=t263rig_${RID}_target" 2>/dev/null
tmux new-session -d -s "t263rig_${RID}_target" "printf 'MARKER_IN_PANE\n'; exec cat"; sleep 1
chk "capture-pane -t '=имя'  (сломанная форма) → пусто" "0" "$(tmux capture-pane -p -t "=t263rig_${RID}_target" 2>/dev/null | grep -c MARKER_IN_PANE)"
chk "capture-pane -t '=имя:' (рабочая форма)  → видит панель" "1" "$(tmux capture-pane -p -t "=t263rig_${RID}_target:" 2>/dev/null | grep -c MARKER_IN_PANE)"
tmux send-keys -t "=t263rig_${RID}_target" "SENT_EQ" Enter 2>/dev/null; rc_eq=$?
tmux send-keys -t "=t263rig_${RID}_target:" "SENT_EQCOLON" Enter 2>/dev/null; rc_col=$?
chk "send-keys -t '=имя'  → ненулевой код (не доставлено)" "1" "$rc_eq"
chk "send-keys -t '=имя:' → код 0" "0" "$rc_col"
sleep 1
# (в панели строка видна дважды: эхо ввода и вывод самого `cat` — считаем «есть/нет», а не сколько)
chk "в панели есть только доставленное рабочей формой" "1" \
    "$( [ "$(tmux capture-pane -p -t "=t263rig_${RID}_target:" | grep -ca SENT_EQCOLON)" -ge 1 ] && echo 1 || echo 0)"
chk "текст сломанной формы в панель не попал" "0" "$(tmux capture-pane -p -t "=t263rig_${RID}_target:" | grep -c SENT_EQ$)"
tmux kill-session -t "=t263rig_${RID}_target" 2>/dev/null
;; esac

# ============================================================================
# D. Интеграция: настоящий супервизор на подставном стенде
# ============================================================================
case "$PARTS" in *D*)
hdr "D. интеграция — настоящий супервизор, подставная панель и подставной jsonl"
# Подставной лончер: поднимает «панель агента» с образцом текста, кладёт живой PID и свежий jsonl.
cat > "$WORK/fake_launcher.sh" <<'EOF'
#!/bin/bash
set -u
tmux kill-session -t "=$PANE_SESSION" 2>/dev/null
# 🔴 Высота панели 20, а не 45: pane_tail берёт ПОСЛЕДНИЕ 40 строк, а capture-pane отдаёт всю
# панель целиком вместе с пустым низом. На панели в 45 строк tail -40 срезал ПЕРВЫЕ пять строк
# образца — и стенд «лимит сессии» ложно показывал, что детектор ничего не увидел.
# Подставная панель ведёт себя как настоящий REPL: строка ошибки остаётся видимой над полем ввода.
# Голый `cat` так не умеет — побудка дописывала текст, и ошибка уезжала за край панели (это дефект
# СТЕНДА, а не супервизора; из-за него же 15.08 нашлась настоящая дырка в счётчике побудок).
# Высота 36 < 40: pane_tail берёт последние 40 строк, значит панель попадает в него целиком.
tmux new-session -d -s "$PANE_SESSION" -x 200 -y 36 \
  "bash -c 'cat \"$RIG_PANE\"; while IFS= read -r l; do printf \"%s\\n\" \"\$l\" >> \"$RIG_DELIVERED\"; cat \"$RIG_PANE\"; done'"
mkdir -p "$JSONL_DIR"
printf '{"task":"%s","note":"fake transcript"}\n' "$TASK" > "$JSONL_DIR/rig_$(date +%s%N).jsonl"
sleep 3000 &
echo $! > "$PID_FILE"
EOF
chmod +x "$WORK/fake_launcher.sh"

# run_rig <имя> <фикстура панели> <доп-env…> — запускает супервизор в фоне, печатает путь к логу
run_rig(){
  local name pane
  name="$1"; pane="$2"; shift 2
  local dir="$WORK/$name"
  mkdir -p "$dir/logs" "$dir/state" "$dir/reports" "$dir/jsonl"
  : > "$dir/task.md"
  ( export TASK="T263RIG" PROJECT_DIR="$dir" TASK_FILE="$dir/task.md" \
           REPORT="$dir/reports/report_T263RIG.md" LOG_DIR="$dir/logs" STATE_DIR="$dir/state" \
           JSONL_DIR="$dir/jsonl" PANE_SESSION="t263rig_${RID}_$name" LAUNCHER="$WORK/fake_launcher.sh" \
           PID_FILE="$dir/state/rig.pid" RIG_PANE="$FX/$pane" NOTIFY_CMD="$WORK/notify_$name.sh" \
           RIG_DELIVERED="$dir/delivered.txt" \
           SUPLOG="$dir/logs/sup.log" PAUSE_FLAG="$dir/never_paused" RAM_RESPAWN_MIN_KB=1 \
           POLL=5 "$@"
    bash "$SUP" ) >/dev/null 2>&1 &
  echo $! >> "$SUPPIDS"
  echo "$dir/logs/sup.log"
}
mk_notify(){ cat > "$WORK/notify_$1.sh" <<EOF
#!/bin/bash
echo "\$*" >> "$WORK/notify_$1.log"
EOF
chmod +x "$WORK/notify_$1.sh"; : > "$WORK/notify_$1.log"; }
waitfor(){ # waitfor <файл> <шаблон> <сек>
  local i=0
  while [ "$i" -lt "$3" ]; do grep -qa -- "$2" "$1" 2>/dev/null && return 0; sleep 2; i=$((i+2)); done
  return 1
}

# --- D1: ошибка связи → побудки → снятие без ожидания STALL --------------------------------
mk_notify d1
LOG1="$(run_rig d1 pane_api_enotimp.txt API_ERROR_QUIET=20 API_ERROR_GRACE=15 API_ERROR_TRIES=3 \
        STALL_LIMIT=900 NO_JSONL_LIMIT=900 MAX_RESPAWN=0 API_ERROR_NIGHT_FROM=0 API_ERROR_NIGHT_TO=0)"
printf '  … D1 стенд «ошибка связи» поднят, лог %s\n' "$LOG1"

# --- D2: регресс — обычная панель, ошибок нет, поведение прежнее ----------------------------
mk_notify d2
LOG2="$(run_rig d2 pane_working_agent.txt API_ERROR_QUIET=20 API_ERROR_GRACE=15 API_ERROR_TRIES=3 \
        STALL_LIMIT=40 NO_JSONL_LIMIT=900 REMIND_LIMIT=1 MAX_RESPAWN=0 API_ERROR_NIGHT_FROM=0 API_ERROR_NIGHT_TO=0)"
printf '  … D2 стенд «регресс STALL» поднят, лог %s\n' "$LOG2"

# --- D3: лимит сессии не уходит в API-ветку -------------------------------------------------
mk_notify d3
LOG3="$(run_rig d3 pane_rate_limit_with_api.txt API_ERROR_QUIET=20 API_ERROR_GRACE=15 API_ERROR_TRIES=3 \
        STALL_LIMIT=900 NO_JSONL_LIMIT=900 MAX_RESPAWN=0 API_ERROR_NIGHT_FROM=0 API_ERROR_NIGHT_TO=0)"
printf '  … D3 стенд «лимит сессии» поднят, лог %s\n' "$LOG3"

# --- D4: агент ожил после первой побудки → счётчик обнуляется, снятия нет -------------------
mk_notify d4
LOG4="$(run_rig d4 pane_api_enotimp.txt API_ERROR_QUIET=20 API_ERROR_GRACE=15 API_ERROR_TRIES=3 \
        STALL_LIMIT=900 NO_JSONL_LIMIT=900 MAX_RESPAWN=0 API_ERROR_NIGHT_FROM=0 API_ERROR_NIGHT_TO=0)"
printf '  … D4 стенд «ожил после побудки» поднят, лог %s\n' "$LOG4"
# как только увидим первую побудку — «оживляем» транскрипт, трогая jsonl
( if waitfor "$LOG4" "попытка 1/3" 120; then
    for _ in $(seq 1 10); do find "$WORK/d4/jsonl" -name '*.jsonl' -exec touch {} + 2>/dev/null; sleep 3; done
  fi ) &

# --- сбор результатов D1 ---
if waitfor "$LOG1" "попытка 1/3" 120; then
  ok "D1: первая побудка вышла"
  # доказательство доставки: текст побудки должен ЛЕЖАТЬ В ПАНЕЛИ агента
  sleep 2
  # 🔴 Доказательство доставки — не снимок панели (его сносит новым выводом), а то, что подставной
  # агент ПРОЧИТАЛ текст со своего ввода: ровно этим каналом работают remind_commit/remind_report.
  chk "D1: побудка ДОШЛА до агента (прочитана с его ввода)" "1" \
      "$( [ "$(grep -ca 'Связь восстановилась' "$WORK/d1/delivered.txt" 2>/dev/null)" -ge 1 ] && echo 1 || echo 0)"
else bad "D1: первой побудки не дождались"; fi
if waitfor "$LOG1" "разбудить не удалось" 180; then ok "D1: после исчерпания попыток агент снят с явной причиной"
else bad "D1: эскалации не дождалась"; fi
sleep 6
chk "D1: побудок ровно 3 (API_ERROR_TRIES)" "3" "$(grep -ca 'бужу агента' "$LOG1")"
chk "D1: снят ДО STALL_LIMIT=900 (строки STALL в логе нет)" "0" "$(grep -ca 'STALL jsonl quiet' "$LOG1")"
chk "D1: причина ушла и в пинг" "1" "$( [ "$(grep -ca 'встал на ошибке связи' "$WORK/notify_d1.log")" -ge 1 ] && echo 1 || echo 0)"
chk "D1: карантин §24 — respawn-лимит исчерпан" "1" "$( [ "$(grep -ca 'respawn-лимит исчерпан после ошибки связи' "$LOG1")" -ge 1 ] && echo 1 || echo 0)"

# --- сбор результатов D2 (регресс) ---
if waitfor "$LOG2" "STALL jsonl quiet" 150; then ok "D2: STALL-ветка сработала как раньше"
else bad "D2: STALL не сработал"; fi
sleep 4
chk "D2: API-ветка не вмешалась ни разу" "0" "$(grep -ca 'API-ERROR' "$LOG2")"
chk "D2: напоминание про отчёт перед respawn осталось" "1" \
    "$( [ "$(grep -ca 'напоминание 1/1' "$LOG2")" -ge 1 ] && echo 1 || echo 0)"
chk "D2: kill+respawn по прежнему пути" "1" \
    "$( [ "$(grep -ca 'kill+respawn' "$LOG2")" -ge 1 ] && echo 1 || echo 0)"

# --- сбор результатов D3 (лимит сессии) ---
if waitfor "$LOG3" "RATE-LIMIT в панели" 120; then ok "D3: лимит сессии распознан отдельной веткой"
else bad "D3: строки про RATE-LIMIT нет"; fi
chk "D3: побудок по API не было" "0" "$(grep -ca 'бужу агента' "$LOG3")"
chk "D3: агента не снимали" "0" "$(grep -ca 'разбудить не удалось' "$LOG3")"
chk "D3: отметка о лимите одна, лог не засорён" "1" "$(grep -ca 'RATE-LIMIT в панели' "$LOG3")"

# --- сбор результатов D4 (ожил) ---
if waitfor "$LOG4" "агент продолжил" 200; then ok "D4: ожил после побудки — записано в лог"
else bad "D4: строки «агент продолжил» нет"; fi
chk "D4: до снятия дело не дошло" "0" "$(grep -ca 'разбудить не удалось' "$LOG4")"
chk "D4: счётчик обнулён (сообщение про обнуление есть)" "1" \
    "$( [ "$(grep -ca 'счётчик обнулён' "$LOG4")" -ge 1 ] && echo 1 || echo 0)"

# --- D5: ЧЕРНОВИК ОТЧЁТА НЕ ОТМЕНЯЕТ ПРОВЕРКУ СВЯЗИ (регресс фикса 07.09.2026, кейс T339) ----
# Зачем этот стенд. Детектор ошибки связи существовал с 15.08, но у реальных задач НЕ РАБОТАЛ:
# ветка «черновик отчёта у живого агента» делала continue раньше, чем цикл доходил до
# handle_api_error. А отчёт «по ходу» требуется в каждом таск-файле, то есть файл отчёта
# появляется в первые минуты. 07.09 агент T339 простоял на ENOTIMP 1 ч 11 мин, и в журнале
# задачи не было ни одной строки со словом API. Стенд ловит именно этот порядок проверок.
mk_notify d5
LOG5="$(run_rig d5 pane_api_enotimp.txt API_ERROR_QUIET=20 API_ERROR_GRACE=15 API_ERROR_TRIES=3 \
        STALL_LIMIT=900 NO_JSONL_LIMIT=900 MAX_RESPAWN=0 API_ERROR_NIGHT_FROM=0 API_ERROR_NIGHT_TO=0)"
# Отчёт-черновик появляется ПОСЛЕ старта супервизора — ровно как в жизни. Положить его заранее
# нельзя: на старте, до подъёма агента, отчёт без STATUS честно уводит задачу в карантин (exit 3).
sleep 8
printf '# T263RIG. Черновик: агент пишет отчёт по ходу, строки STATUS ещё нет\n' \
  > "$WORK/d5/reports/report_T263RIG.md"
printf '  … D5 стенд «черновик отчёта + обрыв связи» поднят, лог %s\n' "$LOG5"

# --- сбор результатов D5 ---
if waitfor "$LOG5" "агент ЖИВ и пишет" 120; then ok "D5: супервизор увидел черновик отчёта"
else bad "D5: черновик не распознан — стенд собран неверно, вывод о фиксе делать нельзя"; fi
if waitfor "$LOG5" "бужу агента" 200; then ok "D5: побудка вышла, хотя отчёт-черновик уже существовал"
else bad "D5: побудки не дождались — черновик снова перехватывает цикл (регресс фикса T339)"; fi

cleanup
;; esac

# ============================================================================
# E. Регресс old-vs-new
# ============================================================================
case "$PARTS" in *E*)
hdr "E. регресс old-vs-new"
if [ -z "$OLD" ] || [ ! -f "$OLD" ]; then
  printf '  (пропущено: не задан OLD=<старый шаблон>)\n'
else
  # 🔴 Срез функций СТАРОГО шаблона готовим ПЕРВЫМ делом. 15.08 он готовился ниже, в блоке E2, а
  # проба E1b стояла выше и источала ещё НЕ СОЗДАННЫЙ файл: sourcing молча падал, RATE_LIMIT_RE
  # оставался пустым, а ПУСТОЙ шаблон в grep совпадает с ЛЮБОЙ строкой — старый шаблон выглядел
  # «ловящим всё». Проверять надо и сам стенд: «тест показал» — это гипотеза, а не вывод.
  funcs_of "$OLD" "$WORK/oldfuncs.sh"
  # E1. структурный diff: какие строки ЗАМЕНЕНЫ (всё остальное обязано быть чистым добавлением)
  diff -u "$OLD" "$SUP" | grep '^-[^-]' | sed 's/^-//' > "$WORK/removed.txt"
  printf '  заменённые/удалённые строки (%s):\n' "$(wc -l < "$WORK/removed.txt")"
  sed 's/^/    /' "$WORK/removed.txt"
  chk "E1: заменено ровно 8 строк (2 гейта + 5 таргетов tmux + умолчание RATE_LIMIT_RE)" "8" "$(wc -l < "$WORK/removed.txt")"
  chk "E1: логика веток COMMIT_GATE/REPORT-ALIAS/STALL/finish не тронута ни одной строкой" "0" \
      "$(grep -cE 'COMMIT_GATE|REPORT-ALIAS|STALL_LIMIT|finish_on_report|commit_pending|report_is_draft' "$WORK/removed.txt")"
  # E1b. RATE_LIMIT_RE починен — но НЕ ослаблен: всё, что ловил старый шаблон, ловит и новый.
  # 🔴 Пробы гоняем ОТДЕЛЬНЫМ скриптом в ЧИСТОМ окружении (env -i), а не в подоболочке харнесса.
  # Две причины, обе пойманы этим же харнессом 15.08:
  #  1) часть A уже источала НОВЫЙ шаблон в оболочку харнесса — переменная RATE_LIMIT_RE оставалась
  #     выставленной, и `${RATE_LIMIT_RE:-<умолчание>}` в СТАРОМ файле брал уже починенное значение,
  #     то есть старый шаблон выглядел исправным;
  #  2) те же строки внутри `bash -c '…'` разъезжались по вложенным кавычкам. Скрипт на диске
  #     снимает оба вопроса разом.
  cat > "$WORK/probe_lim.sh" <<'PROBE'
#!/bin/bash
set +u
[ -f "$1" ] || { echo "NOFUNCS"; exit 9; }
. "$1"
for s in "You've hit your session limit" "Your limit will reset soon" "usage limit reached" \
         "resets at 4:30pm" "You've hit your 5-hour limit" "обычная строка вывода агента"; do
  printf '%s' "$s" | grep -aqiE "$RATE_LIMIT_RE" && printf 'Y' || printf 'N'
done
echo
PROBE
  cat > "$WORK/probe_funcs.sh" <<'PROBE'
#!/bin/bash
set +u
[ -f "$1" ] || { echo "NOFUNCS"; exit 9; }
. "$1"
printf 'status_ok=%s\n'     "$(printf 'x\nSTATUS: SUCCESS\n' > "$REPORT"; report_status)"
printf 'status_lower=%s\n'  "$(printf 'STATUS: partial\n'   > "$REPORT"; report_status)"
printf 'status_none=%s\n'   "$(printf 'нет строки\n'        > "$REPORT"; report_status)"
printf 'status_tail=%s\n'   "$(printf 'STATUS: FAIL\nхвост после\n' > "$REPORT"; report_status)"
printf 'inlist_yes=%s\n'    "$(status_in_list PARTIAL 'partial blocked' && echo Y || echo N)"
printf 'inlist_no=%s\n'     "$(status_in_list SUCCESS 'partial blocked' && echo Y || echo N)"
printf 'alive_bad=%s\n'     "$(alive_pid 999999 && echo Y || echo N)"
printf 'alive_self=%s\n'    "$(alive_pid $$ && echo Y || echo N)"
LAUNCH_TS=$(date +%s); REPORT="$WORK/proj/reports/нет_такого.md"
printf 'resolve_miss=%s\n'  "$(resolve_report >/dev/null 2>&1 && echo Y || echo N)"
PROBE
  clean_run(){   # clean_run <скрипт-пробы> <файл-функций>
    env -i PATH="$PATH" HOME="$HOME" WORK="$WORK" TASK="T263SELFTEST" PROJECT_DIR="$WORK/proj" \
      TASK_FILE="$WORK/task.md" REPORT="$WORK/proj/reports/report_T263SELFTEST.md" \
      LOG_DIR="$WORK/proj/logs" STATE_DIR="$WORK/proj/state" PANE_SESSION="t263rig_none" \
      NOTIFY_CMD="" bash "$1" "$2" 2>/dev/null
  }
  lim_probe(){ clean_run "$WORK/probe_lim.sh" "$1"; }
  probe(){ clean_run "$WORK/probe_funcs.sh" "$1"; }
  L_OLD="$(lim_probe "$WORK/oldfuncs.sh")"; L_NEW="$(lim_probe "$WORK/newfuncs.sh")"
  printf '    строки лимита: старый=%s новый=%s (порядок: session/will reset/usage reached/resets at 4:30pm/5-hour/шум)\n' "$L_OLD" "$L_NEW"
  lost=0; i=1
  while [ "$i" -le "${#L_OLD}" ]; do
    o="${L_OLD:$((i-1)):1}"; n="${L_NEW:$((i-1)):1}"
    [ "$o" = Y ] && [ "$n" = N ] && lost=$((lost+1))
    i=$((i+1))
  done
  chk "E1b: новый RATE_LIMIT_RE не потерял ни одной строки, что ловил старый" "0" "$lost"
  chk "E1b: «resets at 4:30pm» старый НЕ ловил (склеенный {1,2)" "N" "${L_OLD:3:1}"
  chk "E1b: «resets at 4:30pm» новый ловит" "Y" "${L_NEW:3:1}"
  chk "E1b: обычная строка вывода агента не считается лимитом (и там, и там)" "NN" "${L_OLD:5:1}${L_NEW:5:1}"
  # E2. поведение общих функций: одинаковые входы — одинаковые ответы
  probe(){ # probe <файл-функций> — тоже в чистом окружении, по той же причине
    local f="$1"
    env -i PATH="$PATH" HOME="$HOME" WORK="$WORK" \
      TASK="T263SELFTEST" PROJECT_DIR="$WORK/proj" TASK_FILE="$WORK/task.md" \
      REPORT="$WORK/proj/reports/report_T263SELFTEST.md" LOG_DIR="$WORK/proj/logs" \
      STATE_DIR="$WORK/proj/state" PANE_SESSION="t263rig_none" NOTIFY_CMD="" \
      bash -c 'set +u; f="$1"
      . "$f"
      printf "status_ok=%s\n"     "$(printf "x\nSTATUS: SUCCESS\n" > "$REPORT"; report_status)"
      printf "status_lower=%s\n"  "$(printf "STATUS: partial\n"   > "$REPORT"; report_status)"
      printf "status_none=%s\n"   "$(printf "нет строки\n"        > "$REPORT"; report_status)"
      printf "status_tail=%s\n"   "$(printf "STATUS: FAIL\nхвост после\n" > "$REPORT"; report_status)"
      printf "inlist_yes=%s\n"    "$(status_in_list PARTIAL "partial blocked" && echo Y || echo N)"
      printf "inlist_no=%s\n"     "$(status_in_list SUCCESS "partial blocked" && echo Y || echo N)"
      printf "alive_bad=%s\n"     "$(alive_pid 999999 && echo Y || echo N)"
      printf "alive_self=%s\n"    "$(alive_pid $$ && echo Y || echo N)"
      LAUNCH_TS=$(date +%s); REPORT="$WORK/proj/reports/нет_такого.md"
      printf "resolve_miss=%s\n"  "$(resolve_report >/dev/null 2>&1 && echo Y || echo N)"
      ' _ "$f" 2>/dev/null
  }
  probe "$WORK/oldfuncs.sh" > "$WORK/probe_old.txt"
  probe "$WORK/newfuncs.sh" > "$WORK/probe_new.txt"
  if diff -q "$WORK/probe_old.txt" "$WORK/probe_new.txt" >/dev/null; then
    ok "E2: общие функции (report_status/status_in_list/alive_pid/resolve_report) отвечают идентично"
    sed 's/^/    /' "$WORK/probe_new.txt"
  else
    bad "E2: поведение общих функций разошлось"; diff -u "$WORK/probe_old.txt" "$WORK/probe_new.txt" | sed 's/^/    /'
  fi
  # E3. режим харнесса не запускает агента
  SUPERVISOR_SELFTEST=1 TASK=T263SELFTEST PROJECT_DIR="$WORK/proj" TASK_FILE="$WORK/task.md" \
    REPORT="$WORK/proj/reports/report_T263SELFTEST.md" bash "$SUP" >/dev/null 2>&1
  chk "E3: SUPERVISOR_SELFTEST=1 завершается кодом 0 и агента не поднимает" "0" "$?"
fi
;; esac

printf '\n== ИТОГ: pass=%s fail=%s (work=%s)\n' "$PASS" "$FAIL" "$WORK"
[ "$FAIL" -eq 0 ]
