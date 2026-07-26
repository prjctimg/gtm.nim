# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

Licensed under the GNU General Public License v3.0 — see [LICENSE](LICENSE) for details.

## [Unreleased]

### Added
- Daemon foundation: queue IPC, track advancement, crossfade scheduling, favourites, state persistence
- Monolithic rewrite — daemon owns all state, yt-dlp moved server-side
- Stream YT tracks immediately with background download, up-next notification, queue integrity
- Queue sync fix, footer preset setting, fuzzy finder fixes, crossfade curve type, single-row highlighting
- TUI improvements: opaque overlays, footer modules, key display, downloads, queue, EQ
- TUI freeze fix, YT search spinner, overlay opacity, art overlap fix

### Fixed
- Daemon-client IPC reliability: EAGAIN retry, async scan, 30s timeout, desync protection, greeting
- yt-dlp integration inconsistencies — playback, download, search
- Audio output, playback history tracking, yt-dlp `--print format`
- Synchronize all TUI actions and state from daemon
- TUI event handling for YT downloaded tracks
- Position events, timePos sync, drainEventLines, YT timer restore, shuffle/repeat sync

## [0.0.4] — 2025-07-12

### Fixed
- P0/P1 security, stability, and code quality issues

## [0.0.3] — 2025-07-12

### Added
- Command palette entries: `create_playlist`, `delete_playlist`, `rename_playlist`, `import_m3u`, `export_m3u`, `rescan_library`, `show_now_playing`

### Changed
- Increased palette display from 10 to 20 results
- Increased palette box height to accommodate more items

## [0.0.2] — 2025-07-12

### Added
- Playlist management: daemon commands for CRUD (`create`/`delete`/`rename`/`list`/`add`/`remove`)
- `PlaylistContentsView`: Enter opens track list, Escape goes back
- Keybindings: `a` create, `d` delete (with confirmation), `r` rename (with prompt)
- `addSelectionToPlaylist` routed through daemon for DB persistence
- `renamePlaylist` in library module
- `playlistInputActive` / `playlistInputBuffer` state for text input overlay

### Fixed
- SQL injection in `createPlaylist`, `deletePlaylist`, `getArtistId`

## [0.0.1] — 2025-07-12

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

[Unreleased]: https://github.com/skchr/gtm/compare/0.0.4...HEAD
[0.0.4]: https://github.com/skchr/gtm/compare/0.0.3...0.0.4
[0.0.3]: https://github.com/skchr/gtm/compare/0.0.2...0.0.3
[0.0.2]: https://github.com/skchr/gtm/compare/0.0.1...0.0.2
[0.0.1]: https://github.com/skchr/gtm/releases/tag/0.0.1
