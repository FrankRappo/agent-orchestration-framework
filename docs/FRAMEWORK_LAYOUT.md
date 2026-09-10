# Карта фреймворка `/work/settings` — где что лежит

Собрано задачей T200 (07.08.2026). Это ИНДЕКС фреймворка: начинать чтение отсюда.
В корне `/work/settings` обычных файлов больше нет — только подкаталоги и слой
совместимости из симлинков (см. §3).

---

## 1. Подкаталоги

| Каталог | Что внутри |
|---|---|
| `docs/` | ВСЯ документация фреймворка: `HOW_TO_RUN.md` (главный runbook), `HOW_TO_LAUNCH_AGENTS.md`, `HOW_TO_PUPPETEER.md`, `SEQUENTIAL_ORCHESTRATORS.md`, `GOTCHAS.md`, `STEER_AGENT.md`, `README.repl.md`, `RAM_GUARD.md`, `SANDBOX.md`, `EFFORT_LEVEL.md` (уровень размышлений: где стоит, как менять на лету, две ловушки переключателя), и этот файл |
| `claude/` | Шаблоны и рабочие скрипты агентов Claude: оркестратор, супервизор (с RAM-гейтом на respawn), launcher, keeper очереди, watchdog'и, очереди волн, ожидатели, RAM-сторож v3 + его conf/логи |
| `codex/` | То же для агентов Codex (свой оркестратор/супервизор/launcher, автопилот OMX) |
| `memory/` | Память оркестратора — ЗЕРКАЛО `/root/.claude/projects/-root/memory/`. Индекс: `memory/MEMORY.md`. Источник истины — оригинал в `/root/...`, эта копия для того, чтобы память жила во фреймворке и попадала в git |
| `agent-orchestration-toolkit/` | ОТДЕЛЬНЫЙ git-репозиторий с публичной санитизированной выжимкой (github.com/FrankRappo/agent-orchestration-toolkit). Исключён из `.gitignore` родителя. 🔴 Приватное содержимое туда переносить НЕЛЬЗЯ — см. его `.forbidden-patterns` (запрещены `projecta`, `agentuser`, `projectc`, имена клиентов, hostname'ы) |
| `.backups/` | Исторические снапшоты правок фреймворка. Не трогать, не переписывать ссылки внутри |

## 2. Git: приватный оригинал и публичное зеркало

Репозиториев ДВА, и путать их нельзя.

| | Приватный оригинал | Публичное зеркало |
|---|---|---|
| Где | `/work/settings` (локальный, remote НЕТ) | github.com/FrankRappo/agent-orchestration-framework |
| Что внутри | всё как есть: имена проектов, клиентов, хостов, chat_id | то же дерево, но обезличенное; без бэкапов и рантайм-логов |
| История | полная, с 19.07.2026 | ОДИН коммит, история не переносится |
| Как обновить | обычный `git commit` | `bash /work/settings/publish/publish.sh "сообщение"` |

🔴 **Remote на `/work/settings` не заводить никогда.** Содержимое (особенно
`docs/HOW_TO_RUN.md`, 185 КБ) насыщено именами проектов, клиентов, машин и городов. Наружу
уходит только результат `publish.sh`, и только после того, как гейт скажет «чисто».

**Как устроена публикация** (`publish/`):

1. снапшот берётся из `git archive HEAD`, **не из рабочего дерева** — иначе в публикацию
   уедут незакоммиченные правки параллельного исполнителя;
2. выбрасываются `.backups/`, `claude/_backup_*`, `*.bak*`, `*.log` и сам `publish/`;
3. `publish/sanitize_for_public.py` заменяет имена на плейсхолдеры: проекты →
   `projecta`…`projectj`, пользователь → `agentuser`, `YOUR_TELEGRAM_CHAT_ID` →
   `YOUR_TELEGRAM_CHAT_ID`, IP → `<VPS_IP>`, хостнеймы → `<HOSTNAME>`, город → `<CITY>`,
   почта → `user@example.com`. Технический смысл сохраняется полностью;
4. **ГЕЙТ**: ни один маркер из `agent-orchestration-toolkit/.forbidden-patterns` не должен
   совпасть, плюс проверка на форму ключей и токенов, плюс `bash -n` по всем скриптам.
   Совпало — скрипт падает и не пушит НИЧЕГО;
5. публикация — один свежий коммит поверх пустого дерева (`git init` заново): в приватной
   истории были пароли, чистка 28.07.

🔴 Гейт уже один раз сработал по делу — на слове «Загружаем» (обычный глагол, но подстрочно
содержит маркер «projectf» = имя проекта). Правильная реакция — увести глагол в синоним
правилом санитайзера, а НЕ ослабить гейт и не править приватный документ.

Отдельно живёт `agent-orchestration-toolkit/` — более старая узкая выжимка (только
`*.template.sh`, две ветки) со своим `push_public.sh`. Она не отменяется: у неё свой
remote и свой allowlist.

Из приватной истории исключены (`.gitignore`) рантайм-логи RAM-сторожа:
`claude/ram_guard_top.log`, `claude/ram_guard_v3.log`, `claude/global_ram_guard.log`,
`claude/ram_guard_protect_pids`, а также рабочий чекаут `publish/.checkout/`.

## 3. Слой совместимости СНЯТ (07.08.2026) — корневых путей больше нет

До 07.08 корень фреймворка был публичным API: на `/work/settings/<файл>.sh` и
`/work/settings/<ДОК>.md` ссылались восемь проектов, часть ссылок — рабочий код, а не
комментарии. На время переноса в корне стояли 13 симлинков на новые места. Мандат владельца
на правку чужих проектов получен 07.08 («доделай»), ссылки переписаны, **симлинки сняты**:
в корне остался только `.gitignore` и подкаталоги.

🔴 **Единственно верные пути теперь такие. Старые не работают — их нет:**

| Было (мёртвый путь) | Стало |
|---|---|
| `/work/settings/HOW_TO_RUN.md` | `/work/settings/docs/HOW_TO_RUN.md` |
| `/work/settings/HOW_TO_PUPPETEER.md` | `/work/settings/docs/HOW_TO_PUPPETEER.md` |
| `/work/settings/HOW_TO_LAUNCH_AGENTS.md` | `/work/settings/docs/HOW_TO_LAUNCH_AGENTS.md` |
| `/work/settings/claude/HOW_TO_RUN.md` | `/work/settings/docs/HOW_TO_RUN.md` |
| `/work/settings/claude/HOW_TO_LAUNCH_AGENTS.md` | `/work/settings/docs/HOW_TO_LAUNCH_AGENTS.md` |
| `/work/settings/global_ram_guard.sh` | `/work/settings/claude/global_ram_guard.sh` |
| `/work/settings/<любой>.template.sh` | `/work/settings/claude/<любой>.template.sh` |

Переписано 663 ссылки в 407 файлах: `projectb`, `projectc`, `shop`, `projecth`, `projecti`,
`projectj`, `projecte`, `claster`, `projecta`, `test_disaine` и `/work/chain_master_tonight.sh`.
Не трогали намеренно: `*.log`, каталоги `_backup_*`/`.backups/` и историческую переписку
(`/work/claude_log/claude_dialog_history.txt`, транскрипты сессий) — это архив, он ничего
не открывает по этим путям.

🔴 **Урок порядка, который повторять**: сначала ссылки → потом факт (`grep` даёт ноль,
`bash -n` чист, живые pid'ы на месте) → и только потом снятие симлинков. Обратный порядок
роняет живую волну в момент переноса.

## 4. Живое: что нельзя ломать

* RAM-сторож v3 — демон от root, поднимается из root-crontab (`@reboot` + `*/2`),
  `/etc/wsl.conf [boot]` и `/etc/profile.d/zz-ram-guard.sh`. Все три указывают на
  `/work/settings/claude/ram_guard_v3_start.sh` — путь НЕ менялся и меняться не должен.
  Проверка: `sudo bash /work/settings/claude/ram_guard_v3.sh status` → `демон: ЖИВ pid=…`.
  🔴 От `agentuser` та же команда врёт «НЕ ЗАПУЩЕН»: `kill -0` на чужой root-pid даёт EPERM.
  Статус проверять ТОЛЬКО от root.
* Оркестраторы и супервизоры волн запускаются как `bash /work/settings/claude/claude_orchestrator.template.sh`.
  🔴 bash читает скрипт ПОРЦИЯМИ по ходу выполнения. Править работающий файл «на месте»
  (`>` в него) — гарантированная порча живой волны. Правки только через temp+rename
  (`sed -i` так и делает): работающий процесс дочитывает старый inode.
