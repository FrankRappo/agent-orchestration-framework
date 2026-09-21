# GLM/ZCode orchestration backend

This backend runs headless GLM workers under tmux. It has no Claude runtime
dependency. Codex, GLM itself, or a human can own the queue; ownership is
recorded and protected by one controller lock.

## Components

- `glm_controller.template.sh` — asks GLM to decompose one goal into `T*.md`
  task files, then starts the queue.
- `glm_orchestrator.template.sh` — dynamic task discovery, bounded parallelism,
  resource locks, model routing, quota admission, terminal reports.
- `glm_supervisor.template.sh` — retries, runtime deadline, quota waits,
  authentication/configuration quarantine.
- `glm_agent_launcher.template.sh` — isolated model selection and one headless
  `glm --prompt` call.
- `task_metadata.py` and `model_policy.json` — validated per-task routing.
- `glm_runtime_doctor.template.sh` — static and optional live model check.

Use the common entrypoint rather than calling these scripts directly:

```bash
bash /work/settings/common/orchestrate.template.sh doctor --live
bash /work/settings/common/orchestrate.template.sh limits
```

If the live doctor asks for authentication, complete the standalone CLI OAuth
once. Desktop login and CLI login can be separate:

```bash
glm login
```

The orchestrator never reads or copies the credential file.

## GLM controls the run

```bash
cat > /work/myproject/GOAL.md <<'EOF'
Implement the requested feature, add regression tests, and verify the build.
EOF

bash /work/settings/common/orchestrate.template.sh start \
  --project /work/myproject \
  --controller glm \
  --goal /work/myproject/GOAL.md \
  --max-parallel 2 \
  --quota-policy enforce
```

GLM first creates bounded `tasks/T*.md` files, then the same queue starts GLM
workers for them.

## Codex controls the run

Codex writes the tasks from `task.template.md`, then starts the queue with its
ownership recorded:

```bash
bash /work/settings/common/orchestrate.template.sh start \
  --project /work/myproject \
  --controller codex \
  --max-parallel 2 \
  --quota-policy enforce
```

`controller=codex` does not launch another Codex process. It means the current
Codex session owns planning, task authoring, steering, review, and integration;
GLM sessions execute the task files.

## Task routing

Supported headers:

```text
Complexity: low | medium | high | critical
Model: auto | GLM-5.3 | GLM-5.3-Flash
Mode: build | edit | plan | yolo
Resource-Lock: none | <name>
No-Respawn: true | false
Max-Respawn: 3
Max-Runtime-Seconds: 7200
```

Default policy:

| Complexity | Model |
| --- | --- |
| low | GLM-5.3-Flash |
| medium | GLM-5.3 |
| high | GLM-5.3 |
| critical | GLM-5.3 |

Critical work still requires independent review by the owning Codex session or
another explicitly chosen reviewer. Model price alone is not a verification
strategy.

## Runtime status

```bash
bash /work/settings/common/orchestrate.template.sh status --project /work/myproject
bash /work/settings/common/orchestrate.template.sh attach --project /work/myproject
bash /work/settings/common/orchestrate.template.sh stop --project /work/myproject
```

The queue uses exact tmux names and a `flock` controller lock. A second Codex,
GLM, or manual controller cannot silently take ownership of the same state
directory.
