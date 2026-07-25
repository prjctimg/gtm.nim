# Phase 5: Code Quality Fixes

## Objective
Remove dead code, eliminate duplication, fix misleading patterns, and add
defensive bounds on IPC buffer growth.

## Changes

### 1. Dead code removal — `when false` blocks (`gtm.nim`, `daemon.nim`)
**Bug:** Two `when false` blocks contained unreachable procs and orphaned
statements with broken indentation (daemon.nim lines outside proc body).

**Fix:** Removed both blocks entirely:
- `gtm.nim`: `getNextTrackInfo` proc (was never compiled)
- `daemon.nim`: `cleanupClientState` proc + 6 orphaned statements

### 2. Duplicate `toggleSelect` logic (`gtm.nim:1933-1940`)
**Bug:** The `V` key handler duplicated the logic of `toggleSelect()` inline
instead of calling it. If `toggleSelect` is ever changed, the `V` handler
won't pick up the change.

**Fix:** Replaced the inline logic with `state.toggleSelect()`.

### 3. Misleading `elif true` (`gtm.nim:1248`)
**Bug:** `elif true:` is always true and acts as `else:`. This is confusing.

**Fix:** Changed to plain `else:`.

### 4. Unbounded IPC buffer growth (`client.nim:168`, `daemon.nim:1222`)
**Bug:** No size limit on accumulated IPC data. A misbehaving peer could send
gigabytes without newlines, causing OOM in either process.

**Fix:** Added 16MB buffer limit. If exceeded, the connection is disconnected
and the error is logged (daemon) or returned to the caller (client).

## Testing
- Daemon disconnects client that sends oversized messages
- Client handles daemon buffer overflow gracefully
- `V` key still toggles select mode correctly
- Command palette still shows all results when query is empty
