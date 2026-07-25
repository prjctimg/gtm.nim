# Phase 3: Memory Safety Fixes

## Objective
Fix memory safety issues in the C audio backend: unchecked `realloc` failures,
metadata buffer null-termination, and socket FD leaks.

## Changes

### 1. Unchecked `realloc` failures (`ffmpeg_impl.c:308,631,727,820`)
**Bug:** Four `realloc` calls did not check for NULL return. If allocation fails,
the old pointer is leaked and subsequent writes dereference NULL.

**Fix:** Each `realloc` now uses a temporary pointer to check for NULL before
overwriting the original. On failure, the old buffer is freed, the pointer is
NULLed, and control jumps to the cleanup label (`decode_done` or `mixer_done`).

Sites fixed:
- `decode_thread`: `conv_buf` realloc → jumps to `decode_done`
- `decode_into_buf`: `*buf` realloc → returns 0 (error)
- `mixer_thread` crossfade: `mixbuf` realloc → jumps to `mixer_done`
- `mixer_thread` priming: `prime_buf` realloc → jumps to `mixer_done`

### 2. Metadata buffer null-termination (`ffmpeg_impl.c:149-171`)
**Bug:** `strncpy(ctx->title, t->value, sizeof(ctx->title)-1)` does not
guarantee null-termination when the source is >= 255 chars. On subsequent file
loads, `ctx->title[0] = '\0'` only clears byte 0, leaving stale data in bytes
1-255 that could cause out-of-bounds reads when printing.

**Fix:** Added explicit `ctx->title[sizeof(ctx->title)-1] = '\0'` after each
`strncpy` call (title, artist, album). Also added `ctx->title[0] = '\0'` etc.
at the start of `extract_metadata` to clear old values before writing.

### 3. Socket FD leak on connect failure (`client.nim:52-66`)
**Bug:** If `posix.socket()` succeeds but `connectUnix()` fails, the except
handler set `cli.sock = nil` without closing the FD, leaking it.

**Fix:** Added `cli.sock.close()` in the except handler before setting nil.

## Testing
- Malformed metadata strings (>= 255 chars) are properly truncated and
  null-terminated
- Connection failures do not leak file descriptors
- OOM conditions during decode are handled gracefully (no NULL dereference)
