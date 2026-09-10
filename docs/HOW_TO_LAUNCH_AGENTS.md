# Как правильно запускать агентов (шпаргалка)

Краткий правильный способ. Глубина/грабли — в `HOW_TO_RUN.md` (ссылки на § ниже). Образец раннера — `tasks_runner.template.sh` (RL-aware, 2026-07-04).

## Архитектура (3 уровня, каждый переживает 5ч-лимит)
```
СУПЕРВИЗОР (root, tmux <tag>_sup)      ← держит ОРКЕСТРАТОР живым, RL-aware
   └─ ОРКЕСТРАТОР (agentuser, tmux <tag>)   ← читает progress.md, спавнит саб-агентов по одному
        └─ RUNNER (tasks/runner.sh)    ← один саб-агент = claude -p < task.md, RL-aware
```
- **Супервизор** переживает 5ч/session-лимит: `handle_rate_limit` (RL_RE + цикл `sleep RL_WAIT → relaunch`, respawn НЕ тратит). Образец — `single_agent_supervisor.template.sh` / боевой `orch/orchestrator_supervisor_*.sh`.
- **Runner** тоже RL-aware (2026-07-04): при лимите ждёт сброса циклом, НЕ тратя `retry×3`. Без этого 3 быстрых ретрая сгорают об лимит → ложный `.failed` (кейс §9.3bis на уровне runner).

## Запуск ОДНОГО саб-агента (от agentuser, через runner)
```bash
chmod -R 777 /work/<proj>/tasks /work/<proj>/logs /work/<proj>/reports 2>/dev/null
setsid runuser -u agentuser -- env -i HOME=/home/agentuser \
  PATH="/home/agentuser/.local/bin:/home/agentuser/.cargo/bin:/usr/local/bin:/usr/bin:/bin" \
  SHELL=/bin/bash /work/<proj>/tasks/runner.sh T<NN> \
  </dev/null >>/work/<proj>/logs/T<NN>_runner.log 2>&1 &
```
Runner сам: idempotent-скип по `reports/T<NN>.done`, pid-lock, retry×3 + RL-ожидание, пишет `.done`/`.failed`, TG-пинг.
🔴 `--dangerouslyDisableSandbox` — для команд с ssh/socks/sleep/деплоем (песочница режет сигналом 16). `--dangerously-skip-permissions` у claude ОБЯЗАТЕЛЕН (иначе саб-агент без прав Write/Bash).

## Запуск ОРКЕСТРАТОРА волны (супервизор поднимает сам)
```bash
# 1. подготовить: tasks/T*.md, orch/orchestrator_progress_<W>.md, orchestrator_<W>_prompt.md,
#    launch_<W>_orchestrator.sh, orchestrator_supervisor_<W>.sh (клон рабочего супервизора)
# 2. запустить супервизор от ROOT — он поднимет оркестратор и будет держать живым:
tmux new-session -d -s orv_<W>_sup -c /work/<proj> "bash /work/<proj>/orch/orchestrator_supervisor_<W>.sh"
sleep 45; runuser -u agentuser -- tmux ls | grep <W>; tail -5 /work/<proj>/orch/logs/<W>_supervisor.log
```
Оркестратор в промпте: RE-GREP GUARD (§9.10.2) перед каждым spawn, TASK PICKUP LOOP (§9.10.3), дисциплина progress.md (§9.2), точка выхода = все `[x]`/`[~]` → `reports/ALL_DONE_<W>`.

## Автономный оркестратор: сам пишет таск-файлы и спавнит агентов (2026-07-11)

Мощная и проверенная схема: оркестратор не только гоняет заранее написанные `tasks/T*.md`,
но и САМ порождает новые — когда по гейтам видит, что нужен фикс или доп-шаг. Разделение
труда: человек (или setup-агент) задаёт рамку и первые таски + `10_charter`/гейты; дальше
оркестратор автономно судит результат, ставит диагноз причины, ПИШЕТ новый таск-файл под эту
причину и запускает под него саб-агента — без участия человека.

Отличие от §«НЕЗАПЛАНИРОВАННЫЕ ТАСКИ» (HOW_TO_RUN §9.2): там оркестратор реагирует, когда
саб-агент САМ порекомендовал fix. Здесь шире — оркестратор авторствует таск по СВОЕМУ
гейт-суждению (принял PARTIAL → нашёл причину → написал узкий фикс), а не по подсказке.

Когда оркестратору писать таск самому:
- результат саб-агента `STATUS: PARTIAL/FAIL` по гейтам → узкий фикс-таск на одну причину;
- фазу надо разложить на под-шаги, которых не было в стартовом наборе;
- свой диагноз (Read метрик/рендеров) выявил локальную проблему в 1-2 файла.

Как писать таск-файл (тот же контракт, что у runner):
1. Имя `tasks/T<NN>fix<k>_<slug>.md` — 🔴 ID УНИКАЛЬНЫЙ и не коллизирует по маске
   `T<NN>_*.md` (runner берёт `ls T<NN>_*.md | head -1` — два файла на один ID = запустит
   не тот). Свободные номера, не пересекающиеся с прошлыми волнами.
2. Self-contained промпт: что читать (спеки/charter/предыдущий report), ЖЁСТКИЕ гейты
   приёмки числами, режим вычислений (`ionice -c3 taskset -c 0 nice -n 12`, один процесс,
   checkpoint), пути выхода, что НЕ трогать (измерители/чужие файлы), и обязательный
   `reports/T<NN>fix<k>_report.md` с первой строкой `STATUS: SUCCESS|PARTIAL|FAIL`.
3. 🔴 ADDENDUM — перенеси в таск свой диагноз и данные прошлого (убитого) прогона
   (checkpoint, что уже пробовалось, какие баги не воспроизводить). Без этого новый агент
   переоткрывает всё с нуля и жжёт токены/время.

Обязательные предохранители (иначе схема разносит проект):
- Приёмка ТОЛЬКО по гейтам: Read report + Read метрики JSON напрямую + спот-рендер глазами
  (через JPG). Не верить `STATUS:` на слово. Анти-накрутка: `git diff` измерителей пуст.
- RE-GREP GUARD перед КАЖДЫМ spawn (см. ниже) — и для авторских тасков тоже.
- progress.md: добавь строку нового таска СРАЗУ (раздел «Незапланированные»/фаза), считай
  в общий счётчик (цель = N+X). TG-пинг «запускаю незапланированный <имя>: <причина>».
- Лимит фикс-итераций на причину — 2. Не взял за 2 → зафиксируй `[~]`, TG, иди дальше.
- Храповик `best_so_far` НИКОГДА не ухудшается; PARTIAL не понижает официальный бейзлайн.
- Системная рекомендация (миграция/инфра/lockfile) — НЕ авторствуй сам: пинг + жди юзера.

Боевой пример: projecte, буква «д». Setup написал `T30/T31/T32`+промпт; оркестратор принял
`T30` как PARTIAL, сам поставил диагноз (вогнутый клин в шве тянет boundary), САМ написал
`tasks/T30fix1_junction_cusp_smooth.md` с гейтами+ADDENDUM и запустил под него агента.

## Обязательные правила (не пропускать)
- **RE-GREP GUARD перед spawn:** `grep "^- \[x\].*T<NN>" progress` / `test -f reports/T<NN>.done` / живой pid → SKIP. Доверяй файлу, не памяти (§9.10.2).
- **progress.md = источник правды** после падения: `[x]` пишется СРАЗУ после факта (§9.2). `[ ]` не начат · `[~]` partial/блокер · `[x]` готов.
- **По одному саб-агенту за раз** (RAM). Между тасками — RAM-гейт.
- **Финиш-сигнал волны = смерть `_sup`-сессии ИЛИ `reports/ALL_DONE_<W>`**, НЕ pid/progress и НЕ сессия самого оркестратора (REPL висит; §8.8, SEQUENTIAL_ORCHESTRATORS.md).
- **Визуальная верификация (§5.5):** где скрины — саб-агент ОБЯЗАН открыть их через Read и описать. «Скрин снят» ≠ «выглядит правильно».
- **RU-SOCKS для projectd** (`orch/scripts/socks_ru.sh up`, exit 178) + `dangerouslyDisableSandbox`.
- **🔴 RL-детект — узко и по свежему (кейс 2026-07-13, PROJECTA VAT22).** Маркер 5ч-лимита ищи ТОЛЬКО в настоящем harness-формате («hit your session limit · resets 7:30pm») и ТОЛЬКО в свежем хвосте (последние строки панели/лога), НЕ во всём scrollback/60КБ-jsonl — иначе проза самого агента про «rate limit / 5-hour limit» матчится как лимит → ложная 25-мин пауза и перезапуск ЖИВОГО, НЕ лимитированного агента (у интерактивного оркестратора RL-счётчик рос при работающем агенте). Узкий `RL_RE` (без `rate limit|429|overloaded|проза`) + `tail`-скоуп уже вшиты в `wave_supervisor`/`single_agent_supervisor`/`orchestrator_watchdog`. Симптом: `RATE-LIMIT #N` растёт, а `jsonl`/панель при этом свежие.

## Проверить статус волны
```bash
tmux ls | grep <W>_sup                                   # супервизор жив?
grep -c '^- \[x\]' orch/orchestrator_progress_<W>.md     # готово / всего
for p in /tmp/<tag>_T*.pid; do [ -f "$p" ] && kill -0 $(cat "$p") 2>/dev/null && echo "$p running"; done
tail /work/<proj>/orch/logs/<W>_supervisor.log
ls orch/reports/ALL_DONE_<W> 2>/dev/null && echo "ВОЛНА ЗАВЕРШЕНА"
```

## Остановить / пауза
```bash
tmux kill-session -t =orv_<W>_sup     # сначала супервизор (стоп respawn)
runuser -u agentuser -- tmux kill-session -t =orv_<W>   # затем REPL оркестратора (сам не выйдет, §9.9)
```

## Образцы (в этом каталоге)
- `tasks_runner.template.sh` — RL-aware runner (образец, копировать в `tasks/runner.sh`).
- `single_agent_supervisor.template.sh` / `wave_supervisor.template.sh` — RL-aware супервизоры.
- `orchestrator_watchdog.template.sh` — cron-watchdog (доп. страховка).
- `SEQUENTIAL_ORCHESTRATORS.md` — две волны по очереди (A↔B), не деля RAM.
- Глубина/все грабли — `HOW_TO_RUN.md`.
