# RAM-сторож v3 — защита WSL от OOM (машинный уровень)

Файлы:
- `/work/settings/claude/ram_guard_v3.sh` — сам сторож (демон + утилиты диагностики)
- `/work/settings/claude/ram_guard_v3_start.sh` — идемпотентный старт (cron / profile.d / wsl.conf)
- `/work/settings/claude/ram_guard_v3.conf` — пороги, читаются на каждом тике (правка без рестарта)
- `/work/settings/claude/ram_guard_protect_pids` — PID, которые не трогать ни при каких условиях
- `/work/settings/claude/ram_guard_v3.log` — что делал сторож
- `/work/settings/claude/ram_guard_top.log` — снапшоты топ-потребителей (посмертная улика)

Машина: WSL, `.wslconfig` `memory=6GB`, своп 2 GB, systemd выключен.

🔴 **Границы ответственности: сторож меряет ПАМЯТЬ и больше ничего.** Есть второй способ уронить
ту же виртуалку, который он не увидит никогда: **переполнение тома Windows, где лежит файл диска
WSL** (`ext4.vhdx`). Файл растёт и обратно место не отдаёт; кончилось место на томе — запись в
гостевой ext4 отваливается ошибкой ввода-вывода, и виртуалка встаёт целиком, при полностью
здоровой памяти. Так 12.08.2026 оборвалась ночная волна PROJECTA: в 01:51:59 сторож записал
`avail=4076 Mi state=OK`, а в 01:54 всё остановилось. Разбор и признаки — `GOTCHAS.md` #13.

От этого защищает отдельный гейт в `claude_orchestrator.template.sh` (`disk_ok`, `DISK_MIN_GB`,
умолчание 15 ГБ на `/mnt/c`). Увидел «всё встало, а памяти было полно» — смотри диск, а не сторож.

---

## 1. Зачем: разбор OOM 29.07.2026

С 07:49:50 до 08:00:28 `MemAvailable` сполз с 907 Mi до 106 Mi, VM пришлось перезагружать.
Память в этот момент держали: codex/omx под root (сессия с 28.07 23:46), Chrome под agentuser с
вкладками claude.ai (сейчас в покое это уже 1.3 Gi), claude-сессия agentuser в `/work/projecte`
и интерактивные claude-сессии под root.

Старый сторож (`global_ram_guard.sh`, v2) не мог сделать НИЧЕГО, и это было структурно:

- кандидатов он искал только среди `ps -u agentuser` с `comm=claude` и cwd под `/work/projecta` либо
  `/work/projectb` — всё, что под root, и сессия в `/work/projecte` мимо;
- codex/omx ловил маской `pgrep -f 'oh-my-codex|dist/cli/omx|[ ]codex'` — поймал один node на 20 Mi,
  а сам codex писал на диск ещё до 07:56;
- бил ОДИН процесс, а не дерево: Chrome из сотни процессов отдавал «самого жирного» в 72 Mi.

В логе это выглядело как `STOP sub-agent PGIDs:` с пустым списком и четыре тика подряд
«безопасных кандидатов на kill нет». После ребута не осталось никаких следов, кто именно съел память.

## 2. Что делает v3

Каждые 10 секунд снимает `ps` по ВСЕЙ машине, считает RSS деревьев процессов и относит каждое
дерево к классу: `codex` (codex/omx), `chrome`, `claude_batch` (агент без TTY — запущен супервизором),
`claude_tty` (интерактивная сессия), `other`, `system` (init, kthreadd, SessionLeader/Relay WSL).

Лестница по `MemAvailable` (пороги в `ram_guard_v3.conf`):

| состояние | порог | действие |
|---|---|---|
| SOFT  | < 1400 Mi | заморозка (`SIGSTOP`) деревьев codex/omx + снапшоты топа каждые 30 с |
| CRIT  | < 800 Mi  | плюс пауза batch-агентов claude (любой пользователь, любой cwd), не дольше 180 с; ставится флаг `/tmp/ram_paused`, который читают супервизоры |
| EMERG | < 450 Mi  | реальный `kill -9` ОДНОГО дерева за тик по приоритету: codex -> chrome -> claude_batch -> other -> интерактивная claude-сессия |
| OK    | > 1800 Mi | снятие всех пауз (гистерезис) |

Дополнительно: если `/proc/pressure/memory` `some avg10` выше 25 (реальный thrash), состояние
считается на ступень хуже — свопящаяся VM успевает замёрзнуть раньше, чем avail дойдёт до порога.

Что НЕ трогается никогда (маска `PROTECT_RE` в скрипте): xray, sing-box, sshd, cron, tg-бот,
claude_saver, rustdesk, Xvfb/x11vnc, tmux server, init/SessionLeader/Relay WSL, сам сторож и его предки.
Плюс всё, что перечислено в `ram_guard_protect_pids`.

Порог для интерактивной claude-сессии отдельный и высокий (350 Mi) — она последняя в очереди,
но не бессмертна: замёрзшая VM хуже потерянной сессии.

## 3. Команды

```bash
bash /work/settings/claude/ram_guard_v3.sh status   # жив ли демон, память, паузы, топ потребителей
bash /work/settings/claude/ram_guard_v3.sh top      # только топ деревьев по RSS (в лог + на экран)
bash /work/settings/claude/ram_guard_v3.sh dry      # кого сторож убил бы в аварии — БЕЗ сигналов
bash /work/settings/claude/ram_guard_v3_start.sh    # поднять, если не жив (идемпотентно)
bash /work/settings/claude/ram_guard_v3.sh stop     # остановить демон

tail -f /work/settings/claude/ram_guard_v3.log      # действия сторожа
tail -30 /work/settings/claude/ram_guard_top.log    # кто ел память (в т.ч. перед фризом)
```

Защитить конкретную сессию от последней очереди килла:
```bash
ps -eo pid,user,tty,comm | grep claude          # найти PID своей сессии
echo 12345 >> /work/settings/claude/ram_guard_protect_pids
```

## 4. Автозапуск (три слоя, systemd тут нет)

1. `/etc/wsl.conf` секция `[boot]`: `service cron start` + старт сторожа. Основной путь,
   применяется со следующего полного старта VM (`wsl --shutdown`).
2. root-crontab: `@reboot` и keepalive `*/2 * * * *` — поднимет сторожа, если тот умер.
3. `/etc/profile.d/zz-ram-guard.sh` — любой вход в шелл от root поднимает сторожа, если он не жив.

Проверка после ребута:
```bash
bash /work/settings/claude/ram_guard_v3.sh status | head -2
pgrep -x cron >/dev/null && echo cron ok
```

## 5. Что делать после срабатывания

- `ram_guard_top.log` показывает, какое дерево росло перед аварией — начинать с него.
- Если сторож убил Chrome или codex, это ожидаемо: они первые в очереди жертв.
- Если в логе снова появится «кандидатов выше порога нет» — значит память ушла в класс,
  который считается защищённым; смотреть снапшот топа и расширять классификацию.

## 6. Организационная часть (её сторож не заменяет)

6 Gi — это примерно: Chrome 1.5-2.5 Gi + одна интерактивная claude-сессия 0.5-1.5 Gi +
один batch-агент 0.5-1.5 Gi + codex 0.5-1 Gi. Любые три тяжёлых потребителя одновременно —
уже впритык. Правило «один оркестратор за раз» (PROJECTA workflow §0) касается ВСЕЙ машины, а не
одного проекта: параллельная волна в другом каталоге, codex и браузер считаются наравне.

## 7. Откат

Старый сторож не удалён: `/work/settings/claude/global_ram_guard.sh` (v2) на месте,
бэкап v2 и прежних конфигов — в `/work/settings/claude/_backup_ramguard_v3_<ts>/`
(там же `wsl.conf.orig` и `root_crontab.orig`). Порядок отката:
```bash
bash /work/settings/claude/ram_guard_v3.sh stop
crontab -l | grep -v ram_guard_v3 | crontab -
rm -f /etc/profile.d/zz-ram-guard.sh
cp /work/settings/claude/_backup_ramguard_v3_<ts>/wsl.conf.orig /etc/wsl.conf
tmux new-session -d -s global_ram_guard "bash -c 'while true; do bash /work/settings/claude/global_ram_guard.sh; sleep 15; done'"
```


## 8. Кто поднимает то, что сторож убил (12.08.2026)

Сторож убивает, но не воскрешает. Восстановление разложено по слоям, и у каждого свой порог
`MemAvailable` — лестница построена так, чтобы подъём шёл сверху вниз и не толкал машину обратно
в дефицит:

| Убитое | Кто поднимает | Порог | Файл |
|---|---|---|---|
| агент (claude в REPL) | супервизор, функция `wait_for_ram` | `RAM_RESPAWN_MIN_KB`, деф. 1.1 Gi | `claude/claude_supervisor.template.sh` |
| супервизор | оркестратор (таск возвращается в очередь) | `RAM_MIN_KB`, деф. 0.9 Gi | `claude/claude_orchestrator.template.sh` |
| сам оркестратор | keeper очереди | `MIN_KB`, деф. 1.2 Gi | `claude/orchestrator_keeper.template.sh` |

Логика одна и та же: память есть — поднимаем сразу; памяти нет — ждём и пишем в TG, а не
долбимся в дефицит. Флаг `/tmp/ram_paused` уважают все три слоя: пока сторож держит паузу,
никто ничего не поднимает.

Почему это важнее, чем кажется: до 12.08 супервизор перезапускал агента мгновенно после смерти.
Если агента убил именно сторож, respawn попадал в тот же дефицит, умирал снова и за четыре круга
съедал `MAX_RESPAWN` — здоровый таск уходил в карантин, хотя виновата была только память.

Keeper запускается от root рядом с очередью:

```bash
tmux new-session -d -s <proj>_keeper \
  "PROJECT_DIR=/work/<project> SESSION=<proj>_orch \
   RUNNER=/work/<project>/orch/_run_orch.sh \
   NOTIFY_CMD='python3 /work/tg/bot.py send <chat_id>' \
   bash /work/settings/claude/orchestrator_keeper.template.sh"

tail -f /work/<project>/logs/orch_keeper.log
```

Перезапуск оркестратора безопасен для работающих тасков: `start_task` идемпотентен и живые
сессии супервизоров пропускает — проверено 12.08 на живой очереди из двух параллельных агентов.
