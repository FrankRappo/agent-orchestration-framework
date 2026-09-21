# T<NN> — <short task name>

Complexity: medium
Model: auto
Mode: build
Resource-Lock: none
No-Respawn: false
Max-Respawn: 3
Max-Runtime-Seconds: 7200

## Objective

State one observable outcome.

## Read first

- `<path>`

## Scope

- Allowed: `<paths>`
- Forbidden: unrelated files, destructive git commands, push, deploy.

## Work

1. `<step>`
2. `<step>`

## Acceptance gates

- [ ] `<testable result>`
- [ ] Targeted tests pass.

## Verification commands

```bash
<targeted-test>
<lint-or-typecheck>
```

## Required report

Write `reports/report_T<NN>.md`. Its final line must be exactly one of:

```text
STATUS: SUCCESS
STATUS: FAIL
STATUS: BLOCKED
STATUS: PARTIAL
```
