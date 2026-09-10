# Codex autonomous tmux runners

## OMX Autopilot detached profile

Для автономного ИИ-оркестратора OMX, который сам проходит planning → execution → code review →
UltraQA, используйте отдельный профиль:

```text
/work/settings/codex/OMX_AUTONOMOUS_ORCHESTRATOR.md
/work/settings/codex/omx_autopilot_launcher.template.sh
/work/settings/codex/omx_autopilot_status.template.sh
/work/settings/codex/omx_autonomous.config.template.toml
/work/settings/codex/AGENTS.autonomous.md
/work/settings/codex/hooks.autonomous.json
/work/settings/codex/autopilot.prompt.template.md
```

Это другой уровень, чем очередь task-файлов ниже: OMX Autopilot является ИИ-лидером и может
создавать план, делегировать native subagents, исправлять результаты review и продолжать до
финальных гейтов. Но detached launcher — только транспорт запуска: workflow выбирает prompt.
Для уже утверждённого продолжения используйте execution/`$ultragoal`, а не запускайте строгий
`$autopilot` заново. Иначе при изменении плана detached run может корректно остановиться на
обязательном official Ralplan receipt, которого эта поверхность не умеет выдать. Подробная
матрица выбора и двухстадийный запуск описаны в
[`OMX_AUTONOMOUS_ORCHESTRATOR.md`](OMX_AUTONOMOUS_ORCHESTRATOR.md). Профиль не содержит
credentials или runtime state.

This directory contains templates for running Codex agents autonomously from
tmux. The pattern mirrors the existing Claude orchestration style, but uses
`codex exec` and Codex-native completion signals instead of Claude jsonl files.

## What this provides

- A per-task Codex launcher.
- A per-task supervisor with respawn on death or stalled output, plus pause/resume checkpoints.
- A queue orchestrator that runs task files through tmux sessions.
- A task template with a required `STATUS:` report contract.
- A reproducible OMX native-hook compatibility overlay for flattened collaboration transports.

## Conductor recovery overlay

Some Codex native surfaces report collaboration tools without the namespace
separator, for example `collaborationspawn_agent` instead of
`collaboration.spawn_agent`. An active Conductor correctly fails closed on an
unknown mutation transport, but older OMX builds therefore block legitimate
delegation. Install the maintained compatibility overlay after `omx setup`:

```bash
bash /work/settings/codex/install_omx_conductor_recovery.sh install
bash /work/settings/codex/install_omx_conductor_recovery.sh check
```

The installer locates the global `oh-my-codex` package through `npm root -g`,
patches both `src/scripts/codex-native-hook.ts` and the runtime-loaded
`dist/scripts/codex-native-hook.js`, and creates a timestamped backup below
`<oh-my-codex>/.omx-backups/conductor-recovery-<UTC timestamp>/`. It is
idempotent and refuses to patch when its exact upstream anchors are absent.
Rerun it after an OMX upgrade or `omx setup`; use `check` in provisioning to
detect an overwritten overlay. To roll back, copy the two files from the
reported backup directory to their original relative paths.

The normalized names cover spawn, close, send, follow-up, wait, interrupt, and
list operations. Dotted/upstream spellings remain unchanged. Test the overlay
and supervisor behavior deterministically with:

```bash
bash /work/settings/codex/tests/test_conductor_recovery.sh
```

## Intentional pause/resume handling

`codex_supervisor.template.sh` observes Linux process state `T`/`t` as an
intentional external pause. On the first observation it atomically writes
`codex/state/<TASK>.supervisor-state.json` with `status: paused` and logs
`PAUSED`. While paused, stall and wall-clock recycling are suspended. After an
external `SIGCONT`, it logs `RESUMED`, updates the same checkpoint, excludes
the paused interval from runtime accounting, and starts a fresh stall grace
window.

The supervisor never sends `SIGSTOP` or `SIGCONT`. The RAM guard remains
authoritative: its pause/resume decisions are intentional and must not be
disabled, bypassed, masked, or reconfigured from Codex recovery code. Because
`SIGSTOP` cannot be trapped, transition timestamps are observation times with
up to one `POLL` interval of delay. Keep the supervisor outside the stopped
worker process group so it can observe and checkpoint the transition.

Recovery runbook:

1. Inspect the checkpoint and supervisor log; do not treat `status: paused` as a crash.
2. Let the RAM guard resume the worker. Do not send a competing `SIGCONT` from the supervisor.
3. Confirm a `RESUMED` log entry and `status: running` checkpoint before diagnosing a real stall.
4. If delegation is denied as an unknown transport, run the overlay `check`, then `install` if needed.

## Directory layout in a project

Recommended project-local layout:

```text
/work/<project>/
  codex/
    tasks/
      T-EXAMPLE.md
    reports/
      report_T-EXAMPLE.md
    logs/
      T-EXAMPLE.log
      T-EXAMPLE_supervisor.log
    state/
      T-EXAMPLE.pid
      T-EXAMPLE.last_message.txt
      T-EXAMPLE.lock
      progress.md
```

The files in `/work/settings/codex` are templates. Keep them here as the shared
source of truth, then either copy them into a project or invoke them directly
with environment variables.

## Quick start

Create the project folders:

```bash
mkdir -p /work/projectb/codex/{tasks,reports,logs,state}
cp /work/settings/codex/task.template.md /work/projectb/codex/tasks/T-EXAMPLE.md
```

Run a single task through the queue orchestrator:

```bash
tmux new-session -d -s lc_codex_orch -c /work/projectb \
  "PROJECT_DIR=/work/projectb TASKS='T-EXAMPLE' MAX_PARALLEL=1 bash /work/settings/codex/codex_orchestrator.template.sh"
```

Monitor:

```bash
tail -f /work/projectb/codex/logs/codex_orchestrator.log
tail -f /work/projectb/codex/logs/T-EXAMPLE_supervisor.log
tail -f /work/projectb/codex/logs/T-EXAMPLE.log
cat /work/projectb/codex/reports/report_T-EXAMPLE.md
```

Stop a queue:

```bash
tmux kill-session -t =lc_codex_orch
```

Stop one task supervisor:

```bash
tmux kill-session -t =codex_T-EXAMPLE_sup
```

## Required task contract

Every task must write a report:

```text
codex/reports/report_<TASK>.md
```

The final line must be one of:

```text
STATUS: SUCCESS
STATUS: FAIL
STATUS: BLOCKED
STATUS: PARTIAL
```

The supervisor treats file existence as "finished" only after reading that
status line. `SUCCESS` exits 0. `FAIL`, `BLOCKED`, `PARTIAL`, or missing status
exit non-zero so the queue can report honestly.

## Resource locks

Task files may declare an advisory lock:

```text
Resource-Lock: vnc_1c
```

The queue will not run two tasks with the same non-empty lock at once. Use this
for singleton resources such as 1C, VNC displays, SOCKS ports, or prod deploys.

For 1C tasks, always use:

```text
Resource-Lock: vnc_1c
```

and run with `MAX_PARALLEL=1` unless you have explicitly audited every resource
used by the tasks.

## VNC/CDP UI-driving protocol

For GUI tasks that use `/work/remote_tools`, task files should require this loop:

1. Take a screenshot before any risky click, field edit, save, post, delete,
   or inventory/accounting action.
2. Use `/work/remote_tools/vnc.sh` primitives first: `find`, `map`, `bbox`,
   `cclick`, `mclick`, `tap`, `keytype`, `shot`, and `text`.
3. After every click or field edit, verify the result with a fresh screenshot
   and page text. If the click missed, do not continue from the wrong state:
   recalculate coordinates/selectors and click again.
4. Prefer viewport coordinates from `map`/`bbox` over screenshot coordinates.
   If screenshot coordinates are used, account for browser chrome/viewport
   offset and verify immediately.
5. If `/work/remote_tools` itself appears to misbehave, debug it as part of the
   task. Before editing `vnc.sh`, `cdp.mjs`, or coordinate memory, copy the
   original into the task backup directory and document the change.
6. Never save/post/delete after a suspected mis-click until the visible state
   is confirmed by screenshot.

## Codex defaults

Defaults used by the launcher:

```bash
CODEX_SANDBOX=workspace-write
CODEX_MODEL=
CODEX_EXTRA_ARGS=
```

Override as needed:

```bash
CODEX_MODEL=gpt-5.5 CODEX_SANDBOX=workspace-write \
  PROJECT_DIR=/work/projectb TASKS='T-A T-B' MAX_PARALLEL=1 \
  bash /work/settings/codex/codex_orchestrator.template.sh
```

For no-prompt full-access task agents:

```bash
CODEX_SANDBOX=danger-full-access \
  PROJECT_DIR=/work/projectb TASKS='T-A' MAX_PARALLEL=1 \
  bash /work/settings/codex/codex_orchestrator.template.sh
```

For tasks that must not stop at a partial result, make selected statuses
retryable:

```bash
RETRY_STATUSES=PARTIAL MAX_RESPAWN=20 \
  CODEX_SANDBOX=danger-full-access \
  PROJECT_DIR=/work/projectb TASKS='T-A' MAX_PARALLEL=1 \
  bash /work/settings/codex/codex_orchestrator.template.sh
```

For long-running tasks, recycle the worker before or at a wall-clock limit and
continue from the same task file:

```bash
MAX_RUNTIME_SECONDS=18000 RUNTIME_RESTART_WAIT_SECONDS=300 \
  CODEX_SANDBOX=danger-full-access \
  PROJECT_DIR=/work/projectb TASKS='T-A' MAX_PARALLEL=1 \
  bash /work/settings/codex/codex_orchestrator.template.sh
```

If the agent exits without a report and the log looks like a rate/usage/session
limit, the supervisor waits `RATE_LIMIT_WAIT_SECONDS` before relaunching
**without consuming `MAX_RESPAWN`**. Default is `18000` seconds, i.e. five hours.
`RATE_LIMIT_RE` intentionally covers formats such as `session limit`,
`You've hit your ... limit`, `resets 7:30pm`, `429`, `overloaded`, and
`please try again`; `RATE_LIMIT_MAX_WAITS` defaults to `24`.

For long autonomous queues that must survive the 5-hour window, use:

```bash
RATE_LIMIT_WAIT_SECONDS=18000 RATE_LIMIT_MAX_WAITS=24 \
  MAX_RUNTIME_SECONDS=18000 RUNTIME_RESTART_WAIT_SECONDS=300 \
  CODEX_SANDBOX=danger-full-access CODEX_APPROVAL=never \
  PROJECT_DIR=/work/projectb TASKS='T-A' MAX_PARALLEL=1 \
  bash /work/settings/codex/codex_orchestrator.template.sh
```

Project-specific wrappers may provide a shorter command while still using these
shared templates underneath. Example for `/work/projectb` only:

```bash
RETRY_STATUSES=PARTIAL MAX_RESPAWN=20 MAX_RUNTIME_SECONDS=18000 \
  RUNTIME_RESTART_WAIT_SECONDS=300 \
  CODEX_SANDBOX=danger-full-access CODEX_APPROVAL=never \
  /work/projectb/codex/launch.sh T-1C-RU-WAREHOUSE-POSTING-FIX
```

For another project, keep the same launcher pattern but replace the project
path and task id with that project's local wrapper and task file.

Implementation detail: `codex exec` does not support the interactive CLI flag
`--ask-for-approval`. When `CODEX_SANDBOX=danger-full-access`, the launcher uses
`--dangerously-bypass-approvals-and-sandbox`. For routine repo work, prefer
`workspace-write`; it is non-interactive but still sandboxed.


## Sequential 5-hour-resilient queues

For a chain of stages/orchestrators, wrap them with
`codex_sequential_queue.template.sh`. It runs stages one by one and handles
Codex/LLM rate/session-limit markers the same way as the task supervisor: wait
`RATE_LIMIT_WAIT_SECONDS` (default `18000`, five hours), then retry without
consuming normal stage retries.

```bash
PROJECT_DIR=/work/<project> \
STAGES='04 05 06 07 08 09 10 11' \
STAGE_CMD_TEMPLATE='bash /work/<project>/codex/run_stage.sh {stage}' \
RATE_LIMIT_WAIT_SECONDS=18000 RATE_LIMIT_MAX_WAITS=24 \
bash /work/settings/codex/codex_sequential_queue.template.sh
```

Each stage must be independently resumable or write a new `run_id`, and should
produce `state.json`, `summary.json`, and a log. The queue only decides when to
start/retry the next stage; it must not be the only source of truth for work
completion.

## Important difference from Claude runners

Do not reuse Claude jsonl-based stall checks for Codex. These templates monitor
the `codex exec --json` output log and the required report file instead.

Do not use `/work/settings/claude/global_ram_guard.sh` blindly for Codex queues. That
guard may `SIGSTOP` Codex/OMX processes. Prefer queue-level RAM gating: do not
start new tasks when memory is low, and keep singleton UI tasks sequential.
