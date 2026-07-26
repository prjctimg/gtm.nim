# LOOP.md — gtm

Nim implementation of GTM — a feature-rich terminal audio player with daemon architecture.

## Active Loops

### Daily Triage (L1 — report only)
- Cadence: 1d weekdays
- Skill: `loop-triage`
- State: STATE.md
- Phase: Report-only initially. L2 after trust established.
- Handoff: Design decisions, architectural changes, daemon modifications.

### PR Review (L2 — assisted)
- Cadence: on PR creation
- Skill: `loop-triage` + `loop-verifier`
- State: STATE.md
- Phase: Assisted — verifier runs `nim check` + tests in worktree.
- Handoff: Anything touching src/daemon.nim, ffmpeg_impl.c, or build system.

## Worktrees

- Use isolated git worktrees for any L2 code changes.
- One worktree per fix attempt; discard after verifier REJECT or escalation.

## Budget & Observability

- Token caps: `loop-budget.md`
- Run history: `loop-run-log.md`
- Kill switch: `loop-pause-all` label in STATE.md

## Safety

- Never auto-merge changes to `src/daemon.nim` or `ffmpeg_impl.c`.
- All Nim changes must pass `nim check` before merge.
- C changes require manual review (ffmpeg_impl.c is performance-critical).
