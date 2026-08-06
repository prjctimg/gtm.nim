# gtmd — IPC Protocol Specification

gtmd is a standalone audio playback daemon that communicates over a Unix domain
socket using newline-delimited JSON. Any process that can open a Unix socket and
speak JSON can act as a client — enabling plugin-based UIs (Neovim Lua, CLI
tools, web dashboards, etc.) to control playback.

---

## Transport

| Field | Value |
|---|---|
| Socket family | `AF_UNIX` / `SOCK_STREAM` |
| Socket path | `$XDG_RUNTIME_DIR/gtm/gtmd.sock` or `/tmp/gtm-<USER>/gtmd.sock` |
| Framing | Newline-delimited — each JSON object is terminated by `\n` |
| Encoding | UTF-8 |
| Max clients | 1 (new connection replaces the previous one) |
| I/O model | Non-blocking; daemon uses `select()` with a 16 ms time-out |

### Client auto-start

When `gtm` (the TUI) is launched it looks for the running daemon via
`$XDG_RUNTIME_DIR/gtm/gtmd.pid`. If the daemon is not running it spawns
`gtmd` as a child process and waits up to 600 ms for the socket to appear.

---

## Message Format

### Request (client → daemon)

```json
{"cmd": "<command_name>", "arg1": value1, "arg2": value2, ...}
```

Every request MUST contain a `"cmd"` string. Additional arguments are
command-specific (see [Commands](#commands)).

### Response (daemon → client)

Every command produces exactly one response line:

```json
{"ok": true, "field1": value1, ...}
```

On failure:

```json
{"ok": false, "error": "description of error"}
```

### Events (daemon → client, unsolicited)

The daemon pushes playback events asynchronously as JSON lines:

```json
{"events": [{"kind": 5, "time_pos": 123.45}, ...]}
```

Multiple events may be batched into a single line. Events are sent after every
command response AND between commands (each iteration of the daemon's event
loop). A client MUST be prepared to receive event lines at any time.

---

## Events

Each event object has at minimum a `"kind"` field (integer). The kind values
and their additional payload fields are:

| Kind | Name | Extra fields | When emitted |
|---|---|---|---|
| `1` | `aekPlaybackStarted` | `state: "playing"` | Playback begins / resumes after stop |
| `2` | `aekPlaybackPaused` | `state: "paused"` | Playback paused |
| `3` | `aekPlaybackStopped` | `state: "stopped"` | Playback stopped |
| `4` | `aekTrackEnded` | `reason: "eof"` | Current track reached end-of-file |
| `5` | `aekPositionChanged` | `time_pos: <float>` | Playback position advanced (~1 Hz) |
| `6` | `aekDurationChanged` | `duration: <float>` | Track duration resolved or changed |
| `7` | `aekVolumeChanged` | `volume: <int>` | Volume changed |
| `8` | `aekMetadataChanged` | *(none currently)* | Track metadata updated |
| `9` | `aekError` | *(none currently)* | Audio backend error |

### Example event line

```json
{"events":[{"kind":5,"time_pos":42.7},{"kind":1,"state":"playing"}]}
```

---

## Commands

Unless noted otherwise, every response includes at least `"ok": true` or
`"ok": false` with an `"error"` string. Additional response fields are listed
per command.

### Playback Control

#### `play`

Resume playback (from paused state). No effect if already playing.

Request: `{"cmd": "play"}`

Response: `{"ok": true}`

#### `pause`

Pause playback.

Request: `{"cmd": "pause"}`

Response: `{"ok": true}`

#### `toggle_pause`

Toggle between playing and paused.

Request: `{"cmd": "toggle_pause"}`

Response: `{"ok": true}`

#### `stop`

Stop playback and rewind to position 0.

Request: `{"cmd": "stop"}`

Response: `{"ok": true}`

#### `seek`

Seek by a relative offset (in seconds).

| Arg | Type | Default | Description |
|---|---|---|---|
| `seconds` | float | `5.0` | Seek offset in seconds. May be negative. |

Request: `{"cmd": "seek", "seconds": -10.0}`

Response: `{"ok": true}`

#### `next`

Stop current track (advance to next is handled by the TUI, not the daemon).

Request: `{"cmd": "next"}`

Response: `{"ok": true}`

#### `prev`

Stop current track (go to previous is handled by the TUI).

Request: `{"cmd": "prev"}`

Response: `{"ok": true}`

#### `load_file`

Load a file or URL and begin playback. Optionally attach metadata so the
daemon can track play counts.

| Arg | Type | Default | Description |
|---|---|---|---|
| `path` | string | `""` | File path, URL, or YouTube page URL (required) |
| `title` | string | `""` | Track title for display and library |
| `channel` | string | `""` | Artist / channel name |

Request: `{"cmd": "load_file", "path": "/music/track.flac", "title": "Song", "channel": "Artist"}`

Response:
```json
{
  "ok": true,
  "state": "playing",
  "duration": 234.5,
  "track_id": 42
}
```

| Field | Type | Description |
|---|---|---|
| `state` | string | `"playing"`, `"paused"`, or `"stopped"` |
| `duration` | float | Track duration in seconds |
| `track_id` | int | Library track ID (0 if not in library) |

#### `resume`

Resume the last loaded track. If no track is loaded, returns `state: "stopped"`.

Request: `{"cmd": "resume"}`

Response:
```json
{"ok": true, "state": "playing", "track": "/music/track.flac", "time_pos": 12.3, "duration": 234.5}
```

#### `status` / `now_playing`

Get current playback status. Both commands are identical in behaviour.

Request: `{"cmd": "status"}`

Response:
```json
{
  "ok": true,
  "state": "playing",
  "volume": 80,
  "time_pos": 42.0,
  "duration": 234.5,
  "track": "/music/track.flac",
  "audio_working": true,
  "sleep_timer": 0,
  "crossfading": false,
  "master_ended": false
}
```

| Field | Type | Description |
|---|---|---|
| `state` | string | `"playing"`, `"paused"`, or `"stopped"` |
| `volume` | int | Current volume (0–100) |
| `time_pos` | float | Current playback position in seconds |
| `duration` | float | Track duration in seconds |
| `track` | string | Path or URL of the current track |
| `audio_working` | bool | Whether the audio backend is operational |
| `sleep_timer` | int | Sleep timer remaining (minutes, 0 = off) |
| `crossfading` | bool | Whether a crossfade is in progress |
| `master_ended` | bool | Whether the master decode context has ended |

#### `get_state`

Get comprehensive playback state, including track metadata.

Request: `{"cmd": "get_state"}`

Response:
```json
{
  "ok": true,
  "state": "playing",
  "volume": 80,
  "time_pos": 42.0,
  "duration": 234.5,
  "track_path": "/music/track.flac",
  "track_title": "Song",
  "track_channel": "Artist",
  "track_album": "Album",
  "shuffle": false,
  "repeat": 0,
  "sleep_timer": 0,
  "crossfading": false,
  "master_ended": false
}
```

### Volume

#### `set_volume`

Set the playback volume.

| Arg | Type | Default | Description |
|---|---|---|---|
| `volume` | int | `80` | Volume level (0–100) |

Request: `{"cmd": "set_volume", "volume": 75}`

Response: `{"ok": true}`

#### `get_volume`

Get the current volume.

Request: `{"cmd": "get_volume"}`

Response: `{"ok": true, "volume": 80}`

### Playback mode

#### `set_shuffle`

Enable or disable shuffle.

| Arg | Type | Default | Description |
|---|---|---|---|
| `enabled` | int | `0` | `1` to enable, `0` to disable |

Request: `{"cmd": "set_shuffle", "enabled": 1}`

Response: `{"ok": true, "shuffle": true}`

#### `set_repeat`

Set repeat mode.

| Arg | Type | Default | Description |
|---|---|---|---|
| `mode` | int | `0` | `0` = off, `1` = repeat all, `2` = repeat one |

Request: `{"cmd": "set_repeat", "mode": 1}`

Response: `{"ok": true, "repeat": 1}`

#### `set_sleep_timer`

Set a sleep timer after which playback stops.

| Arg | Type | Default | Description |
|---|---|---|---|
| `minutes` | int | `0` | Minutes until stop. `0` disables the timer. |

Request: `{"cmd": "set_sleep_timer", "minutes": 15}`

Response: `{"ok": true, "sleep_timer": 15}`

### Crossfade

#### `prepare_next`

Pre-load the next track in a secondary decode context for gapless crossfade.

| Arg | Type | Default | Description |
|---|---|---|---|
| `path` | string | `""` | File path or URL to prepare |

Request: `{"cmd": "prepare_next", "path": "/music/next.flac"}`

Response: `{"ok": true}`

#### `crossfade`

Begin an equal-power crossfade from the current (master) context to the
prepared (slave) context. `prepare_next` must have been called first.

| Arg | Type | Default | Description |
|---|---|---|---|
| `duration` | float | `5.0` | Crossfade duration in seconds |

Request: `{"cmd": "crossfade", "duration": 3.0}`

Response: `{"ok": true}`

### Equalizer

#### `set_eq_band`

Set the gain for a single equalizer band.

| Arg | Type | Default | Description |
|---|---|---|---|
| `band` | int | `0` | Band index (0–9: 31, 62, 125, 250, 500, 1k, 2k, 4k, 8k, 16k Hz) |
| `gain_db` | float | `0.0` | Gain in dB (typically –12 to +12) |

Request: `{"cmd": "set_eq_band", "band": 3, "gain_db": -2.5}`

Response: `{"ok": true}`

#### `set_eq_preset`

Apply a named equalizer preset.

| Arg | Type | Default | Description |
|---|---|---|---|
| `name` | string | `""` | Preset name: `Flat`, `Rock`, `Pop`, `Classical`, `Jazz`, `HipHop`, `Vocal`, `BassBoost`, `Headphones`, `Laptop` |

Request: `{"cmd": "set_eq_preset", "name": "Rock"}`

Response: `{"ok": true}`

### Audio Processing

#### `set_reverb`

Enable or disable reverb on the mixer.

| Arg | Type | Default | Description |
|---|---|---|---|
| `enabled` | bool | `false` | Whether reverb is on |
| `room_size` | float | `0.7` | Room size parameter (0.0–1.0) |

Request: `{"cmd": "set_reverb", "enabled": true, "room_size": 0.8}`

Response: `{"ok": true}`

#### `set_loudness_mode`

Set the loudness normalization mode.

| Arg | Type | Default | Description |
|---|---|---|---|
| `mode` | string | `"off"` | `off`, `track`, `album`, or `auto` |

Request: `{"cmd": "set_loudness_mode", "mode": "track"}`

Response: `{"ok": true}`

#### `set_pre_gain`

Set the target loudness (pre-gain) in LUFS for loudness normalization.

| Arg | Type | Default | Description |
|---|---|---|---|
| `pre_gain_db` | float | `-14.0` | Target integrated loudness in LUFS (negative) |

Request: `{"cmd": "set_pre_gain", "pre_gain_db": -16.0}`

Response: `{"ok": true}`

#### `scan_loudness`

Start a background loudness scan over the library using ffmpeg's EBU R128
filter. Emits `loudness_scan_progress` / `loudness_scan_done` events.

| Arg | Type | Default | Description |
|---|---|---|---|
| `force` | bool | `false` | Re-scan tracks that already have loudness data |
| `track_ids` | int64[] | `null` | Optional list of track IDs to scan; all when omitted |

Request: `{"cmd": "scan_loudness", "force": true}`

Response:
```json
{"ok": true, "started": true, "pending_tracks": 120}
```

#### `set_gapless`

Enable or disable gapless playback (zero-gap track transition at end of the
current track).

| Arg | Type | Default | Description |
|---|---|---|---|
| `enabled` | bool | `false` | Whether gapless playback is on |

Request: `{"cmd": "set_gapless", "enabled": true}`

Response: `{"ok": true}`

#### `set_dynamic_mode`

Enable or disable dynamic volume mode (auto volume adjustment while playing).

| Arg | Type | Default | Description |
|---|---|---|---|
| `enabled` | bool | `false` | Whether dynamic mode is on |

Request: `{"cmd": "set_dynamic_mode", "enabled": true}`

Response: `{"ok": true}`

#### `set_scrobble`

Enable or disable Last.fm scrobbling. Scrobbles are submitted once a track has
played for at least 50% of its duration (or 4 minutes).

| Arg | Type | Default | Description |
|---|---|---|---|
| `enabled` | bool | `false` | Whether scrobbling is on |

Request: `{"cmd": "set_scrobble", "enabled": true}`

Response: `{"ok": true}`

### Library / Playlists

The daemon maintains a SQLite library database at
`$XDG_DATA_HOME/gtm/gtm.db`. All playlist commands operate on this database.

#### `scan`

Recursively scan a directory for audio files and add them to the library.

| Arg | Type | Default | Description |
|---|---|---|---|
| `path` | string | `""` | Directory path to scan |

Request: `{"cmd": "scan", "path": "/music"}`

Response: `{"ok": true}`

#### `create_playlist`

Create a new empty playlist.

| Arg | Type | Default | Description |
|---|---|---|---|
| `name` | string | `""` | Playlist name |

Request: `{"cmd": "create_playlist", "name": "Favourites"}`

Response:
```json
{"ok": true, "playlist_id": 5, "playlists": [...]}
```

| Field | Type | Description |
|---|---|---|
| `playlist_id` | int | ID of the newly created playlist |
| `playlists` | array | Array of all current playlists (`id`, `name`, `track_count`) |

#### `delete_playlist`

Delete a playlist by ID.

| Arg | Type | Default | Description |
|---|---|---|---|
| `playlist_id` | int | `0` | Playlist ID to delete |

Request: `{"cmd": "delete_playlist", "playlist_id": 5}`

Response:
```json
{"ok": true, "playlists": [...]}
```

#### `rename_playlist`

Rename a playlist.

| Arg | Type | Default | Description |
|---|---|---|---|
| `playlist_id` | int | `0` | Playlist ID |
| `name` | string | `""` | New name |

Request: `{"cmd": "rename_playlist", "playlist_id": 5, "name": "Best Of"}`

Response:
```json
{"ok": true, "playlists": [...]}
```

#### `add_to_playlist`

Add a track to a playlist.

| Arg | Type | Description |
|---|---|---|
| `data` | object | Contains `playlist_id` (int), `track_id` (int), `position` (int) |

Request:
```json
{"cmd": "add_to_playlist", "data": {"playlist_id": 5, "track_id": 42, "position": 0}}
```

Response: `{"ok": true}`

#### `remove_from_playlist`

Remove a track from a playlist.

| Arg | Type | Description |
|---|---|---|
| `data` | object | Contains `playlist_id` (int), `track_id` (int) |

Request:
```json
{"cmd": "remove_from_playlist", "data": {"playlist_id": 5, "track_id": 42}}
```

Response: `{"ok": true}`

#### `list_playlists`

List all playlists.

Request: `{"cmd": "list_playlists"}`

Response:
```json
{"ok": true, "playlists": [{"id": 1, "name": "Favourites", "track_count": 15}, ...]}
```

#### `get_playlist_tracks`

Get track IDs belonging to a playlist.

| Arg | Type | Default | Description |
|---|---|---|---|
| `playlist_id` | int | `0` | Playlist ID |

Request: `{"cmd": "get_playlist_tracks", "playlist_id": 5}`

Response:
```json
{"ok": true, "playlist_id": 5, "track_ids": [1, 2, 3, ...]}
```

#### `organize_library`

Move tracks into a canonical `Artist/Album/Track` folder layout under the
library directory.

| Arg | Type | Default | Description |
|---|---|---|---|
| `dry_run` | bool | `true` | Report planned moves without applying them |

Request: `{"cmd": "organize_library", "dry_run": true}`

Response:
```json
{"ok": true, "moves": [{"from": "/old/path.mp3", "to": "/Artist/Album/Track.mp3"}], "dry_run": true}
```

Moves are applied when `dry_run` is false. Emits a `library_organized` custom
event when moves are applied.

#### `get_cover_art`

Fetch (or return cached) cover art for a track. If not cached locally, the
daemon searches Deezer and stores the result in the `covers` table.

| Arg | Type | Default | Description |
|---|---|---|---|
| `track_id` | int | `0` | Library track ID |

Response:
```json
{"ok": true, "track_id": 5, "data": "<base64 PNG>", "cached": true}
```

`data` is `null` when no cover could be found.

#### `get_lyrics`

Fetch (or return cached) synchronized lyrics for a track from lrclib.net and
store them in the `lyrics` table.

| Arg | Type | Default | Description |
|---|---|---|---|
| `track_id` | int | `0` | Library track ID |

Response:
```json
{"ok": true, "track_id": 5, "lyrics": {"synced": true, "lines": [{"time": 12.0, "text": "Line one"}]}, "cached": true}
```

`lyrics` is `null` when no lyrics could be found. When present it is an object
with a `synced` boolean and a `lines` array of `{time, text}` entries parsed
from the LRC source.

#### `sync_covers`

Start a background scan that fetches missing cover art for all library tracks.
Emits `covers_synced` custom event when complete.

Request: `{"cmd": "sync_covers"}`

Response:
```json
{"ok": true, "started": true, "pending_tracks": 34}
```

#### `sync_lyrics`

Start a background scan that fetches missing lyrics for all library tracks.
Emits `lyrics_synced` custom event when complete.

Request: `{"cmd": "sync_lyrics"}`

Response:
```json
{"ok": true, "started": true, "pending_tracks": 40}
```

### Lifecycle

#### `quit`

Shut down the daemon. Saves playback state (volume, current track, position)
to the library database, closes the audio
backend, removes the socket file, and exits the process.

Request: `{"cmd": "quit"}`

Response: `{"ok": true}` (client may not receive this before the socket closes)

---

## Example Session (Neovim Lua)

```lua
local sock = vim.uv.new_tcp()

-- Connect to the daemon socket
sock:connect("/run/user/1000/gtm/gtmd.sock", function(err)
  assert(not err, err)

  -- Play a track
  local play_cmd = '{"cmd":"load_file","path":"/music/track.flac"}\n'
  sock:write(play_cmd)

  -- Read response
  sock:read_start(function(_, data)
    for line in data:gmatch("[^\n]+") do
      local ok, resp = pcall(vim.json.decode, line)
      if ok then
        if resp.events then
          for _, ev in ipairs(resp.events) do
            if ev.kind == 5 then  -- aekPositionChanged
              print("Position:", ev.time_pos)
            elseif ev.kind == 1 then  -- aekPlaybackStarted
              print("Now playing")
            end
          end
        else
          print("Command response:", vim.inspect(resp))
        end
      end
    end
  end)

  -- Seek after 2 seconds
  vim.defer_fn(function()
    sock:write('{"cmd":"seek","seconds":30.0}\n')
  end, 2000)
end)
```

### General client flow

1. Open a `SOCK_STREAM` connection to the Unix socket at `sockPath()`
2. Send a command as a single JSON line: `{"cmd":"<cmd>", ...}\n`
3. Read lines from the socket — each `\n`-terminated string is a JSON object
4. If the JSON contains an `"events"` key, it is an asynchronous event batch
5. Otherwise it is the response to the last command sent
6. Event lines may arrive at any time, including between a command and its
   response — the response is the **first** non-event line received after the
   command
7. The daemon accepts at most one connected client; a new connection
   automatically replaces the previous one

---

## Implementation reference

| Component | File | Role |
|---|---|---|
| Daemon entry point | `src/gtmd.nim` | Calls `runDaemon()` |
| Daemon main loop + IPC | `src/daemon.nim` | Socket creation, event loop, command parsing, response serialization |
| Audio backend abstraction | `src/audio.nim` | `AudioEventKind` enum, `AudioBackend` class hierarchy |
| Reference client | `src/client.nim` | `DaemonClient` with `sendDaemonCmd` and `pollEvents` |
| Paths and directories | `src/state.nim` | `sockPath()`, `pidPath()`, `stateDir()`, `dataDir()` |
