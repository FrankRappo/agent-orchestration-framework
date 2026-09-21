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

- ZCode plan/token buckets and official MCP usage from desktop logs;
- Codex rate-limit snapshots from local session JSONL;
- 5-hour, daily, weekly, monthly, and provider-specific windows.

It does not read credential files.

```bash
bash /work/settings/common/orchestrate.template.sh limits
bash /work/settings/common/orchestrate.template.sh limits --json
```

`quota-policy=warn` allows work when the snapshot is unknown or stale but still
defers a model whose known buckets have reached the reserve. `enforce` also
blocks unknown/stale snapshots. The default reserve is 15 percent.

The watcher persists `/work/glm/limits/latest.json` every five minutes and can
call `NOTIFY_CMD` when status crosses 70, 85, or 95 percent.

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
