# Phase 2: Thread Safety Fixes

## Objective
Fix all data races between the decode/mixer threads and the main thread in the
C audio backend. The existing `pthread_mutex_t` in `FfmpegAudioCtx` was declared
and initialized but never actually used.

## Changes

### 1. PCM ring buffer synchronization (`ffmpeg_impl.c`)
**Bug:** `pcm_wp`/`pcm_rp` were `volatile int` without proper memory barriers.
While this works on x86-64 due to strong memory ordering, it is undefined
behavior on ARM and with aggressive compiler optimization.

**Fix:** Wrapped ring buffer index reads/writes in the existing `ctx->mutex` for
both `FfmpegAudioCtx` and `MixerCtx` ring buffers.

### 2. Seek TOCTOU race (`ffmpeg_impl.c`)
**Bug:** `ffmpeg_audio_seek` wrote `seek_target` then `seek_pending=1` without
atomicity. The decode thread could read a stale `seek_target`.

**Fix:** Protected `seek_target` and `seek_pending` writes with `ctx->mutex` in
both `ffmpeg_audio_seek` and the decode thread's seek handling.

### 3. Volume data race (`ffmpeg_impl.c`)
**Bug:** `volume` was written by the main thread and read by the decode thread
without synchronization. On 32-bit platforms, a `float` write can be torn.

**Fix:** Protected `volume` reads/writes with `ctx->mutex` in both
`ffmpeg_audio_set_volume` and the decode thread's volume application.

### 4. current_time data race (`ffmpeg_impl.c`)
**Bug:** `current_time` was written by the decode thread and read by the main
thread via `ffmpeg_audio_get_time` without synchronization.

**Fix:** Protected with `ctx->mutex` in decode thread writes, `get_time` reads,
and `stop` resets. Same pattern applied to `MixerCtx.current_time`.

### 5. EQ state data race (`ffmpeg_impl.c`)
**Bug:** `eq_set_band`/`eq_rebuild` modified EQ filter coefficients from the
main thread while `eq_apply` read them in the decode thread. The biquad filter
has multiple state variables that can be partially overwritten.

**Fix:** Added `pthread_mutex_t mutex` to the `Equalizer` struct. Protected
`eq_set_band` (write path) and `eq_apply` (read path) with this mutex.

### 6. Crossfade state data race (`ffmpeg_impl.c`)
**Bug:** `crossfade_active`, `crossfade_total_frames`, `crossfade_frames_remaining`
were set from the main thread in `ffmpeg_mixer_start_crossfade` while the mixer
thread read them. No synchronization.

**Fix:** Added `pthread_mutex_t mutex` to `MixerCtx`. Protected crossfade state
writes in `start_crossfade`, `stop`, `load_master`, and the mixer thread's
crossfade completion/reset paths.

### 7. Hardcoded sample rate (`audio.nim:292`)
**Bug:** Crossfade frame calculation used hardcoded `44100` Hz. 48kHz/96kHz
streams would have wrong crossfade duration.

**Fix:** Added `ffmpeg_mixer_get_sample_rate()` C function that reads
`mx->master->sample_rate`. Changed `startCrossfade` to query actual rate.

## Testing
- `nim check src/audio.nim` passes
- Crossfade timing verified with 44.1kHz and 48kHz test files
- EQ changes applied during playback produce correct output
- Volume changes during playback are smooth (no glitches)
