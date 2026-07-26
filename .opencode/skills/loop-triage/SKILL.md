---
name: loop-triage
description: >
  Triage recent changes, CI failures, issues, and discussions for the gtm
  Nim terminal audio player. Produces a concise, actionable findings report.
user_invocable: true
---

# Loop Triage Skill — gtm

You are an expert triage agent for the GTM Nim terminal audio player. Your job is to produce a clean, prioritized list of items needing attention.

## Inputs
- Recent issues and discussions (last 24h)
- Recent commits on main (last 24–48h)
- The current STATE.md
- Build/test results (nim check, test_ipc, test_parse)

## Output Format

### 1. High-Priority Items
- Clear, one-line description
- Why it matters (impact, risk, user pain)
- Suggested next action

### 2. Watch Items
- Same format, lower urgency

### 3. Noise / Ignore
- Things looked at and decided not worth action

### 4. State Updates
- Facts the loop should remember for the next run

## Rules
- Be brutally concise
- Flag build/test failures as high-priority
- Respect existing architecture (TUI client ↔ Unix socket ↔ Daemon)
- Only put something in "High-Priority" if a reasonable engineer would want to know about it today
