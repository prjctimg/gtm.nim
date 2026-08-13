# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

Licensed under the GNU General Public License v3.0: see [LICENSE](LICENSE) for details.

## [Unreleased]

## [0.5.0]: 2026-08-06

### Added
- Reverb control: `set_reverb` command, `ffmpeg_mixer_set_reverb` C bridge, per-mixer reverb state persisted
- Loudness normalization: `set_loudness_mode` (off/track/album/auto), `set_pre_gain`, `scan_loudness` command with background ebur128 scan (ffmpeg), `loudness` table (track/album gain, true peak)
- Gapless playback: `set_gapless` command, FFmpeg mixer gapless promotion via `ffmpeg_mixer_gapless_promoted`/`ffmpeg_mixer_clear_gapless_promoted`, daemon-side next-track preload and gapless bookkeeping
- Dynamic mode: `set_dynamic_mode` command
- Last.fm scrobbling: `set_scrobble` command, `submitScrobble` curl-based scrobble submission on track progress
- Library organization: `organize_library` command with dry-run support
- Cover art: `get_cover_art` command (Deezer search → base64 PNG), `covers` table, background cover sync (`sync_covers` + progress/done events)
- Lyrics: `get_lyrics` command (lrclib.net → LRC), `lyrics` table, background lyrics sync (`sync_lyrics` + progress/done events)
- Client wrappers in `client.nim` for all new commands
- Config persistence for new audio settings in `state.nim`

### Fixed
- `createPlaylist` always returned 0: `sqlite3_step` returns `SQLITE_DONE` (101) for INSERTs, not `SQLITE_OK`
- `exportM3u` now validates playlist existence and returns `false` if not found
- `importM3u`/`parseFilenameMetadata` tuple destructuring and forward-declaration compile errors

## [0.4.9]: 2026-07-26

### Added
- Daemon foundation: queue IPC, track advancement, crossfade scheduling, favourites, state persistence
- Monolithic rewrite: daemon owns all state, yt-dlp moved server-side
- Stream YT tracks immediately with background download, up-next notification, queue integrity
- Queue sync fix, footer preset setting, fuzzy finder fixes, crossfade curve type, single-row highlighting
- TUI improvements: opaque overlays, footer modules, key display, downloads, queue, EQ
- TUI freeze fix, YT search spinner, overlay opacity, art overlap fix

### Changed (gtm.spec v2 compliance)
- Handshake protocol v2 with version negotiation (client/daemon exchange versions)
- Socket path fallback chain: XDG_RUNTIME_DIR → /tmp/gtm-$USER → TMPDIR → ~/.gtm
- Heartbeat emission gated on active playback, ~28.8s cadence
- Client initial connect: 100→5000ms backoff, 10 attempts; reconnect: 500→10000ms, 30 attempts
- Response timeout 5s (was 3s), 1 MiB line cap, malformed JSON no longer crashes
- Wire commands renamed to spec (no aliases): play, play_pause, get_status, cycle_repeat, toggle_shuffle
- Umbrella queue/library sub-commands: `{"cmd":"queue","action":"..."}` and `{"cmd":"library","action":"..."}`
- 8 new event types: shuffle_changed, repeat_mode_changed, queue_index_changed, crossfade_changed, eq_preset_changed, eq_enabled_changed, sleep_timer_tick, sleep_timer_expired
- position_changed threshold corrected to 0.5s per spec
- Canonical DaemonState type with version counter and JSON persistence
- get_status returns full structured daemon_state object alongside flat fields

### Fixed
- Unknown commands return {ok:false, error:"unknown command: <name>"}
- SIGINT/SIGTERM graceful shutdown
- Heartbeat and queue_changed events now emitted correctly
- Reconnect watchdog caps at 30 attempts

## [0.0.4]: 2025-07-12

### Fixed
- P0/P1 security, stability, and code quality issues

## [0.0.3]: 2025-07-12

### Added
- Command palette entries: `create_playlist`, `delete_playlist`, `rename_playlist`, `import_m3u`, `export_m3u`, `rescan_library`, `show_now_playing`

### Changed
- Increased palette display from 10 to 20 results
- Increased palette box height to accommodate more items

## [0.0.2]: 2025-07-12

### Added
- Playlist management: daemon commands for CRUD (`create`/`delete`/`rename`/`list`/`add`/`remove`)
- `PlaylistContentsView`: Enter opens track list, Escape goes back
- Keybindings: `a` create, `d` delete (with confirmation), `r` rename (with prompt)
- `addSelectionToPlaylist` routed through daemon for DB persistence
- `renamePlaylist` in library module
- `playlistInputActive` / `playlistInputBuffer` state for text input overlay

### Fixed
- SQL injection in `createPlaylist`, `deletePlaylist`, `getArtistId`

## [0.0.1]: 2025-07-12

### Added
- Full source code: `gtm.nim`, `ui.nim`, `audio.nim`, `daemon.nim`, and all modules
- FFmpeg audio backend with crossfade support
- SQLite library with track/artist/album/playlist persistence
- YouTube integration via yt-dlp
- D-Bus MPRIS support
- Unix socket IPC between client and daemon
- Nerd Font icon system with state-dependent icons
- State-dependent icons via `currentIcons()` in UI

### Fixed
- Config save/load: persist `vizVisible` and `bar_count`
- Settings volume Enter: now toggles mute with volume restore
- `toggleMute`: preserve previous volume for unmute
- Nerd Font detection: check `TERM_PROGRAM` and `TERM` env vars

[Unreleased]: https://github.com/prjctimg/gtm.nim/compare/v0.4.9...HEAD
[0.4.9]: https://github.com/prjctimg/gtm.nim/compare/0.0.4...v0.4.9
[0.0.4]: https://github.com/prjctimg/gtm.nim/compare/0.0.3...0.0.4
[0.0.3]: https://github.com/prjctimg/gtm.nim/compare/0.0.2...0.0.3
[0.0.2]: https://github.com/prjctimg/gtm.nim/compare/0.0.1...0.0.2
[0.0.1]: https://github.com/prjctimg/gtm.nim/releases/tag/0.0.1
