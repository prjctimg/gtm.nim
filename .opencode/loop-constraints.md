# Loop Constraints — gtm

> The `loop-triage` and `loop-verifier` skills read this file at the start of every run.
> Constraints here are **binding** — the agent MUST follow them.

## Push & Merge
- Never auto-merge to main without human approval
- Always create a draft PR first

## Paths
- Never edit `.git/`, `.gitignore`, or hidden config files
- Never auto-edit `vendor/`, `.nimble/`, or C source files (`ffmpeg_impl.c`)
- Never edit `*.log`, `nohup.out`, or build artifacts

## Code
- Always run `nim check` before proposing a Nim change
- Always run tests before proposing a fix: `nim r --path:src tests/test_ipc.nim` and `nim r --path:src tests/test_parse.nim`
- Never disable tests to make CI green
- Never refactor unrelated code — one fix per run
- Max 3 fix attempts per item; escalate after

## Communication
- Always tell the user what you're about to do before doing it
- Never close an issue or PR without approval

## Budget
- If token spend hits 80% of daily cap, switch to report-only
- If loop-pause-all is active, exit immediately
