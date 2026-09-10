# Agent Orchestration Framework

A complete, battle-tested Bash framework for running **long, unattended waves of AI coding
agents** (Claude Code and Codex) on a single Linux/WSL box — orchestrators, supervisors,
watchdogs, sequential queues, waiters, and a RAM guard that keeps a 6 GiB machine from
OOM-ing itself.

This is not a toy. Every template here exists because something broke at 03:00 and the
fix had to survive the next night unattended. The docs record the failures, not just the
happy path.

---

## Layout

| Directory | Contents |
|---|---|
| `claude/` | Templates for Claude Code agents: orchestrator, supervisor, agent launcher, watchdogs, wave launcher/supervisor, sequential-queue handoffs, condition/slot waiters, RAM guard v3 |
| `codex/` | The same three-level model for Codex agents, plus the OMX autopilot |
| `docs/` | The runbooks. `HOW_TO_RUN.md` is the main one; `FRAMEWORK_LAYOUT.md` is the index; `SEQUENTIAL_ORCHESTRATORS.md`, `RAM_GUARD.md`, `GOTCHAS.md`, `STEER_AGENT.md`, `SANDBOX.md`, `HOW_TO_PUPPETEER.md`, `HOW_TO_LAUNCH_AGENTS.md`, `README.repl.md` cover the rest |
| `memory/` | The orchestrator's own long-term memory — the lessons it must not relearn |

## The three-level model

1. **Agent launcher** — hands one task to one agent with a stable preamble, owns its PID,
   captures structured output.
2. **Supervisor** — keeps that single agent alive: detects a quiet or stalled process,
   distinguishes "waiting on I/O" from "dead", waits out usage-window resets without
   burning retries, and never confuses *cannot check* with *condition not met*.
3. **Orchestrator** — discovers tasks, honours per-task resource locks and a RAM gate,
   and starts bounded parallel work in isolated tmux sessions.

Above all three sit **waves**: `wave_launcher` / `wave_supervisor` run a batch,
`queue_*_orchestrator` templates hand a machine from one project's wave to the next, and
`wait_conditions_and_launch` / `wait_slot_and_launch` hold a wave until the box is free.

## Reliability rules baked into the templates

- A report ends with **exactly one** terminal status: `SUCCESS`, `FAIL`, `BLOCKED`,
  `PARTIAL`. Completion is judged by report content, never by file existence.
- **Inability to verify a condition is not the same as the condition being false.**
  Two unreadable probes in a row → proceed, don't wait forever.
- Every waiter has a **hard deadline** after which it starts unconditionally.
- A Telegram ping is a **log line, not a plan**: at night nobody reads it, so the
  automation must act on its own.
- `tmux has-session -t =NAME` — the `=` is mandatory; prefix matching makes a watchdog
  find itself and wait forever.
- Editing a running Bash script in place corrupts it mid-flight (Bash reads scripts in
  chunks). Templates are edited via temp+rename only.

## RAM guard

`claude/ram_guard_v3.sh` is a root daemon that watches `MemAvailable`, swap, and PSI, and
kills the largest non-protected agent tree before the kernel OOM-killer takes down the
whole box. It is started idempotently from cron (`@reboot` + keepalive), `/etc/wsl.conf`
`[boot]`, and `/etc/profile.d` — see `docs/RAM_GUARD.md`.

Known trap, documented because it costs an hour every time: running
`ram_guard_v3.sh status` as a non-root user prints "not running" even when the daemon is
alive, because `kill -0` against a root PID returns `EPERM`. Check the status as root.

## Using it

Templates are parameterised by environment variables — nothing customer-specific is
hardcoded. Copy a template next to your project and pass the variables:

```bash
PROJECT_DIR=/work/myproject/orch/live \
TASKS='T01_first T02_second' \
MAX_PARALLEL=2 \
CHAT_ID=<your telegram chat id> \
bash claude/wave_launcher.template.sh
```

Read `docs/HOW_TO_RUN.md` before the first run. It is long on purpose.

## About this snapshot

This repository is a **sanitised export** of a private working framework. Project names,
usernames, hostnames, addresses, cities, domains and chat IDs have been replaced with
neutral placeholders (`projecta`…`projectj`, `agentuser`, `<VPS_IP>`, `<HOSTNAME>`,
`<CITY>`, `YOUR_TELEGRAM_CHAT_ID`). The technical content — every case study, every
gotcha, every threshold — is unchanged. Runtime logs, state files and backups are not
published.

## License

MIT — see [LICENSE](LICENSE).
