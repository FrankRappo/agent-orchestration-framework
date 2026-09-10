# Claude interactive-REPL task agents

Аналог `../codex/` для Claude, но агент — **интерактивный `claude` REPL в tmux**, а не
`claude -p`. REPL персистентен, переживает одиночный API-сбой, его можно инспектировать
(`tmux attach -t claude_<TASK>_repl`) и продолжать.

## Файлы
- `claude_agent_launcher.template.sh` — поднимает один REPL в tmux, вставляет промпт
  (preamble + task), пишет PID (pane_pid = claude).
- `claude_supervisor.template.sh` — надзор за ОДНИМ агентом: stall по росту jsonl
  (Claude-native), лимит 5ч/session по capture-pane, respawn, контракт `STATUS:`.
- `claude_orchestrator.template.sh` — очередь task-файлов: по одному за раз (RAM-гейт),
  Resource-Lock для singleton-ресурсов, **динамическая** (не выходит на пустой очереди —
  ждёт новые `tasks/T*.md`).
- `orchestrator_keeper.template.sh` — сторож самой очереди: поднимает упавший оркестратор,
  но только когда памяти хватает (см. `RAM_GUARD.md` §8).
- `task.template.md` — контракт задачи (гейты + обязательная строка `STATUS:`).

## Раскладка проекта
```
/work/<project>/
  tasks/T01_*.md        reports/report_T01_*.md
  logs/                 state/            orch/progress.md
```

## Запуск (AS agentuser — под ним живут tmux/jsonl/claude-auth)
```bash
runuser -u agentuser -- env -i HOME=/home/agentuser \
  PATH=/home/agentuser/.local/bin:/usr/local/bin:/usr/bin:/bin SHELL=/bin/bash \
  tmux new-session -d -s <proj>_orch -c /work/<project> \
  "PROJECT_DIR=/work/<project> MAX_PARALLEL=1 bash /work/settings/claude/claude_orchestrator.template.sh"
```

Сторож очереди (от root, чтобы упавший оркестратор поднялся сам):
```bash
tmux new-session -d -s <proj>_keeper \
  "PROJECT_DIR=/work/<project> SESSION=<proj>_orch \
   RUNNER=/work/<project>/orch/_run_orch.sh \
   NOTIFY_CMD='python3 /work/tg/bot.py send <chat_id>' \
   bash /work/settings/claude/orchestrator_keeper.template.sh"
```

Мониторинг:
```bash
tail -f /work/<project>/logs/claude_orchestrator.log
tail -f /work/<project>/logs/T01_*_supervisor.log
runuser -u agentuser -- tmux attach -t claude_T01_<slug>_repl   # заглянуть в живой REPL (Ctrl-b d — выйти)
cat /work/<project>/reports/report_T01_*.md
```

Стоп: `runuser -u agentuser -- tmux kill-session -t =<proj>_orch` (затем при нужде `=claude_*_sup` / `=claude_*_repl`).

## Контракт завершения
Финиш = отчёт `reports/report_<TASK>.md`, последняя строка `STATUS: SUCCESS|FAIL|BLOCKED|PARTIAL`.
Факт файла ≠ успех — успех только при `STATUS: SUCCESS`.

## Отличия от codex-раннеров
- Stall — по jsonl (не по stdout-логу, у REPL его нет).
- Лимит — по `tmux capture-pane` REPL-панели.
- `global_ram_guard.sh` применим (это claude-сторож), в отличие от codex-очередей.
