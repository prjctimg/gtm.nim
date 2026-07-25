# Phase 1: Crash Prevention Fixes

## Objective
Fix all code paths that can cause runtime crashes from out-of-bounds access,
unsafe type casts, and uncaught exceptions.

## Changes

### 1. Unsafe `DaemonClient` cast guard (`gtm.nim`)
**Bug:** `DaemonClient(state.player)` cast was used without checking
`state.player of DaemonClient` at lines 254 and 265. If the player is a
different backend type (FfmpegBackend/MixerBackend), this is undefined behavior.

**Fix:** Added `if state.player of DaemonClient:` guard before every unguarded
cast in `nextTrack()` and `prevTrack()`.

### 2. Negative `selectIndex` bounds check (`gtm.nim:180`)
**Bug:** `getCurrentTrack()` called `min(state.selectIndex, len-1)` which
returns a negative value when `selectIndex == -1`, causing out-of-bounds
array access on `libraryTracks`.

**Fix:** Changed to explicit bounds check: `if state.selectIndex >= 0 and
state.selectIndex < state.libraryTracks.len`.

### 3. Queue cursor bounds checks (`gtm.nim:1672,1896`)
**Bug:** `state.playbackQueue[state.queueCursor]` was accessed without checking
that `queueCursor` is within valid range. Same pattern at `AltD` key handler
and `D` key handler.

**Fix:** Added `state.queueCursor >= 0 and state.queueCursor < state.playbackQueue.len`
guard, plus `libIdx` range validation against `libraryTracks.len`.

### 4. Queue item library index validation (`gtm.nim:1128`)
**Bug:** In the queue overlay `D` handler, `state.libraryTracks[state.playbackQueue[qIdx]]`
was accessed without checking the library index from the queue entry.

**Fix:** Added `libIdx` range validation before array access.

### 5. Uncaught `parseInt` on user input (`gtm.nim:1374`)
**Bug:** `state.playlistInputBuffer.parseInt()` was called without try/except.
Non-numeric input would crash the TUI.

**Fix:** Wrapped in `try/except ValueError` with user notification on failure.

### 6. Daemon shuffleOrder bounds checks (`daemon.nim:371,1411`)
**Bug:** `d.playbackQueue[d.shuffleOrder[d.shuffleIndex]]` was accessed without
verifying the intermediate `shuffleOrder` value was within `playbackQueue` bounds.
Same pattern in `advanceToNextTrack()` and up-next path calculation.

**Fix:** Added intermediate `sIdx` variable with explicit range check before
indexing into `playbackQueue`.

## Testing
- `nim check src/gtm.nim` and `nim check src/daemon.nim` pass
- Manual test: navigate queue with empty library, delete from queue overlay,
  sleep timer with non-numeric input, next/prev with non-daemon backend
