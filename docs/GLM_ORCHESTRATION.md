# GLM as controller and worker

## Purpose

The GLM stack gives two equivalent entry routes:

```text
user -> Codex controller -> shared queue -> GLM workers
user -> GLM controller   -> shared queue -> GLM workers
```

Claude is not required and is not used by these scripts. Existing Claude files
remain a historical backend and a source of reliability lessons only.

## First-time preparation

1. Install the official Linux ZCode `.deb` and expose its bundled CLI through
   `glm/glm-linux-wrapper.template.sh` as `glm`, or set `GLM_BIN`.
2. Run it as a regular Linux user and authenticate the standalone CLI. A
   Windows desktop login does not authenticate the WSL user profile.
3. Run the live doctor:

```bash
bash /work/settings/common/orchestrate.template.sh doctor --live
```

The live doctor sends one no-tools prompt. It must print `Live model call: OK`.
Do not start a real queue before this gate passes.

The default provider is the personal Coding Plan
`account:zai-individual-coding-plan` (Lite/Pro/Max), not the temporary
`account:zai-start-plan` trial provider.

The interactive TUI is not required. Workers use the supported headless
`--prompt` surface and create their evidence in report files.

Headless coding uses `yolo` permission mode. Interactive `build`/`edit` modes
require a permission client; the launcher maps them to `yolo` unless
`GLM_HEADLESS_AUTO_APPROVE=0` is explicitly set.

## Project layout

```text
/work/project/
├── GOAL.md
├── tasks/T01_*.md
├── reports/report_T01_*.md
├── logs/
├── state/glm/
└── orch/
    ├── launch.json
    ├── run.json
    ├── progress.md
    └── controller_report.md
```

`launch.json` records the selected entry route. `run.json` records the process
that actually owns the lock. Reports, not process exit codes, are the terminal
task contract.

## Launch from WSL or Windows

The framework itself is Linux/Bash software. Inside WSL, call it directly:

```bash
orchestrate limits
orchestrate usage --project /work/myproject
orchestrate start --project /work/myproject --controller glm \
  --goal /work/myproject/GOAL.md
```

From Windows PowerShell or Windows Terminal, use the WSL bridge and Linux paths:

```powershell
wsl.exe -d Ubuntu-24.04 -u agentuser -- orchestrate limits

wsl.exe -d Ubuntu-24.04 -u agentuser -- orchestrate start `
  --project /work/myproject `
  --controller glm `
  --goal /work/myproject/GOAL.md
```

Launching this way does not turn the worker into a Windows process: the
orchestrator, tmux, tools, and `glm` remain native WSL processes and use the WSL
network route. `glm-win` may be kept as a diagnostic fallback, but it is not the
recommended coding backend because Windows processes have UNC and Linux-tooling
limitations.

## Controller semantics

Only one controller owns a project queue at a time:

- `glm`: GLM reads the goal, inspects the repository, writes task files, and
  operates the queue.
- `codex`: the current Codex session writes task files and starts/steers the
  queue; GLM performs task execution.
- `manual`: a human provides the task files.

Workers cannot replace the controller. The lock prevents recursive or competing
orchestration from corrupting shared state.

## Quota monitoring and admission

`common/quota_monitor.py` normalizes local provider evidence:

- authenticated ZCode Max 5-hour/weekly credit windows and reset times;
- official ZCode MCP quota plus Start Plan/promo buckets when present;
- Codex rate-limit snapshots from local session JSONL;
- 5-hour, daily, weekly, monthly, and provider-specific windows.

`common/zcode_coding_plan_quota.mjs` reads the current Linux user's encrypted
ZCode credential store, decrypts only in memory using ZCode's own local scheme,
and sends credentials only to the official Z.ai/ZCode quota endpoints. Tokens
and keys are never printed or persisted by the monitor.

```bash
bash /work/settings/common/orchestrate.template.sh limits
bash /work/settings/common/orchestrate.template.sh limits --json
bash /work/settings/common/orchestrate.template.sh usage --project /work/myproject
```

`quota-policy=warn` allows work when the snapshot is unknown or stale but still
defers a model whose known buckets have reached the reserve. `enforce` also
blocks unknown/stale snapshots. The default reserve is 15 percent.

For a Coding Plan task, admission evaluates both the 5-hour and weekly windows;
either window crossing the reserve threshold defers the task. Current server
data also exposes an independent daily built-in ZCode MCP pool. If the provider
returns a monthly MCP window, it is normalized by reset interval.

The watcher persists `/work/glm/limits/latest.json` every five minutes and can
call `NOTIFY_CMD` when status crosses 70, 85, or 95 percent.

Every completed headless turn appends its provider-reported token counters to
`logs/glm_usage.jsonl` under an exclusive file lock. `orchestrate usage` reports
requests, input/output/cache/reasoning/total tokens overall and per model. For
older runs created before the ledger existed, it falls back to parsing their
stored JSON response logs.

## Failure handling

- Quota errors wait without consuming the ordinary respawn counter.
- Missing OAuth, no selected model, and coding-plan errors become
  `STATUS: BLOCKED` instead of restart storms.
- A task has a hard runtime deadline.
- Every worker has its own provider-selection file; changing one task's model
  does not mutate the desktop default or another task.
- A resource lock prevents concurrent use of singleton infrastructure.

## Verification

```bash
bash /work/settings/tests/run_glm_tests.sh
```

The suite uses a fake GLM executable, so it verifies orchestration without
spending quota. The separate `doctor --live` is the credentialed end-to-end gate.
