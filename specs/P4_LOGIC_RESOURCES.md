# Phase 4: Logic & Resource Fixes

## Objective
Fix resource leaks, incorrect exception handling, missing persistence calls,
and redundant operations across the codebase.

## Changes

### 1. File handle leak in `saveCurrentQueue` (`gtm.nim:409-415`)
**Bug:** If `writeLine` raised an exception, `f.close()` was never called,
leaking a file descriptor.

**Fix:** Wrapped file operations in `try/finally` to ensure `f.close()` is
always called.

### 2. Bare `except:` catches `Defect` (`gtm.nim:44,58,82`, `daemon.nim:255`)
**Bug:** Bare `except:` in Nim catches all exceptions including `Defect` and
`OutOfMemoryError`, which are unrecoverable. 4 sites in gtm.nim, 1 in daemon.nim.

**Fix:** Changed all bare `except:` to `except CatchableError:` in the
project's own source files (gtm.nim and daemon.nim). The vendored/supporting
files (client.nim, ytdlp.nim, library.nim) are unchanged as they follow their
own conventions.

### 3. Missing `saveConfig()` for max downloads (`gtm.nim:769`)
**Bug:** All other `adjustSetting` cases called `saveConfig()` to persist
changes, but `scYouTube` index 2 (Max Downloads) did not. The setting was
lost on restart.

**Fix:** Added `state.saveConfig()` after the assignment.

### 4. CrashFile never closed (`daemon.nim:1071-1079`)
**Bug:** The crash log file was opened and its fd dup'd to stdout/stderr, but
the `File` handle was never closed.

**Fix:** Added `crashFile.close()` after the dup2 calls. The fd is duplicated
so closing the original is safe and prevents a leak.

### 5. Redundant `showVolumeCue()` calls (`gtm.nim:1650-1651`)
**Bug:** `adjustVolume()` internally calls `showVolumeCue()`. The callers at
CtrlU/CtrlD also called `showVolumeCue()` explicitly, resulting in double calls.

**Fix:** Removed the redundant `showVolumeCue()` calls from the callers.

## Testing
- Queue save works correctly even with read-only filesystem (exception handled)
- Config changes (theme, volume, max downloads) persist across restarts
- Volume cue overlay appears exactly once per volume change
