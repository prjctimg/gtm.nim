import os, json, strutils, net, osproc, posix, tables
from times import epochTime
from nativesockets import setBlocking
import state, audio

type
  PendingRequest* = object
    idNo: int
    callback: proc(resp: JsonNode) {.closure.}

  DaemonClient* = ref object of AudioBackend
    sock: Socket
    connected*: bool
    buf: string
    sleepTimerRemaining*: int
    lastTrackId*: int64
    drainedEvents: seq[AudioEvent]
    ipcTimeoutSec*: float
    nextRetryAt*: float
    retryDelayMs*: int
    connectionAttempts*: int
    firstConnection*: bool
    lastDataAt*: float
    nextId: int
    pending: seq[PendingRequest]

proc daemonIsRunning*(): bool =
  let p = pidPath()
  if fileExists(p):
    try:
      let pid = readFile(p).strip().parseInt()
      if pid > 0:
        result = posix.kill(pid.cint, 0) == 0
        if not result:
          # Stale PID — remove file
          try: removeFile(p) except: discard
    except:
      try: removeFile(p) except: discard
      result = false

proc startDaemonProcess*() =
  let selfPath = getAppFilename()
  let daemonBin = selfPath.parentDir() / "gtmd"
  let daemonArgs = if debugMode: @["--debug"] else: @[]
  if fileExists(daemonBin):
    discard startProcess(daemonBin, args = daemonArgs,
      options = {poUsePath, poParentStreams})
  elif fileExists(findExe("gtmd")):
    discard startProcess("gtmd", args = daemonArgs,
      options = {poUsePath, poParentStreams})
  else:
    stderr.writeLine("[gtm] gtmd not found, trying fallback to self")
    discard startProcess(selfPath, args = @["daemon"] & daemonArgs,
      options = {poUsePath, poParentStreams})

proc connectToDaemon*(cli: DaemonClient): bool =
  if cli.connected and cli.sock != nil:
    try: cli.sock.close() except: stderr.writeLine("[gtm] connectToDaemon close: " & getCurrentExceptionMsg())
  cli.connected = false
  try:
    let fd = posix.socket(posix.AF_UNIX, posix.SOCK_STREAM, 0)
    cli.sock = newSocket(fd, Domain.AF_UNIX, SockType.SOCK_STREAM)
    cli.sock.connectUnix(sockPath())
    setBlocking(cli.sock.getFd, false)
    cli.connected = true
    cli.backendType = abtDaemon
    return true
  except:
    if cli.sock != nil:
      try: cli.sock.close() except: discard
    cli.sock = nil
    return false

proc handshake*(cli: DaemonClient): bool

proc ensureDaemon*(cli: DaemonClient) =
  if cli == nil: return
  if cli.connected: return
  let now = epochTime()
  if now < cli.nextRetryAt: return
  # Per client.md §Connection retry (initial) and §Reconnection (post-loss):
  #   initial:  100, 200, 400, 800, 1600, 3200, 5000 cap — 10 attempts
  #   reconnect: 500, 1000, 2000, 4000, 8000, 10000 cap — 30 attempts
  # connectionAttempts is reset to 0 on a successful handshake.
  let maxAttempts = if cli.firstConnection: 10 else: 30
  let capMs = if cli.firstConnection: 5000 else: 10000
  if cli.connectionAttempts >= maxAttempts:
    # Bail out; caller (TUI watchdog) surfaces a permanent failure to the user.
    return
  if daemonIsRunning():
    if connectToDaemon(cli):
      if cli.handshake():
        cli.retryDelayMs = if cli.firstConnection: 100 else: 500
        cli.connectionAttempts = 0
        cli.firstConnection = false
        cli.nextRetryAt = 0.0
        cli.lastDataAt = epochTime()
      else:
        try: cli.sock.close() except: discard
        cli.sock = nil
        cli.connected = false
        cli.connectionAttempts.inc
        cli.nextRetryAt = now + cli.retryDelayMs.float / 1000.0
        cli.retryDelayMs = min(cli.retryDelayMs * 2, capMs)
    else:
      cli.connectionAttempts.inc
      cli.nextRetryAt = now + cli.retryDelayMs.float / 1000.0
      cli.retryDelayMs = min(cli.retryDelayMs * 2, capMs)
  else:
    startDaemonProcess()
    cli.connectionAttempts.inc
    cli.nextRetryAt = now + cli.retryDelayMs.float / 1000.0
    cli.retryDelayMs = min(cli.retryDelayMs * 2, capMs)

proc drainEventLines(cli: DaemonClient, buf: var string) =
  cli.drainedEvents = @[]
  while true:
    let nli = buf.find('\n')
    if nli < 0: break
    let line = buf[0..<nli]
    buf = buf[nli+1..^1]
    if line.len == 0: continue
    try:
      let j = parseJson(line)
      if not j.hasKey("event"):
        buf = line & "\n" & buf
        break
      let evName = j["event"].getStr("")
      var ev = AudioEvent()
      ev.kind = parseEventName(evName)
      case ev.kind
      of aekPositionChanged: ev.floatVal = j{"time_pos"}.getFloat(0.0)
      of aekDurationChanged: ev.floatVal = j{"duration"}.getFloat(0.0)
      of aekVolumeChanged: ev.intVal = j{"volume"}.getInt(0)
      of aekPlaybackStarted:
        let track = j{"track"}
        if track != nil and track.kind == JObject:
          ev.metadata["track_path"] = track{"path"}.getStr("")
          ev.metadata["track_title"] = track{"title"}.getStr("")
          ev.metadata["track_channel"] = track{"artist"}.getStr("")
        ev.metadata["auto_advanced"] = $(j{"auto_advanced"}.getBool(false))
      of aekPlaybackPaused: discard
      of aekPlaybackStopped: discard
      of aekTrackEnded: discard
      of aekMetadataChanged:
        ev.strVal = j{"name"}.getStr("")
      of aekQueueChanged:
        if j.hasKey("queue"):
          ev.metadata["queue"] = $j["queue"]
        if j.hasKey("cursor"):
          ev.intVal = j["cursor"].getInt(0)
      of aekHeartbeat: discard
      of aekShuffleChanged:
        ev.intVal = if j{"enabled"}.getBool(false): 1 else: 0
      of aekRepeatModeChanged:
        ev.strVal = j{"mode"}.getStr("off")
      of aekQueueIndexChanged:
        ev.intVal = j{"index"}.getInt(0)
      of aekCrossfadeChanged:
        ev.intVal = if j{"enabled"}.getBool(false): 1 else: 0
        ev.floatVal = j{"duration_secs"}.getFloat(0.0)
      of aekEqPresetChanged:
        ev.strVal = j{"preset"}.getStr("")
      of aekEqEnabledChanged:
        ev.intVal = if j{"enabled"}.getBool(false): 1 else: 0
      of aekSleepTimerTick:
        ev.intVal = j{"remaining_secs"}.getInt(0)
      of aekSleepTimerExpired: discard
      of aekReverbChanged:
        ev.intVal = if j{"enabled"}.getBool(false): 1 else: 0
        ev.floatVal = j{"room_scale"}.getFloat(0.7)
      of aekLoudnessModeChanged:
        case j{"mode"}.getStr("off")
        of "track": ev.intVal = 1
        of "album": ev.intVal = 2
        of "auto": ev.intVal = 3
        else: ev.intVal = 0
      of aekPreGainChanged:
        ev.floatVal = j{"pre_gain_db"}.getFloat(-14.0)
      of aekGaplessChanged:
        ev.intVal = if j{"enabled"}.getBool(false): 1 else: 0
      of aekDynamicModeChanged:
        ev.intVal = if j{"enabled"}.getBool(false): 1 else: 0
      of aekScrobbleConfigChanged:
        ev.intVal = if j{"enabled"}.getBool(false): 1 else: 0
      of aekCustomEvent:
        ev.strVal = j{"name"}.getStr("")
        if j.hasKey("shuffleIndex"):
          ev.intVal = j["shuffleIndex"].getInt(0)
        if j.hasKey("url"):
          ev.metadata["url"] = j["url"].getStr("")
        if j.hasKey("path"):
          ev.metadata["path"] = j["path"].getStr("")
        if j.hasKey("title"):
          ev.metadata["title"] = j["title"].getStr("")
        if j.hasKey("channel"):
          ev.metadata["channel"] = j["channel"].getStr("")
        if j.hasKey("next_path"):
          ev.metadata["next_path"] = j["next_path"].getStr("")
        if j.hasKey("next_title"):
          ev.metadata["next_title"] = j["next_title"].getStr("")
        if j.hasKey("next_channel"):
          ev.metadata["next_channel"] = j["next_channel"].getStr("")
        if j.hasKey("queue"):
          ev.metadata["queue"] = $j["queue"]
        if j.hasKey("results"):
          ev.metadata["results"] = $j["results"]
        if j.hasKey("tracks"):
          ev.metadata["tracks"] = $j["tracks"]
      else: discard
      cli.drainedEvents.add(ev)
    except:
      buf = line & "\n" & buf
      break

proc clearPending*(cli: DaemonClient)

proc sendDaemonCmd*(cli: DaemonClient, cmd: JsonNode): JsonNode =
  if cli == nil or cli.sock == nil or not cli.connected: return %*{"ok": false, "error": "not connected"}
  try:
    drainEventLines(cli, cli.buf)
    let idNo = cli.nextId
    cli.nextId.inc
    cmd["id"] = %idNo
    let data = $cmd & "\n"
    cli.sock.send(data)
    var tmp: array[16384, char]
    let timeout = if cli.ipcTimeoutSec > 0: cli.ipcTimeoutSec else: 5.0
    var totalWait = 0.0
    while totalWait < timeout:
      var rfds: posix.TFdSet
      FD_ZERO(rfds)
      FD_SET(cli.sock.getFd, rfds)
      var tv: posix.Timeval
      tv.tv_sec = 0.Time
      tv.tv_usec = 100_000.Suseconds
      let sel = posix.select(cint(int(cli.sock.getFd) + 1), addr(rfds), nil, nil, addr(tv))
      if sel > 0:
        let n = posix.recv(cli.sock.getFd, addr tmp[0], tmp.len, 0.cint)
        if n > 0:
          let old = cli.buf.len
          if old + n > 16 * 1024 * 1024:
            cli.connected = false
            cli.clearPending()
            return %*{"ok": false, "error": "buffer exceeded"}
          cli.buf.setLen(old + n); copyMem(addr cli.buf[old], addr tmp[0], n)
        elif n == 0:
          cli.connected = false
          cli.clearPending()
          return %*{"ok": false, "error": "connection closed"}
      while true:
        let nli = cli.buf.find('\n')
        if nli < 0: break
        let line = cli.buf[0..<nli]
        cli.buf = cli.buf[nli+1..^1]
        if line.len == 0: continue
        if line.len > 1048576:
          cli.connected = false
          cli.clearPending()
          return %*{"ok": false, "error": "line exceeds 1 MiB"}
        let j = try: parseJson(line) except CatchableError: nil
        if j == nil:
          cli.connected = false
          cli.clearPending()
          return %*{"ok": false, "error": "malformed JSON"}
        if j.hasKey("id") and j["id"].getInt(-1) == idNo:
          return j
        if j.hasKey("event"): continue
      totalWait += 0.1
  except:
    cli.connected = false
    cli.clearPending()
  return %*{"ok": false, "error": "no response"}

proc handshake*(cli: DaemonClient): bool =
  if cli == nil or cli.sock == nil or not cli.connected: return false
  let cmd = %*{"cmd": "handshake", "version": 2, "client": "gtm",
    "client_version": "0.4.9"}
  let resp = sendDaemonCmd(cli, cmd)
  result = resp.hasKey("ok") and resp["ok"].getBool(false)

proc sendOnly*(cli: DaemonClient, cmd: JsonNode) =
  if cli == nil or cli.sock == nil or not cli.connected: return
  try:
    drainEventLines(cli, cli.buf)
    cmd["id"] = %cli.nextId
    cli.nextId.inc
    let data = $cmd & "\n"
    cli.sock.send(data)
  except:
    cli.connected = false
    cli.clearPending()

proc daemonSimpleCmd*(cli: DaemonClient, cmd: string): JsonNode =
  sendDaemonCmd(cli, %*{"cmd": cmd})

proc sendAsync*(cli: DaemonClient, cmd: JsonNode, callback: proc(resp: JsonNode) {.closure.}) =
  if cli == nil or cli.sock == nil or not cli.connected: return
  try:
    drainEventLines(cli, cli.buf)
    let idNo = cli.nextId
    cli.nextId.inc
    cmd["id"] = %idNo
    cli.pending.add(PendingRequest(idNo: idNo, callback: callback))
    let data = $cmd & "\n"
    cli.sock.send(data)
  except:
    discard

method loadFile*(cli: DaemonClient, path: string, title: string = "", channel: string = "") =
  cli.ensureDaemon()
  let resp = sendDaemonCmd(cli, %*{"cmd": "play", "path": path, "title": title, "channel": channel})
  cli.lastTrackId = 0
  if resp.hasKey("track_id"):
    cli.lastTrackId = resp["track_id"].getInt().int64
  if resp.hasKey("time_pos"):
    cli.timePos = resp["time_pos"].getFloat(0.0)
  if resp.hasKey("duration"):
    cli.duration = resp["duration"].getFloat(0.0)
  if resp.hasKey("state"):
    let s = resp["state"].getStr()
    cli.state = (if s == "playing": 1 elif s == "paused": 2 else: 0)

method play*(cli: DaemonClient) =
  discard

method pause*(cli: DaemonClient) =
  cli.ensureDaemon()
  cli.sendOnly(%*{"cmd": "pause"})

method stop*(cli: DaemonClient) =
  cli.ensureDaemon()
  cli.sendOnly(%*{"cmd": "stop"})

method seek*(cli: DaemonClient, seconds: float) =
  cli.ensureDaemon()
  cli.sendOnly(%*{"cmd": "seek", "position_secs": seconds})

method setVolume*(cli: DaemonClient, vol: int) =
  cli.ensureDaemon()
  if cli.sock == nil: return
  cli.sendOnly(%*{"cmd": "set_volume", "volume": vol})

method prepareNext*(cli: DaemonClient, path: string) =
  discard

method getStatusFlags*(cli: DaemonClient): tuple[crossfading, masterEnded: bool] =
  cli.ensureDaemon()
  let resp = daemonSimpleCmd(cli, "get_status")
  (resp{"crossfading"}.getBool(false), resp{"master_ended"}.getBool(false))

proc startCrossfade*(cli: DaemonClient, durationSeconds: float) =
  cli.ensureDaemon()
  cli.sendOnly(%*{"cmd": "crossfade", "enabled": true, "duration_secs": durationSeconds, "easing": "equal_power"})

method setEqBand*(cli: DaemonClient, band: int, gainDb: float) =
  discard

method setEqPreset*(cli: DaemonClient, name: string) =
  cli.ensureDaemon()
  cli.sendOnly(%*{"cmd": "set_eq_preset", "preset": name})

method setEqEnabled*(cli: DaemonClient, enabled: bool) =
  cli.ensureDaemon()
  cli.sendOnly(%*{"cmd": "set_eq_enabled", "enabled": enabled})

method setCrossfadeCurve*(cli: DaemonClient, curveType: int) =
  cli.ensureDaemon()
  let easing = case curveType
    of 0: "linear"
    of 2: "exponential"
    else: "equal_power"
  cli.sendOnly(%*{"cmd": "crossfade", "enabled": true, "duration_secs": 5, "easing": easing})

method togglePause*(cli: DaemonClient) =
  cli.ensureDaemon()
  cli.sendOnly(%*{"cmd": "play_pause"})

method pollEvents*(cli: DaemonClient): seq[AudioEvent] =
  result = cli.drainedEvents
  cli.drainedEvents = @[]
  if not cli.connected: return
  try:
    var tmp: array[16384, char]
    var rfds: posix.TFdSet
    FD_ZERO(rfds)
    FD_SET(cli.sock.getFd, rfds)
    var tv: posix.Timeval
    tv.tv_sec = 0.Time
    tv.tv_usec = 0.Suseconds
    let sel = posix.select(cint(int(cli.sock.getFd) + 1), addr(rfds), nil, nil, addr(tv))
    if sel > 0:
      let n = posix.recv(cli.sock.getFd, addr tmp[0], tmp.len, 0.cint)
      if n > 0:
        cli.lastDataAt = epochTime()
        let old = cli.buf.len; cli.buf.setLen(old + n); copyMem(addr cli.buf[old], addr tmp[0], n)
    while true:
      let nli = cli.buf.find('\n')
      if nli < 0: break
      let line = cli.buf[0..<nli]
      cli.buf = cli.buf[nli+1..^1]
      if line.len == 0: continue
      let json = parseJson(line)
      if json.hasKey("event"):
        let evName = json["event"].getStr("")
        var ev = AudioEvent()
        ev.kind = parseEventName(evName)
        case ev.kind
        of aekPositionChanged:
          ev.floatVal = json{"time_pos"}.getFloat(0.0)
          cli.timePos = ev.floatVal
        of aekDurationChanged: ev.floatVal = json{"duration"}.getFloat(0.0)
        of aekVolumeChanged: ev.intVal = json{"volume"}.getInt(0)
        of aekPlaybackStarted:
          let track = json{"track"}
          if track != nil and track.kind == JObject:
            ev.metadata["track_path"] = track{"path"}.getStr("")
            ev.metadata["track_title"] = track{"title"}.getStr("")
            ev.metadata["track_channel"] = track{"artist"}.getStr("")
          ev.floatVal = json{"time_pos"}.getFloat(0.0)
        of aekMetadataChanged: ev.strVal = json{"name"}.getStr("")
        of aekReverbChanged:
          ev.intVal = if json{"enabled"}.getBool(false): 1 else: 0
          ev.floatVal = json{"room_scale"}.getFloat(0.7)
        of aekLoudnessModeChanged:
          case json{"mode"}.getStr("off")
          of "track": ev.intVal = 1
          of "album": ev.intVal = 2
          of "auto": ev.intVal = 3
          else: ev.intVal = 0
        of aekPreGainChanged:
          ev.floatVal = json{"pre_gain_db"}.getFloat(-14.0)
        of aekGaplessChanged:
          ev.intVal = if json{"enabled"}.getBool(false): 1 else: 0
        of aekDynamicModeChanged:
          ev.intVal = if json{"enabled"}.getBool(false): 1 else: 0
        of aekScrobbleConfigChanged:
          ev.intVal = if json{"enabled"}.getBool(false): 1 else: 0
        of aekCustomEvent:
          ev.strVal = json{"name"}.getStr("")
          if json.hasKey("shuffleIndex"):
            ev.intVal = json["shuffleIndex"].getInt(0)
          if json.hasKey("url"):
            ev.metadata["url"] = json["url"].getStr("")
          if json.hasKey("path"):
            ev.metadata["path"] = json["path"].getStr("")
          if json.hasKey("title"):
            ev.metadata["title"] = json["title"].getStr("")
          if json.hasKey("channel"):
            ev.metadata["channel"] = json["channel"].getStr("")
          if json.hasKey("results"):
            ev.metadata["results"] = $json["results"]
          if json.hasKey("tracks"):
            ev.metadata["tracks"] = $json["tracks"]
        else: discard
        result.add(ev)
      elif json.hasKey("id"):
        let idNo = json["id"].getInt(-1)
        var i = 0
        while i < cli.pending.len:
          if cli.pending[i].idNo == idNo:
            let cb = cli.pending[i].callback
            cli.pending.delete(i)
            cb(json)
            break
          i.inc
      else:
        # Skip stray command response lines (leftover from timed-out commands)
        discard
  except:
    cli.connected = false
    cli.clearPending()

method getVolume*(cli: DaemonClient): int =
  cli.ensureDaemon()
  let resp = daemonSimpleCmd(cli, "get_volume")
  if resp.hasKey("volume"):
    return resp["volume"].getInt(80)
  return 80

proc clearPending*(cli: DaemonClient) =
  cli.pending = @[]

method shutdown*(cli: DaemonClient) =
  cli.clearPending()
  discard daemonSimpleCmd(cli, "quit")
  if cli.sock != nil:
    try: cli.sock.close() except: stderr.writeLine("[gtm] shutdown close: " & getCurrentExceptionMsg())

proc sendQuitDaemon*(cli: DaemonClient) =
  discard daemonSimpleCmd(cli, "quit")

proc createPlaylist*(cli: DaemonClient, name: string): JsonNode =
  cli.ensureDaemon()
  sendDaemonCmd(cli, %*{"cmd": "library", "action": "create_playlist", "name": name})

proc deletePlaylist*(cli: DaemonClient, playlistId: int64): JsonNode =
  cli.ensureDaemon()
  sendDaemonCmd(cli, %*{"cmd": "library", "action": "delete_playlist", "id": playlistId})

proc renamePlaylist*(cli: DaemonClient, playlistId: int64, name: string): JsonNode =
  cli.ensureDaemon()
  sendDaemonCmd(cli, %*{"cmd": "library", "action": "rename_playlist", "playlist_id": playlistId, "name": name})

proc addToPlaylist*(cli: DaemonClient, playlistId, trackId: int64, position: int = 0): JsonNode =
  cli.ensureDaemon()
  sendDaemonCmd(cli, %*{"cmd": "library", "action": "add_to_playlist", "playlist_id": playlistId, "track_ids": [trackId], "position": position})

proc removeFromPlaylist*(cli: DaemonClient, playlistId, trackId: int64): JsonNode =
  cli.ensureDaemon()
  sendDaemonCmd(cli, %*{"cmd": "library", "action": "remove_from_playlist", "playlist_id": playlistId, "track_id": trackId})

proc listPlaylists*(cli: DaemonClient): JsonNode =
  cli.ensureDaemon()
  sendDaemonCmd(cli, %*{"cmd": "library", "action": "get_playlists"})

proc getPlaylistTracks*(cli: DaemonClient, playlistId: int64): JsonNode =
  cli.ensureDaemon()
  sendDaemonCmd(cli, %*{"cmd": "library", "action": "get_playlist_tracks", "playlist_id": playlistId})

proc setShuffle*(cli: DaemonClient, enabled: bool): JsonNode =
  cli.ensureDaemon()
  sendDaemonCmd(cli, %*{"cmd": "toggle_shuffle"})

proc setRepeat*(cli: DaemonClient, mode: int): JsonNode =
  cli.ensureDaemon()
  let modeStr = case mode
    of 2: "one"
    of 1: "all"
    else: "off"
  sendDaemonCmd(cli, %*{"cmd": "cycle_repeat", "mode": modeStr})

proc setSleepTimer*(cli: DaemonClient, minutes: int): JsonNode =
  cli.ensureDaemon()
  sendDaemonCmd(cli, %*{"cmd": "set_sleep_timer", "minutes": minutes})

proc cancelSleepTimer*(cli: DaemonClient): JsonNode =
  cli.ensureDaemon()
  sendDaemonCmd(cli, %*{"cmd": "cancel_sleep_timer"})

proc getDaemonState*(cli: DaemonClient): JsonNode =
  cli.ensureDaemon()
  sendDaemonCmd(cli, %*{"cmd": "get_status"})

proc resumePlayback*(cli: DaemonClient): JsonNode =
  cli.ensureDaemon()
  sendDaemonCmd(cli, %*{"cmd": "play_pause"})

proc toggleMute*(cli: DaemonClient): JsonNode =
  cli.ensureDaemon()
  sendDaemonCmd(cli, %*{"cmd": "toggle_mute"})

proc search*(cli: DaemonClient, query: string): JsonNode =
  cli.ensureDaemon()
  sendDaemonCmd(cli, %*{"cmd": "search", "query": query})

proc checkHealth*(cli: DaemonClient): JsonNode =
  cli.ensureDaemon()
  sendDaemonCmd(cli, %*{"cmd": "check_health"})

proc getLibrary*(cli: DaemonClient): JsonNode =
  cli.ensureDaemon()
  sendDaemonCmd(cli, %*{"cmd": "library", "action": "get_tracks"})

proc addTrack*(cli: DaemonClient, data: JsonNode): JsonNode =
  cli.ensureDaemon()
  var params = %*{"cmd": "library", "action": "add_track"}
  for k, v in data:
    params[k] = v
  sendDaemonCmd(cli, params)

proc updateTrackPath*(cli: DaemonClient, oldPath, newPath, newTitle: string): JsonNode =
  cli.ensureDaemon()
  sendDaemonCmd(cli, %*{"cmd": "library", "action": "update_metadata", "old_path": oldPath, "new_path": newPath, "title": newTitle})

proc updateTrackMetadata*(cli: DaemonClient, trackId: int64, title, artist, album, genre: string, year, trackNum: int): JsonNode =
  cli.ensureDaemon()
  sendDaemonCmd(cli, %*{"cmd": "library", "action": "update_metadata", "track_id": trackId,
    "title": title, "artist": artist, "album": album, "genre": genre,
    "year": year, "track_number": trackNum})

proc scanDir*(cli: DaemonClient, path: string): JsonNode =
  cli.ensureDaemon()
  sendDaemonCmd(cli, %*{"cmd": "library", "action": "scan", "path": path})

proc queueAdd*(cli: DaemonClient, items: seq[tuple[path, title, channel: string]]): JsonNode =
  cli.ensureDaemon()
  var paths = newJArray()
  for (path, title, channel) in items:
    paths.add(%*{"path": path, "title": title, "channel": channel})
  sendDaemonCmd(cli, %*{"cmd": "queue", "action": "add", "paths": paths})

proc queueAddPaths*(cli: DaemonClient, paths: seq[string]): JsonNode =
  cli.ensureDaemon()
  var arr = newJArray()
  for p in paths:
    arr.add(%p)
  sendDaemonCmd(cli, %*{"cmd": "queue", "action": "add", "paths": arr})

proc queueMove*(cli: DaemonClient, fromIdx, toIdx: int): JsonNode =
  cli.ensureDaemon()
  sendDaemonCmd(cli, %*{"cmd": "queue", "action": "move", "from": fromIdx, "to": toIdx})

proc queueSet*(cli: DaemonClient, paths: seq[string]): JsonNode =
  cli.ensureDaemon()
  var arr = newJArray()
  for p in paths:
    arr.add(%p)
  sendDaemonCmd(cli, %*{"cmd": "queue", "action": "set", "paths": arr})

proc queueRemove*(cli: DaemonClient, index: int): JsonNode =
  cli.ensureDaemon()
  sendDaemonCmd(cli, %*{"cmd": "queue", "action": "remove", "index": index})

proc queueClear*(cli: DaemonClient): JsonNode =
  cli.ensureDaemon()
  sendDaemonCmd(cli, %*{"cmd": "queue", "action": "clear"})

proc queueList*(cli: DaemonClient): JsonNode =
  cli.ensureDaemon()
  sendDaemonCmd(cli, %*{"cmd": "queue", "action": "list"})

proc queueRemovePath*(cli: DaemonClient, path: string): JsonNode =
  let listResp = queueList(cli)
  if listResp.hasKey("queue"):
    let q = listResp["queue"]
    for i in 0..<q.len:
      if q[i].getStr() == path:
        return queueRemove(cli, i)
  result = %*{"ok": true}

proc queueSetCursor*(cli: DaemonClient, index: int): JsonNode =
  cli.ensureDaemon()
  sendDaemonCmd(cli, %*{"cmd": "queue_set_cursor", "index": index})

proc addFavourite*(cli: DaemonClient, trackId: int64): JsonNode =
  cli.ensureDaemon()
  sendDaemonCmd(cli, %*{"cmd": "add_favourite", "track_id": trackId})

proc removeFavourite*(cli: DaemonClient, trackId: int64): JsonNode =
  cli.ensureDaemon()
  sendDaemonCmd(cli, %*{"cmd": "remove_favourite", "track_id": trackId})

proc getFavouritesFromDaemon*(cli: DaemonClient): JsonNode =
  cli.ensureDaemon()
  sendDaemonCmd(cli, %*{"cmd": "get_favourites"})

proc getFullState*(cli: DaemonClient): JsonNode =
  cli.ensureDaemon()
  sendDaemonCmd(cli, %*{"cmd": "get_status"})

proc ytSearch*(cli: DaemonClient, query: string, pageSize: int = 10) =
  cli.ensureDaemon()
  sendOnly(cli, %*{"cmd": "yt_search", "query": query, "page_size": pageSize})

proc ytSearchPoll*(cli: DaemonClient): JsonNode =
  cli.ensureDaemon()
  sendDaemonCmd(cli, %*{"cmd": "yt_search_poll"})

proc ytSearchCancel*(cli: DaemonClient) =
  cli.ensureDaemon()
  sendOnly(cli, %*{"cmd": "yt_search_cancel"})

proc ytResolveStream*(cli: DaemonClient, url, title, channel: string): JsonNode =
  cli.ensureDaemon()
  sendDaemonCmd(cli, %*{"cmd": "yt_resolve_stream", "url": url, "title": title, "channel": channel})

proc ytResolveStreamPoll*(cli: DaemonClient): JsonNode =
  cli.ensureDaemon()
  sendDaemonCmd(cli, %*{"cmd": "yt_resolve_stream_poll"})

proc ytDownload*(cli: DaemonClient, url, title, channel: string): JsonNode =
  cli.ensureDaemon()
  sendDaemonCmd(cli, %*{"cmd": "yt_download", "url": url, "title": title, "channel": channel})

proc ytDownloadPoll*(cli: DaemonClient): JsonNode =
  cli.ensureDaemon()
  sendDaemonCmd(cli, %*{"cmd": "yt_download_poll"})

proc ytCancelDownload*(cli: DaemonClient, url: string): JsonNode =
  cli.ensureDaemon()
  sendDaemonCmd(cli, %*{"cmd": "yt_cancel_download", "url": url})

proc ytListDownloads*(cli: DaemonClient): JsonNode =
  cli.ensureDaemon()
  sendDaemonCmd(cli, %*{"cmd": "yt_list_downloads"})

proc ytFetchPlaylist*(cli: DaemonClient, url: string): JsonNode =
  cli.ensureDaemon()
  sendDaemonCmd(cli, %*{"cmd": "yt_fetch_playlist", "url": url})

proc ytFetchPlaylistPoll*(cli: DaemonClient): JsonNode =
  cli.ensureDaemon()
  sendDaemonCmd(cli, %*{"cmd": "yt_fetch_playlist_poll"})

proc ping*(cli: DaemonClient): bool =
  cli.ensureDaemon()
  let resp = sendDaemonCmd(cli, %*{"cmd": "ping"})
  result = resp.hasKey("pong") and resp["pong"].getBool(false)

proc ytSetConfig*(cli: DaemonClient, cookieSource, jsRuntime, downloadDir: string, maxConcurrent: int): JsonNode =
  cli.ensureDaemon()
  sendDaemonCmd(cli, %*{"cmd": "yt_set_config", "cookie_source": cookieSource, "js_runtime": jsRuntime, "download_dir": downloadDir, "max_concurrent": maxConcurrent})

proc ytGetSearchHistory*(cli: DaemonClient): JsonNode =
  cli.ensureDaemon()
  sendDaemonCmd(cli, %*{"cmd": "yt_get_search_history"})

proc ytClearSearchHistory*(cli: DaemonClient): JsonNode =
  cli.ensureDaemon()
  sendDaemonCmd(cli, %*{"cmd": "yt_clear_search_history"})

proc getEqPresets*(cli: DaemonClient): JsonNode =
  cli.ensureDaemon()
  sendDaemonCmd(cli, %*{"cmd": "list_eq_presets"})

proc setReverb*(cli: DaemonClient, enabled: bool, roomScale: float): JsonNode =
  cli.ensureDaemon()
  sendDaemonCmd(cli, %*{"cmd": "set_reverb", "enabled": enabled, "room_size": roomScale})

proc setLoudnessMode*(cli: DaemonClient, mode: string): JsonNode =
  cli.ensureDaemon()
  sendDaemonCmd(cli, %*{"cmd": "set_loudness_mode", "mode": mode})

proc scanLoudness*(cli: DaemonClient, force: bool = false, trackIds: seq[int64] = @[]): JsonNode =
  cli.ensureDaemon()
  if trackIds.len > 0:
    sendDaemonCmd(cli, %*{"cmd": "scan_loudness", "force": force, "track_ids": trackIds})
  else:
    sendDaemonCmd(cli, %*{"cmd": "scan_loudness", "force": force})

proc setPreGain*(cli: DaemonClient, preGainDb: float): JsonNode =
  cli.ensureDaemon()
  sendDaemonCmd(cli, %*{"cmd": "set_pre_gain", "pre_gain_db": preGainDb})

proc setGapless*(cli: DaemonClient, enabled: bool): JsonNode =
  cli.ensureDaemon()
  sendDaemonCmd(cli, %*{"cmd": "set_gapless", "enabled": enabled})

proc setDynamicMode*(cli: DaemonClient, enabled: bool): JsonNode =
  cli.ensureDaemon()
  sendDaemonCmd(cli, %*{"cmd": "set_dynamic_mode", "enabled": enabled})

proc setScrobble*(cli: DaemonClient, enabled: bool): JsonNode =
  cli.ensureDaemon()
  sendDaemonCmd(cli, %*{"cmd": "set_scrobble", "enabled": enabled})

proc organizeLibrary*(cli: DaemonClient, dryRun: bool = true): JsonNode =
  cli.ensureDaemon()
  sendDaemonCmd(cli, %*{"cmd": "organize_library", "dry_run": dryRun})

proc getCoverArt*(cli: DaemonClient, trackId: int64): JsonNode =
  cli.ensureDaemon()
  sendDaemonCmd(cli, %*{"cmd": "get_cover_art", "track_id": trackId})

proc getLyrics*(cli: DaemonClient, trackId: int64): JsonNode =
  cli.ensureDaemon()
  sendDaemonCmd(cli, %*{"cmd": "get_lyrics", "track_id": trackId})

proc syncCovers*(cli: DaemonClient) =
  cli.ensureDaemon()
  sendOnly(cli, %*{"cmd": "sync_covers"})

proc syncLyrics*(cli: DaemonClient) =
  cli.ensureDaemon()
  sendOnly(cli, %*{"cmd": "sync_lyrics"})

proc libraryAction*(cli: DaemonClient, action: string): JsonNode =
  cli.ensureDaemon()
  sendDaemonCmd(cli, %*{"cmd": "library", "action": action})

proc newDaemonClient*(): DaemonClient =
  DaemonClient(
    volume: 80, state: 0, running: false,
    connected: false, buf: "", backendType: abtDaemon,
    working: true, sleepTimerRemaining: 0,
    # Per client.md §Sending Commands: 5 second response timeout.
    ipcTimeoutSec: 5.0, nextRetryAt: 0.0, retryDelayMs: 100,
    connectionAttempts: 0, firstConnection: true,
    lastDataAt: 0.0, nextId: 0, pending: @[]
  )
