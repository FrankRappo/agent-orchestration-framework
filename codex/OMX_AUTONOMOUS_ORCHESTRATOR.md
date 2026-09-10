# OMX Autopilot: автономный запуск из WSL

Каталог содержит обезличенный воспроизводимый профиль автономного OMX/Codex-оркестратора.
Проектный подробный пример должен храниться в документации самого проекта; этот общий профиль не содержит аутентификацию,
секреты, SSH-ключи или состояние конкретной сессии.

## Файлы

- `omx_autopilot_launcher.template.sh` — detached launcher (`nohup + setsid`).
- `omx_autopilot_status.template.sh` — проверка PID, JSONL и metadata.
- `omx_autonomous.config.template.toml` — безопасный фрагмент Codex-конфигурации.
- `AGENTS.autonomous.md` — снимок рабочего автономного контракта агентов.
- `hooks.autonomous.json` — снимок OMX native hooks без секретов.
- `autopilot.prompt.template.md` — минимальный prompt-контракт Autopilot.
- `omx_autonomous.sha256` — контрольные суммы этого профиля.

Проектный подробный пример должен храниться в документации самого проекта; общий публичный
профиль намеренно не содержит имён проектов, клиентов, хостов или дат конкретных запусков.

## Установка OMX/Codex

```bash
omx setup
omx doctor
codex login status
```

`codex login` выполняется отдельно. Никогда не копируйте сюда `~/.codex/auth.json`.

## Подготовка проекта

```bash
mkdir -p /work/<project>/.omx/{context,prompts,logs,run}
cp /work/settings/codex/autopilot.prompt.template.md \
  /work/<project>/.omx/prompts/<task>-autopilot.md
```

Заполните prompt конкретными целями, проверками, ограничениями и stop condition. Секреты в prompt
не помещать.

## Сначала выбрать workflow, затем launcher

`omx_autopilot_launcher.template.sh` — detached-транспорт (`nohup + setsid + omx exec`), а не
разрешение всегда активировать `$autopilot`. Workflow задаёт содержимое `PROMPT_FILE`.

| Состояние задачи | Правильный workflow в prompt | Почему |
|---|---|---|
| Требования или архитектура ещё не определены, а поверхность умеет выдавать официальный Ralplan receipt | `$autopilot` | Нужен полный `deep-interview -> ralplan -> ultragoal -> code-review -> ultraqa` |
| План и test spec уже утверждены, нужно продолжить реализацию/проверку | `$ultragoal` или bounded execution lane | Не надо повторно входить в Ralplan и создавать новый authority gate |
| Нужна одна ограниченная реализация без изменения утверждённой архитектуры | direct/executor task | Autopilot добавит лишний lifecycle |
| Во время execution выяснилось, что утверждённый план надо существенно менять | Остановить execution, выпустить новый PRD/test spec, получить отдельную авторизацию, затем запустить новый execution-run | Detached local reviews не заменяют официальный receipt |

### Важное ограничение strict Autopilot

Текущий строгий `$autopilot` не разрешает переход `ralplan -> ultragoal` только на основании
локальных Planner/Architect/Critic сообщений или файлов. Нужен официальный, не создаваемый самим
пользователем/агентом host receipt и документированный verifier. Перед обещанием полностью
автономного planning-to-execution запуска проверьте **ту же поверхность**, из которой будет идти
run:

```bash
omx ralplan preflight --json
```

Если результат содержит `unsupported_documented_leader_proof`, эта поверхность не может
авторизовать strict Ralplan handoff. Нельзя объявлять локальные `APPROVE/CLEAR` эквивалентом
receipt и нельзя его фабриковать.

Правильный fallback — двухстадийный:

1. planning-run публикует PRD, test spec, reviews, точные SHA-256 и терминальный checkpoint;
2. владелец или поддерживаемая host-поверхность явно авторизует эти exact hashes;
3. новый detached prompt запускает `$ultragoal`/execution по утверждённым hashes и не повторяет
   Ralplan, пока evidence не докажет, что план снова надо менять.

### Инцидент, который нельзя повторять

В projectk-run 2026-08-19 уже утверждённое продолжение ошибочно запустили через strict
`$autopilot`. После успешного UltraQA агент обнаружил необходимость нового component-split
плана, получил локальные Architect `APPROVE/CLEAR` и Critic `APPROVE`, но detached surface не
имела official receipt verifier. Safety-hook правильно запретил implementation, и run завершился
`BLOCKED` задолго до дедлайна. Это был workflow-routing blocker, а не ошибка модели, датасета или
training runtime.

Вывод: для approved continuation запускать execution lane; для настоящего replanning заранее
проверять receipt surface либо планировать отдельный approval -> execution handoff.

## Запуск в sandbox

```bash
PROJECT_DIR=/work/<project> \
PROMPT_FILE=/work/<project>/.omx/prompts/<task>-autopilot.md \
RUN_NAME=<task>-autopilot \
OMX_REASONING=high \
bash /work/settings/codex/omx_autopilot_launcher.template.sh
```

## Запуск с полным доступом

Только если задача действительно требует SSH, удалённого деплоя или записи за пределами project
root и prompt содержит жёсткие safety boundaries:

```bash
PROJECT_DIR=/work/<project> \
PROMPT_FILE=/work/<project>/.omx/prompts/<task>-autopilot.md \
RUN_NAME=<task>-autopilot \
OMX_REASONING=xhigh \
OMX_FULL_ACCESS=1 \
OMX_ADD_DIR=/work \
bash /work/settings/codex/omx_autopilot_launcher.template.sh
```

`OMX_FULL_ACCESS=1` преобразуется в `--dangerously-bypass-approvals-and-sandbox`. Без этого
переменного шаблон использует `--sandbox workspace-write`.

## Изолированный runtime root

Не наследуйте `OMX_ROOT`/session pointer из другой Codex/OMX-сессии и не полагайтесь на старый
project-local `.omx/state/session.json`. Иначе новый detached run может завершиться при startup с
`session_pointer_unusable` или привязаться к чужому runtime state.

Из обычного shell создавайте новый runtime root на каждый запуск:

```bash
RUN_NAME=<task>-execution
RUNTIME_ROOT="$HOME/.omx-runs/${RUN_NAME}-$(date -u +%Y%m%dT%H%M%SZ)"

env -u OMX_SESSION_ID -u OMX_ACTIVE_SESSION_ID \
  -u OMX_REPO_ROOT -u OMX_WORKTREE_ROOT -u OMX_SOURCE_CWD -u OMX_STARTUP_CWD \
  OMX_ROOT="$RUNTIME_ROOT" \
  PROJECT_DIR=/work/<project> \
  PROMPT_FILE=/work/<project>/.omx/prompts/<task>-execution.md \
  RUN_NAME="$RUN_NAME" \
  OMX_REASONING=xhigh \
  OMX_FULL_ACCESS=1 \
  OMX_ADD_DIR=/work \
  bash /work/settings/codex/omx_autopilot_launcher.template.sh
```

Проверить после старта:

1. PID и SID живы, SID совпадает с PID detached leader;
2. JSONL содержит `thread.started` и первый осмысленный agent message;
3. новый `session.json` лежит под выбранным `RUNTIME_ROOT`, а не в runtime другой сессии;
4. prompt сообщает правильный workflow (`$ultragoal` для approved continuation);
5. нет второго orchestrator/trainer на тот же output root или resource lock.

## Настройки

| Переменная | Значение по умолчанию | Назначение |
|---|---:|---|
| `PROJECT_DIR` | обязательно | корень проекта |
| `PROMPT_FILE` | обязательно | prompt через stdin |
| `RUN_NAME` | `omx-autopilot` | безопасный префикс логов |
| `OMX_REASONING` | `high` | `low`, `medium`, `high`, `xhigh` |
| `OMX_FULL_ACCESS` | `0` | полный доступ только при `1` |
| `OMX_ADD_DIR` | пусто | дополнительный доступный каталог |
| `OMX_MODEL` | пусто | пусто = модель из актуального Codex config |
| `OMX_LOG_DIR` | `$PROJECT_DIR/.omx/logs` | JSONL/final output |
| `OMX_RUN_DIR` | `$PROJECT_DIR/.omx/run` | PID/metadata |

Не фиксируйте модель в шаблонах без необходимости: актуальная модель выбирается из установленного
Codex/OMX-профиля. Reasoning задаётся отдельно.

## Статус

```bash
PROJECT_DIR=/work/<project> \
bash /work/settings/codex/omx_autopilot_status.template.sh
```

Для конкретного metadata-файла:

```bash
META=/work/<project>/.omx/run/<run>.meta.json \
bash /work/settings/codex/omx_autopilot_status.template.sh
```

## Что переживает отключение

- Закрытие терминала/SSH/Codex UI: да.
- Завершение родительского shell: да, благодаря `nohup + setsid`.
- Выключение компьютера или `wsl --shutdown`: нет.
- Пропадание OpenAI-сети/аутентификации/квоты: агент может остановиться или ждать.
- Отдельно detached удалённые скрипты: могут продолжить работу независимо.

## Безопасность

- Не копировать credentials и runtime-state.
- Не считать PID доказательством успеха: проверять state, отчёты и hashes.
- Не запускать два оркестратора на один output root без явного locking.
- Не делать `git push`, production deploy или полное обучение без явного разрешения/gate.
- Данные uncertainty/conflict не превращать в clean positives.
- Для остановки использовать точный PID, не широкий `pkill -f`.
