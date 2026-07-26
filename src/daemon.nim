import os, json, strutils, net, posix, random, osproc, times, tables
from nativesockets import setBlocking, selectRead, SocketHandle
import msgpack4nim
import msgpack4nim/msgpack2json
proc prctl(option: cint, arg2: cstring): cint {.importc, header: "<sys/prctl.h>".}
import audio, state, library, ytdlp

var signalFlag* {.threadvar.}: bool

proc parseFilenameForMetadata(path: string): tuple[title, artist: string] =
  let (_, stem, _) = path.splitFile()
  result = (stem, "")
  let dashPos = stem.find(" - ")
  if dashPos > 0:
    let left = stem[0..<dashPos].strip()
    var isTrackNum = left.len in {2, 3}
    if isTrackNum:
      for c in left:
        if c notin {'0'..'9'}: isTrackNum = false; break
    if not isTrackNum:
      result.artist = left
      result.title = stem[dashPos+3..^1].strip()

type
  DaemonCmdKind* = enum
    dckPlay, dckPause, dckStop, dckSeek, dckNext, dckPrev,
    dckSetVolume, dckGetVolume,
    dckPlayPause,
    dckQuit, dckGetStatus,
    dckToggleShuffle, dckCycleRepeat, dckSetSleepTimer, dckCancelSleepTimer,
    dckCrossfade,
    dckSetEqPreset, dckSetEqEnabled, dckListEqPresets,
    dckAddFavourite, dckRemoveFavourite, dckGetFavourites,
    dckYtSearch, dckYtSearchPoll, dckYtSearchCancel,
    dckYtResolveStream, dckYtResolveStreamPoll,
    dckYtDownload, dckYtDownloadPoll, dckYtCancelDownload,
    dckYtListDownloads, dckYtFetchPlaylist, dckYtFetchPlaylistPoll,
    dckYtSetConfig, dckYtGetSearchHistory, dckYtClearSearchHistory,
    dckPing,
    dckHandshake,
    dckCheckHealth, dckToggleMute, dckSearch,
    dckQueue, dckLibrary,
    dckQueueSetCursor,
    dckUnknown

  DaemonCmd* = object
    kind*: DaemonCmdKind
    strArg*: string
    floatArg*: float
    intArg*: int
    strArg2*: string
    strArg3*: string


  ClientState* = object
    sock*: Socket
    buf*: string
    authenticated*: bool
    id*: uint64
    framesSinceConnect*: int

  Daemon* = ref object
    player: AudioBackend
    lib: LibraryDb
    running: bool
    server: Socket
    state*: DaemonState
    clients*: seq[ClientState]
    currentTrackPath: string
    currentTrackTitle: string
    currentTrackChannel: string
    trackHistory: seq[string]
    idleFrames: int
    idleTimeout: int
    shuffleEnabled*: bool
    repeatMode*: int
    sleepTimerRemaining*: int
    sleepTimerFrames*: int
    persistFrames: int
    heartbeatFrames: int
    pulseServer: Socket
    pulseClients: seq[Socket]
    playbackQueue*: seq[string]
    shuffleOrder*: seq[int]
    shuffleIndex*: int
    crossfadeDuration*: int
    crossfadeCurve*: int
    crossfadePrepared*: bool
    crossfadeStarted*: bool
    crossfadeNextPath*: string
    crossfadeConsumed: bool
    autoAdvancing*: bool
    lastConsumedFromQueue: seq[string]
    upNextSent: bool
    # Background scan state
    scanningDir: string
    scanningFiles: seq[string]
    scanningIdx: int
    # yt-dlp state
    ytCookieSource: string
    ytJsRuntime: string
    ytDownloadDir: string
    ytMaxConcurrentDownloads: int
    ytSearchProcess: Process
    ytSearchBuf: string
    ytSearchActive: bool
    ytSearchQuery: string
    ytSearchResults: seq[YtSearchResult]
    ytStreamProcess: Process
    ytStreamBuf: string
    ytStreamActive: bool
    ytStreamResultUrl: string
    ytStreamPendingTitle: string
    ytStreamPendingChannel: string
    ytStreamPendingDuration: string
    ytStreamUrls: Table[string, string]
    ytStreamResolveProcess: Process
    ytStreamResolveBuf: string
    ytStreamResolveUrl: string
    ytStreamResolving: bool
    ytDownloadTasks: seq[DownloadTask]
    ytDownloaded: Table[string, string]
    ytDownloadedMeta: Table[string, tuple[title, channel: string]]
    ytLastCompletedPath: string
    ytLastCompletedUrl: string
    ytPlaylistProcess: Process
    ytPlaylistBuf: string
    ytPlaylistActive: bool
    ytPlaylistResult: YtPlaylistDetail
    ytPlaylistUrl: string

proc writePidFile() =
  let dir = stateDir()
  if not dirExists(dir): createDir(dir)
  writeFile(pidPath(), $getpid())

proc removePidFile() =
  try: removeFile(pidPath()) except: stderr.writeLine("[gtm] removePidFile: " & getCurrentExceptionMsg())

proc setupSignalHandlers() =
  proc handler(sig: cint) {.noconv.} =
    signalFlag = true
  signal(SIGINT, handler)
  signal(SIGTERM, handler)

proc parseDaemonCommand(line: string): DaemonCmd =
  try:
    let j = parseJson(line)
    let cmd = j["cmd"].getStr()
    case cmd
    of "play":
      result.kind = dckPlay; result.strArg = j{"path"}.getStr("")
      result.floatArg = j{"start_pos"}.getFloat(0.0)
      result.strArg2 = j{"title"}.getStr("")
      result.strArg3 = j{"channel"}.getStr("")
    of "pause": result.kind = dckPause
    of "stop": result.kind = dckStop
    of "play_pause": result.kind = dckPlayPause
    of "seek":
      result.kind = dckSeek; result.floatArg = j{"position_secs"}.getFloat(5.0)
    of "next": result.kind = dckNext
    of "prev": result.kind = dckPrev
    of "set_volume":
      result.kind = dckSetVolume; result.intArg = j{"volume"}.getInt(80)
    of "get_volume": result.kind = dckGetVolume
    of "quit": result.kind = dckQuit
    of "get_status": result.kind = dckGetStatus
    of "queue":
      result.kind = dckQueue
      result.strArg = j{"action"}.getStr("")
    of "library":
      result.kind = dckLibrary
      result.strArg = j{"action"}.getStr("")
    of "toggle_shuffle": result.kind = dckToggleShuffle
    of "cycle_repeat":
      result.kind = dckCycleRepeat
      let modeStr = j{"mode"}.getStr("off")
      result.intArg = case modeStr
        of "one": 2
        of "all": 1
        else: 0
    of "set_sleep_timer":
      result.kind = dckSetSleepTimer; result.intArg = j{"minutes"}.getInt(0)
    of "cancel_sleep_timer": result.kind = dckCancelSleepTimer
    of "crossfade":
      result.kind = dckCrossfade
      if j.hasKey("enabled"):
        result.intArg = if j["enabled"].getBool(false): 1 else: 0
      else:
        result.intArg = 1
      result.floatArg = j{"duration_secs"}.getFloat(5.0)
      result.strArg = j{"easing"}.getStr("equal_power")
    of "set_eq_preset":
      result.kind = dckSetEqPreset; result.strArg = j{"preset"}.getStr("")
    of "set_eq_enabled":
      result.kind = dckSetEqEnabled
      result.intArg = if j{"enabled"}.getBool(true): 1 else: 0
    of "queue_set_cursor":
      result.kind = dckQueueSetCursor; result.intArg = j{"index"}.getInt(0)
    of "add_favourite":
      result.kind = dckAddFavourite; result.intArg = j{"track_id"}.getInt(0)
    of "remove_favourite":
      result.kind = dckRemoveFavourite; result.intArg = j{"track_id"}.getInt(0)
    of "get_favourites": result.kind = dckGetFavourites
    of "yt_search":
      result.kind = dckYtSearch; result.strArg = j{"query"}.getStr(""); result.intArg = j{"page_size"}.getInt(10)
    of "yt_search_poll": result.kind = dckYtSearchPoll
    of "yt_search_cancel": result.kind = dckYtSearchCancel
    of "yt_resolve_stream":
      result.kind = dckYtResolveStream; result.strArg = j{"url"}.getStr("")
      result.strArg2 = j{"title"}.getStr(""); result.strArg3 = j{"channel"}.getStr("")
    of "yt_resolve_stream_poll": result.kind = dckYtResolveStreamPoll
    of "yt_download":
      result.kind = dckYtDownload; result.strArg = j{"url"}.getStr("")
      result.strArg2 = j{"title"}.getStr(""); result.strArg3 = j{"channel"}.getStr("")
    of "yt_download_poll": result.kind = dckYtDownloadPoll
    of "yt_cancel_download":
      result.kind = dckYtCancelDownload; result.strArg = j{"url"}.getStr("")
    of "yt_list_downloads": result.kind = dckYtListDownloads
    of "yt_fetch_playlist":
      result.kind = dckYtFetchPlaylist; result.strArg = j{"url"}.getStr("")
    of "yt_fetch_playlist_poll": result.kind = dckYtFetchPlaylistPoll
    of "yt_set_config":
      result.kind = dckYtSetConfig; result.strArg = j{"cookie_source"}.getStr("")
      result.strArg2 = j{"js_runtime"}.getStr(""); result.strArg3 = j{"download_dir"}.getStr("")
      result.intArg = j{"max_concurrent"}.getInt(4)
    of "yt_get_search_history": result.kind = dckYtGetSearchHistory
    of "yt_clear_search_history": result.kind = dckYtClearSearchHistory
    of "list_eq_presets": result.kind = dckListEqPresets
    of "toggle_mute": result.kind = dckToggleMute
    of "search":
      result.kind = dckSearch; result.strArg = j{"query"}.getStr("")
    of "check_health": result.kind = dckCheckHealth
    of "ping": result.kind = dckPing
    of "handshake": result.kind = dckHandshake
    else:
      result.kind = dckUnknown
      result.strArg = cmd
  except CatchableError:
    result.kind = dckUnknown
    result.strArg = "<malformed>"

proc serializeEvents(events: seq[AudioEvent]; d: Daemon = nil): seq[string] =
  result = @[]
  for ev in events:
    var obj = %*{"event": %eventName(ev.kind)}
    case ev.kind
    of aekPositionChanged: obj["time_pos"] = %ev.floatVal
    of aekDurationChanged: obj["duration"] = %ev.floatVal
    of aekVolumeChanged: obj["volume"] = %ev.intVal
    of aekPlaybackStarted:
      if d != nil:
        obj["track"] = %*{
          "id": %d.currentTrackPath,
          "title": %d.currentTrackTitle,
          "artist": %d.currentTrackChannel,
          "path": %d.currentTrackPath,
          "duration": %d.player.duration,
          "cover_art": "",
          "favourite": false
        }
        obj["auto_advanced"] = %d.autoAdvancing
        obj["time_pos"] = %d.player.timePos
        obj["duration"] = %d.player.duration
    of aekPlaybackPaused:
      if d != nil: obj["time_pos"] = %d.player.timePos
    of aekPlaybackStopped: discard
    of aekTrackEnded: discard
    of aekMetadataChanged:
      if ev.strVal.len > 0: obj["name"] = %ev.strVal
    of aekShuffleChanged: obj["enabled"] = %ev.intVal
    of aekRepeatModeChanged: obj["mode"] = %ev.strVal
    of aekQueueIndexChanged: obj["index"] = %ev.intVal
    of aekCrossfadeChanged:
      obj["enabled"] = %ev.intVal
      obj["duration_secs"] = %ev.floatVal
    of aekEqPresetChanged: obj["preset"] = %ev.strVal
    of aekEqEnabledChanged: obj["enabled"] = %ev.intVal
    of aekSleepTimerTick: obj["remaining_secs"] = %ev.intVal
    of aekSleepTimerExpired: discard
    else: discard
    result.add($obj)

proc broadcastAll(d: Daemon, data: string) =
  var alive: seq[ClientState]
  for c in d.clients:
    if c.authenticated:
      if trySend(c.sock, data):
        alive.add(c)
      else:
        try: c.sock.close() except: discard
    else:
      alive.add(c)
  d.clients = alive

proc broadcastAllLines(d: Daemon, lines: seq[string]) =
  for line in lines:
    d.broadcastAll(line & "\n")

proc broadcastPulse(d: Daemon, evJson: JsonNode) =
  if d.pulseClients.len == 0: return
  let payload = fromJsonNode(evJson)
  var lenBuf: array[4, byte]
  let plen = payload.len
  lenBuf[0] = byte((plen shr 24) and 0xFF)
  lenBuf[1] = byte((plen shr 16) and 0xFF)
  lenBuf[2] = byte((plen shr 8) and 0xFF)
  lenBuf[3] = byte(plen and 0xFF)
  var frame = newString(4 + plen)
  copyMem(addr frame[0], addr lenBuf[0], 4)
  copyMem(addr frame[4], unsafeAddr payload[0], plen)
  var alive: seq[Socket]
  for pc in d.pulseClients:
    if trySend(pc, frame):
      alive.add(pc)
    else:
      try: pc.close() except: discard
  d.pulseClients = alive

proc broadcastEvent(d: Daemon, evJson: JsonNode) =
  d.broadcastAll($evJson & "\n")
  d.broadcastPulse(evJson)

proc sendQueueEvent(d: Daemon) =
  if d.clients.len == 0: return
  var qArr = newJArray()
  for p in d.playbackQueue: qArr.add(%p)
  var soArr = newJArray()
  for i in d.shuffleOrder: soArr.add(%i)
  let ev = %*{"event": "queue_changed",
    "queue": qArr, "shuffleOrder": soArr, "shuffleIndex": %d.shuffleIndex}
  d.broadcastEvent(ev)

proc savePlaybackState(d: Daemon) =
  if d.lib != nil:
    d.lib.setPlaybackState("volume", $d.player.volume)
    d.lib.setPlaybackState("track_path", d.currentTrackPath)
    d.lib.setPlaybackState("track_title", d.currentTrackTitle)
    d.lib.setPlaybackState("track_channel", d.currentTrackChannel)
    d.lib.setPlaybackState("state", $(d.player.state))
    d.lib.setPlaybackState("shuffle", $(d.shuffleEnabled))
    d.lib.setPlaybackState("repeat", $(d.repeatMode))
    d.lib.setPlaybackState("sleep_timer", $(d.sleepTimerRemaining))
    d.lib.setPlaybackState("crossfade_duration", $(d.crossfadeDuration))
    d.lib.setPlaybackState("crossfade_curve", $(d.crossfadeCurve))
    d.lib.setPlaybackState("yt_cookie_source", d.ytCookieSource)
    d.lib.setPlaybackState("yt_js_runtime", d.ytJsRuntime)
    d.lib.setPlaybackState("yt_download_dir", d.ytDownloadDir)
    d.lib.setPlaybackState("yt_max_concurrent", $(d.ytMaxConcurrentDownloads))
    var qArr = newJArray()
    for p in d.playbackQueue:
      qArr.add(%p)
    d.lib.setPlaybackState("queue_json", $qArr)
  d.state.saveDaemonState()


proc gracefulShutdown(d: Daemon) =
  if not d.running: return
  d.savePlaybackState()
  when defined(useMpris):
    shutdownMpris()
  if d.lib != nil:
    d.lib.closeDb()
  if d.player != nil:
    d.player.shutdown()
  d.running = false


proc shuffleOrder(count: int): seq[int] =
  result = newSeq[int](count)
  for i in 0..<count:
    result[i] = i
  for i in countup(0, count - 2):
    let j = rand(i..<count)
    swap(result[i], result[j])

proc nextTrackFromQueue(d: Daemon): string =
  if d.shuffleEnabled and d.shuffleOrder.len > 0:
    if d.shuffleIndex < d.shuffleOrder.len:
      let idx = d.shuffleOrder[d.shuffleIndex]
      if idx >= 0 and idx < d.playbackQueue.len:
        result = d.playbackQueue[idx]
      d.shuffleIndex.inc
    if d.shuffleIndex >= d.shuffleOrder.len:
      if d.repeatMode == 1:
        d.shuffleOrder = shuffleOrder(d.playbackQueue.len)
        d.shuffleIndex = 0
        if d.shuffleOrder.len > 0:
          result = d.playbackQueue[d.shuffleOrder[0]]
          d.shuffleIndex = 1
      else:
        result = ""
  elif d.playbackQueue.len > 0:
    result = d.playbackQueue[0]
    d.playbackQueue.delete(0)
    if d.repeatMode == 1 and result.len > 0:
      d.playbackQueue.add(result)
  if result.len > 0:
    d.lastConsumedFromQueue.add(result)
    if d.lastConsumedFromQueue.len > 10:
      d.lastConsumedFromQueue.delete(0)

proc pushTrackHistory(d: Daemon, newPath: string) =
  if d.currentTrackPath.len > 0 and d.currentTrackPath != newPath:
    d.trackHistory.add(d.currentTrackPath)
    if d.trackHistory.len > 50:
      d.trackHistory.delete(0)

proc advanceToNextTrack(d: Daemon, forward: bool = true): bool =
  d.autoAdvancing = true
  d.upNextSent = false
  if forward:
    if d.playbackQueue.len == 0: return false
    # Peek at next candidate without consuming
    var nextCandidate = ""
    if d.shuffleEnabled and d.shuffleIndex < d.shuffleOrder.len:
      let sIdx = d.shuffleOrder[d.shuffleIndex]
      if sIdx >= 0 and sIdx < d.playbackQueue.len:
        nextCandidate = d.playbackQueue[sIdx]
    elif not d.shuffleEnabled:
      nextCandidate = d.playbackQueue[0]
    if nextCandidate.len == 0: return false
    # Resolve YouTube watch URLs: prefer downloaded file, fall back to stream URL
    var loadPath = nextCandidate
    if isYtWatchUrl(nextCandidate):
      if nextCandidate in d.ytDownloaded:
        loadPath = d.ytDownloaded[nextCandidate]
        if nextCandidate in d.ytDownloadedMeta:
          d.currentTrackTitle = d.ytDownloadedMeta[nextCandidate].title
          d.currentTrackChannel = d.ytDownloadedMeta[nextCandidate].channel
      elif nextCandidate in d.ytStreamUrls:
        loadPath = d.ytStreamUrls[nextCandidate]
        # Use pending download metadata as fallback for title/channel
        if nextCandidate in d.ytDownloadedMeta:
          d.currentTrackTitle = d.ytDownloadedMeta[nextCandidate].title
          d.currentTrackChannel = d.ytDownloadedMeta[nextCandidate].channel
        elif d.currentTrackPath != loadPath:
          for t in d.ytDownloadTasks:
            if t.url == nextCandidate and t.title.len > 0:
              d.currentTrackTitle = t.title
              d.currentTrackChannel = t.channel
              break
        # Ensure download is running in background
        var alreadyDL = false
        for t in d.ytDownloadTasks:
          if t.url == nextCandidate: alreadyDL = true; break
        if not alreadyDL and d.lib != nil:
          var meta = if nextCandidate in d.ytDownloadedMeta: d.ytDownloadedMeta[nextCandidate] else: (title: "", channel: "")
          var task: DownloadTask
          if startDownload(YtSearchResult(url: nextCandidate, title: meta.title, channel: meta.channel), d.ytDownloadDir, task.process, d.ytCookieSource, d.ytJsRuntime):
            task.title = meta.title; task.url = nextCandidate; task.channel = meta.channel
            task.outputDir = d.ytDownloadDir; task.completed = false; task.startedAt = epochTime()
            d.ytDownloadTasks.add(task)
      else:
        # Start resolving stream URL and retry next frame
        if not d.ytStreamResolving or d.ytStreamResolveUrl != nextCandidate:
          try: d.ytStreamResolveProcess.terminate() except: discard
          close(d.ytStreamResolveProcess)
          d.ytStreamResolveBuf = ""
          d.ytStreamResolveUrl = nextCandidate
          discard startStreamUrlFetch(nextCandidate, d.ytStreamResolveProcess, d.ytCookieSource, d.ytJsRuntime)
          d.ytStreamResolving = true
        return false
    # Consume and play
    let consumed = d.nextTrackFromQueue()
    if consumed.len == 0: return false
    d.pushTrackHistory(loadPath)
    if d.crossfadeDuration > 0 and d.player.state == 1:
      # Crossfade transition
      d.crossfadeConsumed = true
      d.player.prepareNext(loadPath)
      d.player.startCrossfade(float(d.crossfadeDuration))
      d.currentTrackPath = loadPath
      d.crossfadePrepared = false
      d.crossfadeStarted = false
      d.crossfadeNextPath = ""
    else:
      d.player.stop()
      d.player.loadFile(loadPath)
      d.currentTrackPath = loadPath
      d.player.play()
    d.idleFrames = 0
    if d.lib != nil:
      let trackId = d.lib.findTrackByPath(loadPath)
      if trackId > 0:
        d.lib.updatePlayCount(trackId)
    return true

when defined(useMpris):
  include mpris

proc executeQueueCommand(d: Daemon, action: string, cmdJson: JsonNode): JsonNode =
  result = %*{"ok": true}
  case action
  of "list":
    var arr = newJArray()
    for p in d.playbackQueue:
      arr.add(%p)
    result["queue"] = arr
  of "clear":
    d.playbackQueue = @[]
    d.shuffleOrder = @[]
    d.shuffleIndex = 0
    d.sendQueueEvent()
  of "add":
    let path = cmdJson{"path"}.getStr("")
    let position = cmdJson{"position"}.getInt(-1)
    if path.len > 0:
      if position >= 0 and position < d.playbackQueue.len:
        d.playbackQueue.insert(path, position)
      else:
        d.playbackQueue.add(path)
      if isYtWatchUrl(path) and path notin d.ytDownloaded:
        var alreadyDL = false
        for task in d.ytDownloadTasks:
          if task.url == path:
            alreadyDL = true
            break
        if not alreadyDL:
          var task: DownloadTask
          if startDownload(YtSearchResult(url: path), d.ytDownloadDir, task.process, d.ytCookieSource, d.ytJsRuntime):
            task.title = ""
            task.url = path
            task.outputDir = d.ytDownloadDir
            task.completed = false
            task.startedAt = epochTime()
            d.ytDownloadTasks.add(task)
          else:
            stderr.writeLine("[gtm] Failed to start download for: " & path)
        if path notin d.ytStreamUrls and not d.ytStreamResolving:
          d.ytStreamResolveBuf = ""
          d.ytStreamResolveUrl = path
          discard startStreamUrlFetch(path, d.ytStreamResolveProcess, d.ytCookieSource, d.ytJsRuntime)
          d.ytStreamResolving = true
    d.sendQueueEvent()
  of "add_many":
    let paths = cmdJson{"paths"}
    if paths.kind == JArray:
      for item in paths:
        var path = ""
        var title = ""
        var channel = ""
        if item.kind == JString:
          path = item.getStr("")
        elif item.kind == JObject:
          path = item{"path"}.getStr("")
          title = item{"title"}.getStr("")
          channel = item{"channel"}.getStr("")
        if path.len > 0:
          d.playbackQueue.add(path)
          if isYtWatchUrl(path) and path notin d.ytDownloaded:
            var alreadyDL = false
            for task in d.ytDownloadTasks:
              if task.url == path:
                alreadyDL = true
                break
            if not alreadyDL:
              var task: DownloadTask
              if startDownload(YtSearchResult(url: path, title: title, channel: channel), d.ytDownloadDir, task.process, d.ytCookieSource, d.ytJsRuntime):
                task.title = title
                task.url = path
                task.channel = channel
                task.outputDir = d.ytDownloadDir
                task.completed = false
                task.startedAt = epochTime()
                d.ytDownloadTasks.add(task)
              else:
                stderr.writeLine("[gtm] Failed to start download for: " & path)
            if path notin d.ytStreamUrls and not d.ytStreamResolving:
              d.ytStreamResolveBuf = ""
              d.ytStreamResolveUrl = path
              discard startStreamUrlFetch(path, d.ytStreamResolveProcess, d.ytCookieSource, d.ytJsRuntime)
              d.ytStreamResolving = true
      d.sendQueueEvent()
  of "remove":
    let index = cmdJson{"index"}.getInt(0)
    if index >= 0 and index < d.playbackQueue.len:
      d.playbackQueue.delete(index)
    d.sendQueueEvent()
  of "move":
    let fromIdx = cmdJson{"from"}.getInt(0)
    let toIdx = cmdJson{"to"}.getInt(0)
    if fromIdx >= 0 and fromIdx < d.playbackQueue.len and toIdx >= 0 and toIdx < d.playbackQueue.len and fromIdx != toIdx:
      let track = d.playbackQueue[fromIdx]
      d.playbackQueue.delete(fromIdx)
      d.playbackQueue.insert(track, toIdx)
    d.sendQueueEvent()
  of "set":
    let paths = cmdJson{"paths"}
    if paths.kind == JArray:
      d.playbackQueue = @[]
      for item in paths:
        if item.kind == JString:
          let path = item.getStr("")
          if path.len > 0:
            d.playbackQueue.add(path)
    let startIdx = cmdJson{"start_idx"}.getInt(0)
    if startIdx >= 0 and startIdx < d.playbackQueue.len:
      d.shuffleIndex = startIdx
    d.sendQueueEvent()
  else:
    result["ok"] = %false
    result["error"] = %("unknown queue action: " & action)

proc executeLibraryCommand(d: Daemon, action: string, cmdJson: JsonNode): JsonNode =
  result = %*{"ok": true}
  case action
  of "scan":
    let path = cmdJson{"path"}.getStr("")
    if path.len > 0 and dirExists(path):
      if d.scanningDir.len > 0:
        result["scanning_already"] = %true
      else:
        d.scanningDir = path
        d.scanningFiles = scanDirectoryRecursive(path)
        d.scanningIdx = 0
        result["scanning"] = %true
        result["total_files"] = %d.scanningFiles.len
  of "get_tracks":
    if d.lib != nil:
      let dbTracks = d.lib.loadTracks()
      var arr = newJArray()
      for t in dbTracks:
        arr.add(%*{
          "id": %t.id, "path": %t.path, "title": %t.title,
          "artist": %t.artist, "album": %t.album, "duration": %t.duration,
          "track_num": %t.trackNum, "year": %t.year, "genre": %t.genre,
          "play_count": %t.playCount, "artist_id": %t.artistId,
          "album_id": %t.albumId, "is_favourite": %t.isFavourite,
          "added_at": %t.addedAt, "last_played": %t.lastPlayed
        })
      result["tracks"] = arr
      let dbArtists = d.lib.loadArtists()
      var artArr = newJArray()
      for a in dbArtists:
        artArr.add(%*{"id": %a.id, "name": %a.name})
      result["artists"] = artArr
      let dbAlbums = d.lib.loadAlbums()
      var albArr = newJArray()
      for a in dbAlbums:
        albArr.add(%*{"id": %a.id, "title": %a.title, "artist_id": %a.artistId, "artist_name": %a.artistName, "year": %a.year, "genre": %a.genre})
      result["albums"] = albArr
  of "get_playlists":
    if d.lib != nil:
      let pls = d.lib.loadPlaylists()
      var arr = newJArray()
      for pl in pls:
        arr.add(%*{"id": pl.id, "name": pl.name, "track_count": pl.trackIds.len})
      result["playlists"] = arr
  of "create_playlist":
    if d.lib != nil:
      let name = cmdJson{"name"}.getStr("")
      if name.len > 0:
        let id = d.lib.createPlaylist(name)
        result["playlist_id"] = %id
        let pls = d.lib.loadPlaylists()
        var arr = newJArray()
        for pl in pls:
          arr.add(%*{"id": pl.id, "name": pl.name, "track_count": pl.trackIds.len})
        result["playlists"] = arr
  of "delete_playlist":
    if d.lib != nil:
      let plId = int64(cmdJson{"id"}.getInt(0))
      if plId > 0:
        d.lib.deletePlaylist(plId)
        let pls = d.lib.loadPlaylists()
        var arr = newJArray()
        for pl in pls:
          arr.add(%*{"id": pl.id, "name": pl.name, "track_count": pl.trackIds.len})
        result["playlists"] = arr
  of "rename_playlist":
    if d.lib != nil:
      let plId = int64(cmdJson{"playlist_id"}.getInt(0))
      let name = cmdJson{"name"}.getStr("")
      if plId > 0 and name.len > 0:
        d.lib.renamePlaylist(plId, name)
        let pls = d.lib.loadPlaylists()
        var arr = newJArray()
        for pl in pls:
          arr.add(%*{"id": pl.id, "name": pl.name, "track_count": pl.trackIds.len})
        result["playlists"] = arr
  of "add_to_playlist":
    if d.lib != nil:
      let plId = int64(cmdJson{"playlist_id"}.getInt(0))
      let trackIds = cmdJson{"track_ids"}
      if plId > 0 and trackIds.kind == JArray:
        let pos = cmdJson{"position"}.getInt(0)
        var i = 0
        for tidNode in trackIds:
          let trackId = int64(tidNode.getInt(0))
          if trackId > 0:
            d.lib.addTrackToPlaylist(plId, trackId, pos + i)
            inc i
  of "remove_from_playlist":
    if d.lib != nil:
      let plId = int64(cmdJson{"playlist_id"}.getInt(0))
      let trackId = int64(cmdJson{"track_id"}.getInt(0))
      if plId > 0 and trackId > 0:
        d.lib.removeTrackFromPlaylist(plId, trackId)
  of "get_playlist_tracks":
    if d.lib != nil:
      let plId = int64(cmdJson{"playlist_id"}.getInt(0))
      if plId > 0:
        let pls = d.lib.loadPlaylists()
        for pl in pls:
          if pl.id == plId:
            var arr = newJArray()
            for tid in pl.trackIds:
              arr.add(%tid)
            result["track_ids"] = arr
            break
        result["playlist_id"] = %plId
  of "add_track":
    if d.lib != nil:
      let path = cmdJson{"path"}.getStr("")
      let title = cmdJson{"title"}.getStr("")
      let artist = cmdJson{"artist"}.getStr("")
      let album = cmdJson{"album"}.getStr("YouTube")
      let duration = cmdJson{"duration"}.getFloat(0.0)
      if path.len > 0:
        let trackId = d.lib.addTrack(path, title, artist, album, duration, 0, 0, "")
        result["track_id"] = %trackId
  of "update_metadata":
    if d.lib != nil:
      let oldPath = cmdJson{"old_path"}.getStr("")
      let newPath = cmdJson{"new_path"}.getStr("")
      let newTitle = cmdJson{"title"}.getStr("")
      if oldPath.len > 0 and newPath.len > 0:
        d.lib.updateTrackPath(oldPath, newPath, newTitle)
        result["updated"] = %true
  of "search":
    if d.lib != nil:
      let query = cmdJson{"query"}.getStr("")
      if query.len > 0:
        let tracks = d.lib.searchTracks(query)
        var arr = newJArray()
        for t in tracks:
          arr.add(%*{"id": %t.id, "path": %t.path, "title": %t.title,
            "artist": %t.artist, "album": %t.album, "duration": %t.duration})
        result["tracks"] = arr
  else:
    result["ok"] = %false
    result["error"] = %("unknown library action: " & action)

proc executeCommand(d: Daemon, cmd: DaemonCmd, cmdJson: JsonNode = nil): JsonNode =
  result = %*{"ok": true}
  if d.player == nil:
    result["ok"] = %false
    result["error"] = %"no audio backend"
    return
  case cmd.kind
  of dckPlay:
    if cmd.strArg.len > 0:
      d.upNextSent = false
      d.autoAdvancing = false
      if d.currentTrackPath.len > 0 and d.currentTrackPath != cmd.strArg:
        d.trackHistory.add(d.currentTrackPath)
        if d.trackHistory.len > 50:
          d.trackHistory.delete(0)
      d.player.stop()
      d.player.loadFile(cmd.strArg)
      d.currentTrackPath = cmd.strArg
      d.currentTrackTitle = cmd.strArg2
      d.currentTrackChannel = cmd.strArg3
      d.player.play()
      d.idleFrames = 0
      discard d.player.pollEvents()
      var trackId = d.lib.findTrackByPath(d.currentTrackPath)
      if trackId == 0 and d.currentTrackTitle.len > 0:
        trackId = d.lib.addTrack(d.currentTrackPath, d.currentTrackTitle, d.currentTrackChannel, "YouTube", 0.0, 0, 0, "")
      if trackId > 0:
        d.lib.updatePlayCount(trackId)
        result["track_id"] = %trackId
      let st = case d.player.state
        of 1: "playing"
        of 2: "paused"
        else: "stopped"
      result["state"] = %st
      result["duration"] = %d.player.duration
      result["time_pos"] = %d.player.timePos
      when defined(useMpris):
        emitMprisPlayerChanged(d)
  of dckPause:
    d.player.pause()
    when defined(useMpris):
      emitMprisPlayerChanged(d)
  of dckPlayPause:
    d.player.togglePause(); d.idleFrames = 0
    when defined(useMpris):
      emitMprisPlayerChanged(d)
  of dckStop:
    d.player.stop()
    when defined(useMpris):
      emitMprisPlayerChanged(d)
  of dckSeek:
    d.player.seek(cmd.floatArg)
    when defined(useMpris):
      let pos = int64(d.player.timePos * 1_000_000)
      emitMprisSeeked(pos)
  of dckNext:
    d.autoAdvancing = false
    discard d.advanceToNextTrack(true)
    d.sendQueueEvent()
    when defined(useMpris):
      emitMprisPlayerChanged(d)
  of dckPrev:
    d.autoAdvancing = false
    var prevPath = ""
    # Try last-consumed-from-queue first for queue-aware prev
    if d.lastConsumedFromQueue.len > 1:
      # last entry is the current track just consumed; entry before it is the one we want
      let idx = d.lastConsumedFromQueue.len - 2
      if idx >= 0:
        prevPath = d.lastConsumedFromQueue[idx]
        # Remove both last entries (current and previous) so replaying doesn't loop
        d.lastConsumedFromQueue.setLen(idx + 1)
    if prevPath.len == 0 and d.trackHistory.len > 0:
      prevPath = d.trackHistory.pop()
    if prevPath.len > 0:
      d.pushTrackHistory(prevPath)
      if d.crossfadeDuration > 0 and d.player.state == 1:
        d.player.prepareNext(prevPath)
        d.player.startCrossfade(float(d.crossfadeDuration), reverse = true)
        d.currentTrackPath = prevPath
        d.currentTrackTitle = ""
        d.currentTrackChannel = ""
        d.crossfadePrepared = false
        d.crossfadeStarted = false
        d.crossfadeNextPath = ""
        d.crossfadeConsumed = false
      else:
        d.player.stop()
        d.player.loadFile(prevPath)
        d.currentTrackPath = prevPath
        d.currentTrackTitle = ""
        d.currentTrackChannel = ""
        d.player.play()
      d.idleFrames = 0
      when defined(useMpris):
        emitMprisPlayerChanged(d)
      if d.lib != nil:
        var trackId = d.lib.findTrackByPath(prevPath)
        if trackId > 0:
          d.lib.updatePlayCount(trackId)
          result["track_id"] = %trackId
    else:
      d.player.stop()
      d.idleFrames = 0
      when defined(useMpris):
        emitMprisPlayerChanged(d)
  of dckSetVolume:
    d.player.setVolume(cmd.intArg)
    when defined(useMpris):
      emitMprisPlayerChanged(d)
  of dckGetVolume:
    result["volume"] = %d.player.volume
  of dckQuit:
    when defined(useMpris):
      shutdownMpris()
    d.savePlaybackState()
    if d.lib != nil:
      d.lib.closeDb()
    d.player.shutdown()
    d.running = false
  of dckGetStatus:
    let st = case d.player.state
      of 0: "stopped"
      of 1: "playing"
      of 2: "paused"
      else: "unknown"
    result["state"] = %st
    result["volume"] = %d.player.volume
    result["time_pos"] = %d.player.timePos
    result["duration"] = %d.player.duration
    result["track"] = %d.currentTrackPath
    result["audio_working"] = %d.player.working
    result["sleep_timer"] = %d.sleepTimerRemaining
    let flags = d.player.getStatusFlags()
    result["crossfading"] = %flags.crossfading
    result["master_ended"] = %flags.masterEnded
    result["shuffle"] = %d.shuffleEnabled
    result["repeat"] = %d.repeatMode
    result["track_path"] = %d.currentTrackPath
    if d.currentTrackTitle.len > 0:
      result["track_title"] = %d.currentTrackTitle
    elif d.currentTrackPath.contains("youtube.com") or d.currentTrackPath.contains("googlevideo.com"):
      result["track_title"] = %d.player.metadata.title
    else:
      result["track_title"] = %(splitFile(d.currentTrackPath).name.replace(".", " "))
    if d.currentTrackChannel.len > 0:
      result["track_channel"] = %d.currentTrackChannel
    elif d.player.metadata.artist.len > 0:
      result["track_channel"] = %d.player.metadata.artist
    if d.player.metadata.album.len > 0:
      result["track_album"] = %d.player.metadata.album
    when defined(useFFmpeg):
      result["backend_type"] = %(if d.player of MixerBackend: "Mixer" elif d.player of FfmpegBackend: "FFmpeg" else: "ALSA")
    else:
      result["backend_type"] = %"process"
    var qArr = newJArray()
    for p in d.playbackQueue:
      qArr.add(%p)
    result["queue"] = qArr
    # Full spec DaemonState object
    d.state.version = d.state.version + 1
    d.state.status = case d.player.state
      of 1: psPlaying
      of 2: psPaused
      else: psStopped
    d.state.volume = d.player.volume
    d.state.shuffle = d.shuffleEnabled
    d.state.repeat = case d.repeatMode
      of 2: "one"
      of 1: "all"
      else: "off"
    d.state.timePos = d.player.timePos
    d.state.duration = d.player.duration
    d.state.sleepTimer = d.sleepTimerRemaining
    d.state.crossfade.enabled = d.crossfadeDuration > 0
    d.state.crossfade.durationSecs = d.crossfadeDuration
    d.state.crossfade.easing = case d.crossfadeCurve
      of 0: "linear"
      of 2: "exponential"
      else: "equal_power"
    d.state.queue = d.playbackQueue
    d.state.queueCursor = uint64(max(0, d.shuffleIndex))
    d.state.currentTrack = TrackInfo(
      id: d.currentTrackPath,
      title: if d.currentTrackTitle.len > 0: d.currentTrackTitle
             elif d.player.metadata.title.len > 0: d.player.metadata.title
             else: splitFile(d.currentTrackPath).name,
      artist: if d.currentTrackChannel.len > 0: d.currentTrackChannel
              else: d.player.metadata.artist,
      path: d.currentTrackPath,
      duration: d.player.duration
    )
    result["daemon_state"] = %*{
      "version": d.state.version,
      "status": $d.state.status,
      "volume": d.state.volume,
      "shuffle": d.state.shuffle,
      "repeat": d.state.repeat,
      "time_pos": d.state.timePos,
      "duration": d.state.duration,
      "sleep_timer": d.state.sleepTimer,
      "crossfade": %*{"enabled": d.state.crossfade.enabled,
        "duration_secs": d.state.crossfade.durationSecs,
        "easing": d.state.crossfade.easing},
      "eq_preset": d.state.eqPreset,
      "eq_enabled": d.state.eqEnabled,
      "queue": qArr,
      "queue_cursor": d.state.queueCursor
    }
  of dckCrossfade:
    let enabled = cmd.intArg != 0
    if enabled:
      d.crossfadeDuration = int(cmd.floatArg)
      case cmd.strArg
      of "linear": d.crossfadeCurve = 0
      of "exponential": d.crossfadeCurve = 2
      else: d.crossfadeCurve = 1
      d.player.setCrossfadeCurve(d.crossfadeCurve)
    else:
      d.crossfadeDuration = 0
    result["crossfade_enabled"] = %(d.crossfadeDuration > 0)
    result["crossfade_duration"] = %d.crossfadeDuration
    d.broadcastEvent(%*{"event": "crossfade_changed",
      "enabled": %(d.crossfadeDuration > 0),
      "duration_secs": %d.crossfadeDuration})
  of dckSetEqPreset:
    d.player.setEqPreset(cmd.strArg)
    d.broadcastEvent(%*{"event": "eq_preset_changed", "preset": %cmd.strArg})
  of dckSetEqEnabled:
    d.player.setEqEnabled(cmd.intArg != 0)
    d.broadcastEvent(%*{"event": "eq_enabled_changed", "enabled": %(cmd.intArg != 0)})
  of dckQueue:
    if cmdJson != nil:
      return d.executeQueueCommand(cmd.strArg, cmdJson)
    else:
      result["ok"] = %false
      result["error"] = %"queue requires cmdJson"
  of dckLibrary:
    if cmdJson != nil:
      return d.executeLibraryCommand(cmd.strArg, cmdJson)
    else:
      result["ok"] = %false
      result["error"] = %"library requires cmdJson"
  of dckToggleShuffle:
    d.shuffleEnabled = not d.shuffleEnabled
    if d.shuffleEnabled and d.playbackQueue.len > 0:
      d.shuffleOrder = shuffleOrder(d.playbackQueue.len)
      d.shuffleIndex = 0
    result["shuffle"] = %d.shuffleEnabled
    d.broadcastEvent(%*{"event": "shuffle_changed", "enabled": %d.shuffleEnabled})
    when defined(useMpris):
      emitMprisPlayerChanged(d)
  of dckCycleRepeat:
    d.repeatMode = cmd.intArg
    result["repeat"] = %d.repeatMode
    let modeStr = case d.repeatMode
      of 2: "one"
      of 1: "all"
      else: "off"
    d.broadcastEvent(%*{"event": "repeat_mode_changed", "mode": %modeStr})
    when defined(useMpris):
      emitMprisPlayerChanged(d)
  of dckSetSleepTimer:
    d.sleepTimerRemaining = cmd.intArg
    result["sleep_timer"] = %d.sleepTimerRemaining
    if d.sleepTimerRemaining > 0:
      d.broadcastEvent(%*{"event": "sleep_timer_tick", "remaining_secs": %d.sleepTimerRemaining})
  of dckCancelSleepTimer:
    let wasActive = d.sleepTimerRemaining > 0
    d.sleepTimerRemaining = 0
    result["sleep_timer"] = %0
    if wasActive:
      d.broadcastEvent(%*{"event": "sleep_timer_expired"})
  of dckQueueSetCursor:
    d.shuffleIndex = cmd.intArg
    result["cursor"] = %d.shuffleIndex
  of dckAddFavourite:
    if d.lib != nil:
      d.lib.addFavourite(int64(cmd.intArg))
  of dckRemoveFavourite:
    if d.lib != nil:
      d.lib.removeFavourite(int64(cmd.intArg))
  of dckGetFavourites:
    if d.lib != nil:
      var arr = newJArray()
      for t in d.lib.getFavourites():
        arr.add(%t)
      result["favourites"] = arr
  of dckYtSearch:
    if d.ytSearchActive:
      try: d.ytSearchProcess.terminate() except: discard
      close(d.ytSearchProcess)
    d.ytSearchBuf = ""
    d.ytSearchResults = @[]
    d.ytSearchQuery = cmd.strArg
    d.ytSearchActive = startYoutubeSearch(cmd.strArg, d.ytSearchProcess, d.ytCookieSource, cmd.intArg)
    if d.ytSearchActive and d.lib != nil:
      d.lib.addSearchQuery(cmd.strArg)
    result["active"] = %d.ytSearchActive
  of dckYtSearchPoll:
    # Main loop auto-polls; just return current accumulated results
    var arr = newJArray()
    for r in d.ytSearchResults:
      arr.add(%*{"title": %r.title, "url": %r.url, "duration": %r.duration, "channel": %r.channel, "kind": %r.kind.int})
    result["results"] = arr
    result["done"] = %(not d.ytSearchActive)
  of dckYtSearchCancel:
    if d.ytSearchActive:
      try: d.ytSearchProcess.terminate() except: discard
      close(d.ytSearchProcess)
    d.ytSearchActive = false
    d.ytSearchBuf = ""
    d.ytSearchResults = @[]
  of dckYtResolveStream:
    d.ytStreamBuf = ""
    d.ytStreamResultUrl = ""
    d.ytStreamPendingTitle = cmd.strArg2
    d.ytStreamPendingChannel = cmd.strArg3
    d.ytStreamActive = startStreamUrlFetch(cmd.strArg, d.ytStreamProcess, d.ytCookieSource, d.ytJsRuntime)
    result["active"] = %d.ytStreamActive
  of dckYtResolveStreamPoll:
    # Main loop auto-polls; just return current state
    result["url"] = %d.ytStreamResultUrl
    result["title"] = %d.ytStreamPendingTitle
    result["channel"] = %d.ytStreamPendingChannel
    result["done"] = %(not d.ytStreamActive)
  of dckYtDownload:
    if cmd.strArg.len > 0:
      var task: DownloadTask
      if startDownload(YtSearchResult(url: cmd.strArg, title: cmd.strArg2, channel: cmd.strArg3), d.ytDownloadDir, task.process, d.ytCookieSource, d.ytJsRuntime):
        task.title = cmd.strArg2
        task.url = cmd.strArg
        task.channel = cmd.strArg3
        task.outputDir = d.ytDownloadDir
        task.completed = false
        task.startedAt = epochTime()
        d.ytDownloadTasks.add(task)
        result["started"] = %true
      else:
        result["started"] = %false
    else:
      result["started"] = %false
  of dckYtDownloadPoll:
    # Main loop auto-polls; just return current accumulated state
    result["done"] = %(d.ytDownloadTasks.len == 0)
    if d.ytLastCompletedPath.len > 0:
      result["path"] = %d.ytLastCompletedPath
      result["url"] = %d.ytLastCompletedUrl
      d.ytLastCompletedPath = ""
      d.ytLastCompletedUrl = ""
    var activeArr = newJArray()
    for t in d.ytDownloadTasks:
      activeArr.add(%*{"url": %t.url, "title": %t.title, "started": %t.startedAt})
    result["active"] = activeArr
    var completedArr = newJArray()
    for url, path in d.ytDownloaded:
      completedArr.add(%*{"url": %url, "path": %path})
    result["completed"] = completedArr
  of dckYtCancelDownload:
    for i in 0..<d.ytDownloadTasks.len:
      if d.ytDownloadTasks[i].url == cmd.strArg:
        try: d.ytDownloadTasks[i].process.terminate() except: discard
        close(d.ytDownloadTasks[i].process)
        d.ytDownloadTasks.delete(i)
        break
  of dckYtListDownloads:
    var arr = newJArray()
    if d.lib != nil:
      for dl in d.lib.getDownloads():
        arr.add(%*{"url": %dl.url, "path": %dl.path, "title": %dl.title})
    result["downloads"] = arr
  of dckYtFetchPlaylist:
    if d.ytPlaylistActive:
      result["ok"] = %false
      result["error"] = %"playlist fetch already in progress"
    else:
      if startPlaylistFetch(cmd.strArg, d.ytPlaylistProcess, d.ytCookieSource, d.ytJsRuntime):
        d.ytPlaylistActive = true
        d.ytPlaylistBuf = ""
        d.ytPlaylistUrl = cmd.strArg
        d.ytPlaylistResult = YtPlaylistDetail(url: cmd.strArg)
        result["ok"] = %true
        result["pending"] = %true
      else:
        result["ok"] = %false
        result["error"] = %"failed to start playlist fetch"
  of dckYtFetchPlaylistPoll:
    # Main loop auto-polls; just return current state
    if not d.ytPlaylistActive and d.ytPlaylistResult.tracks.len == 0:
      result["ok"] = %false
      result["error"] = %"no active playlist fetch"
    elif d.ytPlaylistActive:
      result["ok"] = %true
      result["pending"] = %true
    else:
      var tracksArr = newJArray()
      for t in d.ytPlaylistResult.tracks:
        tracksArr.add(%*{"title": %t.title, "url": %t.url, "duration": %t.duration, "channel": %t.channel, "kind": %t.kind.int})
      result["title"] = %d.ytPlaylistResult.title
      result["tracks"] = tracksArr
      result["track_count"] = %d.ytPlaylistResult.tracks.len
      result["done"] = %true
  of dckYtSetConfig:
    d.ytCookieSource = cmd.strArg
    d.ytJsRuntime = cmd.strArg2
    if cmd.strArg3.len > 0: d.ytDownloadDir = cmd.strArg3
    if cmd.intArg > 0: d.ytMaxConcurrentDownloads = cmd.intArg
    result["cookie_source"] = %d.ytCookieSource
    result["js_runtime"] = %d.ytJsRuntime
    result["download_dir"] = %d.ytDownloadDir
    result["max_concurrent"] = %d.ytMaxConcurrentDownloads
  of dckYtGetSearchHistory:
    var arr = newJArray()
    if d.lib != nil:
      for q in d.lib.getSearchHistory():
        arr.add(%q)
    result["history"] = arr
  of dckYtClearSearchHistory:
    if d.lib != nil:
      d.lib.clearSearchHistory()
  of dckListEqPresets:
    result["presets"] = %["Flat", "Rock", "Pop", "Classical", "Jazz", "HipHop", "Vocal", "BassBoost", "Headphones", "Laptop"]
  of dckToggleMute:
    if d.player.volume > 0:
      d.player.setVolume(0)
    else:
      d.player.setVolume(80)
    result["volume"] = %d.player.volume
  of dckSearch:
    if d.lib != nil and cmd.strArg.len > 0:
      let tracks = d.lib.searchTracks(cmd.strArg)
      var arr = newJArray()
      for t in tracks:
        arr.add(%*{
          "id": %t.id, "path": %t.path, "title": %t.title,
          "artist": %t.artist, "album": %t.album, "duration": %t.duration
        })
      result["tracks"] = arr
  of dckCheckHealth:
    result["clients_connected"] = %d.clients.len
    when defined(useFFmpeg):
      result["audio_backend"] = %(if d.player of MixerBackend: "mixer" elif d.player of FfmpegBackend: "ffmpeg" else: "process")
    else:
      result["audio_backend"] = %"process"
    result["audio_working"] = %d.player.working
  of dckPing:
    result["pong"] = %true
  of dckHandshake:
    const daemonProtocolVersion = 2
    if cmdJson == nil or not cmdJson.hasKey("version"):
      result["ok"] = %false
      result["error"] = %"handshake missing 'version' field"
    else:
      let clientVersion = cmdJson["version"].getInt(0)
      if clientVersion > daemonProtocolVersion:
        result["ok"] = %false
        result["error"] = %("protocol version " & $clientVersion &
          " is newer than daemon version " & $daemonProtocolVersion)
      else:
        result["ok"] = %true
        result["version"] = %daemonProtocolVersion
        result["daemon"] = %"gtmd-nim"
        result["daemon_version"] = %GTM_VERSION
  of dckUnknown:
    result["ok"] = %false
    result["error"] = %("unknown command: " & cmd.strArg)


proc trySend(client: Socket, data: string): bool =
  if data.len == 0: return true
  var remaining = data
  var retries = 20
  while remaining.len > 0 and retries > 0:
    let n = posix.send(client.getFd, unsafeAddr remaining[0], remaining.len.cint, 0.cint)
    if n > 0:
      remaining = remaining[n..^1]
    elif n == 0:
      return true
    else:
      let err = osLastError()
      if err.int32 == 11 or err.int32 == 10035:
        os.sleep(10)
        retries.dec
      else:
        try: client.close() except: discard
        return false
  if remaining.len > 0:
    try: client.close() except: discard
    return false
  return true

proc runDaemon*() =
  let debugMode = "--debug" in os.commandLineParams()
  let dir = stateDir()
  if not dirExists(dir): createDir(dir)
  let cacheDir = getEnv("XDG_CACHE_HOME", getEnv("HOME", "") & "/.cache") & "/gtm"
  if not dirExists(cacheDir): createDir(cacheDir)
  let crashPath = cacheDir / "crash.log"
  var crashFile: File
  if crashFile.open(crashPath, fmAppend):
    let crashFd = crashFile.getFileHandle
    if debugMode:
      stderr.writeLine("[gtmd] GTM Daemon v" & GTM_VERSION & " starting — pid: " & $getpid() & ", socket: " & sockPath())
    else:
      discard dup2(cint(crashFd), cint(1))
      discard dup2(cint(crashFd), cint(2))
    crashFile.close()
  discard prctl(15.cint, "gtmd")
  writePidFile()
  setupSignalHandlers()
  var player: AudioBackend
  when defined(useFFmpeg):
    player = newMixerBackend()
    if not player.working:
      echo "[gtm] Mixer backend unavailable (ALSA?), trying FFmpeg fallback"
      player = newFfmpegBackend()
    if not player.working:
      echo "[gtm] FFmpeg backend unavailable"
  else:
    player = nil
  if player == nil or not player.working:
    stderr.writeLine("[gtm] All audio backends unavailable")
  let defaultDownloadDir = dataDir() & "/audio"
  var daemon = Daemon(
    player: player,
    running: true,
    idleTimeout: 300,
    clients: @[],
    shuffleEnabled: false,
    repeatMode: 0,
    sleepTimerRemaining: 0,
    sleepTimerFrames: 0,
    persistFrames: 0,
    heartbeatFrames: 0,
    playbackQueue: @[],
    trackHistory: @[],
    shuffleOrder: @[],
    shuffleIndex: 0,
    crossfadeDuration: 0,
    crossfadeCurve: 1,
    crossfadePrepared: false,
    crossfadeStarted: false,
    crossfadeNextPath: "",
    scanningDir: "",
    scanningFiles: @[],
    scanningIdx: 0,
    ytCookieSource: "",
    ytJsRuntime: "",
    ytDownloadDir: defaultDownloadDir,
    ytMaxConcurrentDownloads: 4,
    ytSearchActive: false,
    ytStreamActive: false,
    ytStreamResultUrl: "",
    ytDownloaded: initTable[string, string](),
    ytDownloadedMeta: initTable[string, tuple[title, channel: string]](),
    ytLastCompletedPath: "",
    ytLastCompletedUrl: "",
    ytPlaylistActive: false,
    ytPlaylistBuf: "",
    ytPlaylistUrl: "",
    pulseClients: @[]
  )
  when defined(useMpris):
    initMpris(daemon)
  let libPath = dataDir() & "/gtm.db"
  if not dirExists(dataDir()):
    createDir(dataDir())
  daemon.lib = openLibrary(libPath)
  if daemon.lib != nil:
    daemon.lib.initSchema()
    let volStr = daemon.lib.getPlaybackState("volume")
    if volStr.len > 0:
      try: daemon.player.setVolume(parseInt(volStr)) except: discard
    let trackPath = daemon.lib.getPlaybackState("track_path")
    let trackTitle = daemon.lib.getPlaybackState("track_title")
    let trackChannel = daemon.lib.getPlaybackState("track_channel")
    if trackPath.len > 0 and fileExists(trackPath):
      daemon.player.loadFile(trackPath)
      daemon.currentTrackPath = trackPath
      daemon.currentTrackTitle = trackTitle
      daemon.currentTrackChannel = trackChannel
    let shuffleStr = daemon.lib.getPlaybackState("shuffle")
    if shuffleStr.len > 0:
      try: daemon.shuffleEnabled = shuffleStr == "true" except: discard
    let repeatStr = daemon.lib.getPlaybackState("repeat")
    if repeatStr.len > 0:
      try: daemon.repeatMode = parseInt(repeatStr) except: discard
    let sleepStr = daemon.lib.getPlaybackState("sleep_timer")
    if sleepStr.len > 0:
      try: daemon.sleepTimerRemaining = parseInt(sleepStr) except: discard
    let cfStr = daemon.lib.getPlaybackState("crossfade_duration")
    if cfStr.len > 0:
      try: daemon.crossfadeDuration = parseInt(cfStr) except: discard
    let cfcStr = daemon.lib.getPlaybackState("crossfade_curve")
    if cfcStr.len > 0:
      try: daemon.crossfadeCurve = parseInt(cfcStr) except: discard
    let ytCookie = daemon.lib.getPlaybackState("yt_cookie_source")
    if ytCookie.len > 0: daemon.ytCookieSource = ytCookie
    let ytJs = daemon.lib.getPlaybackState("yt_js_runtime")
    if ytJs.len > 0: daemon.ytJsRuntime = ytJs
    let ytDlDir = daemon.lib.getPlaybackState("yt_download_dir")
    if ytDlDir.len > 0: daemon.ytDownloadDir = ytDlDir
    let ytMax = daemon.lib.getPlaybackState("yt_max_concurrent")
    if ytMax.len > 0:
      try: daemon.ytMaxConcurrentDownloads = parseInt(ytMax) except: discard
    # Restore completed downloads from database
    for dl in daemon.lib.getDownloads():
      daemon.ytDownloaded[dl.url] = dl.path
    let queueStr = daemon.lib.getPlaybackState("queue_json")
    if queueStr.len > 0:
      try:
        let qj = parseJson(queueStr)
        daemon.playbackQueue = @[]
        for p in qj:
          daemon.playbackQueue.add(p.getStr(""))
      except: discard
    # Auto-scan download directory for files not yet in library
    if dirExists(daemon.ytDownloadDir):
      let existing = scanDirectoryRecursive(daemon.ytDownloadDir)
      for p in existing:
        if daemon.lib.findTrackByPath(p) == 0:
          let (ftitle, fartist) = parseFilenameForMetadata(p)
          discard daemon.lib.addTrack(p, ftitle, fartist, "", 0.0, 0, 0, "")
  # Sync DaemonState from restored fields
  daemon.state.version = 0
  daemon.state.status = case daemon.player.state
    of 1: psPlaying
    of 2: psPaused
    else: psStopped
  daemon.state.volume = daemon.player.volume
  daemon.state.shuffle = daemon.shuffleEnabled
  daemon.state.repeat = case daemon.repeatMode
    of 2: "one"
    of 1: "all"
    else: "off"
  daemon.state.crossfade.enabled = daemon.crossfadeDuration > 0
  daemon.state.crossfade.durationSecs = daemon.crossfadeDuration
  daemon.state.crossfade.easing = case daemon.crossfadeCurve
    of 0: "linear"
    of 2: "exponential"
    else: "equal_power"
  daemon.state.queue = daemon.playbackQueue
  daemon.state.queueCursor = uint64(max(0, daemon.shuffleIndex))
  removeFile(sockPath())
  let srvFd = posix.socket(posix.AF_UNIX, posix.SOCK_STREAM, 0)
  daemon.server = newSocket(srvFd, Domain.AF_UNIX, SockType.SOCK_STREAM)
  daemon.server.bindUnix(sockPath())
  daemon.server.listen()
  # Pulse socket for binary MessagePack events
  removeFile(pulseSockPath())
  let pulseFd = posix.socket(posix.AF_UNIX, posix.SOCK_STREAM, 0)
  daemon.pulseServer = newSocket(pulseFd, Domain.AF_UNIX, SockType.SOCK_STREAM)
  daemon.pulseServer.bindUnix(pulseSockPath())
  daemon.pulseServer.listen()
  daemon.pulseServer.getFd().setBlocking(false)
  while daemon.running:
    when defined(useMpris):
      pollMpris()
    var readFds: seq[SocketHandle] = @[daemon.server.getFd, daemon.pulseServer.getFd]
    for c in daemon.clients:
      readFds.add(c.sock.getFd)
    for pc in daemon.pulseClients:
      readFds.add(pc.getFd)
    if selectRead(readFds, 16) > 0:
      if daemon.server.getFd in readFds:
        var clientAddr: posix.Sockaddr_un
        var addrLen = posix.SockLen(sizeof(clientAddr))
        let cliFd = posix.accept(daemon.server.getFd,
          cast[ptr posix.SockAddr](addr(clientAddr)), addr(addrLen))
        if cliFd.int >= 0:
          var newClient = ClientState(
            sock: newSocket(cliFd, Domain.AF_UNIX, SockType.SOCK_STREAM),
            buf: "", authenticated: false, framesSinceConnect: 0
          )
          setBlocking(newClient.sock.getFd, false)
          daemon.clients.add(newClient)
          daemon.idleFrames = 0
      if daemon.pulseServer.getFd in readFds:
        var pulseAddr: posix.Sockaddr_un
        var pulseAddrLen = posix.SockLen(sizeof(pulseAddr))
        let pcFd = posix.accept(daemon.pulseServer.getFd,
          cast[ptr posix.SockAddr](addr(pulseAddr)), addr(pulseAddrLen))
        if pcFd.int >= 0:
          var pcSock = newSocket(pcFd, Domain.AF_UNIX, SockType.SOCK_STREAM)
          setBlocking(pcSock.getFd, false)
          daemon.pulseClients.add(pcSock)
      # Read from all clients
      var ci = 0
      while ci < daemon.clients.len:
        if daemon.clients[ci].sock.getFd in readFds:
          var tmp: array[4096, char]
          let n = posix.recv(daemon.clients[ci].sock.getFd, addr tmp[0], tmp.len.cint, 0)
          if n < 0:
            let err = osLastError()
            if err.int32 != 11 and err.int32 != 10035:
              daemon.clients[ci].sock.close()
              daemon.clients.delete(ci)
              continue
            else:
              ci.inc
              continue
          elif n == 0:
            daemon.clients[ci].sock.close()
            daemon.clients.delete(ci)
            continue
          else:
            let old = daemon.clients[ci].buf.len
            if old + n > 16 * 1024 * 1024:
              if debugMode: stderr.writeLine("[gtm] client buffer exceeded 16MB, disconnecting")
              daemon.clients[ci].sock.close()
              daemon.clients.delete(ci)
              continue
            daemon.clients[ci].buf.setLen(old + n)
            copyMem(addr daemon.clients[ci].buf[old], addr tmp[0], n)
            while true:
              let nli = daemon.clients[ci].buf.find('\n')
              if nli < 0: break
              let line = daemon.clients[ci].buf[0..<nli]
              daemon.clients[ci].buf = daemon.clients[ci].buf[nli+1..^1]
              if line.len > 0:
                if line.len > 1048576:
                  if debugMode: stderr.writeLine("[gtm] line exceeds 1 MiB, disconnecting client")
                  daemon.clients[ci].sock.close()
                  daemon.clients.delete(ci)
                  break
                if debugMode: stderr.writeLine("[gtm] daemon recv: " & line)
                let cmdJson = try: parseJson(line) except CatchableError: nil
                if cmdJson == nil:
                  if debugMode: stderr.writeLine("[gtm] malformed JSON, disconnecting client")
                  daemon.clients[ci].sock.close()
                  daemon.clients.delete(ci)
                  break
                let cmd = parseDaemonCommand(line)
                # Auth gate: require handshake first
                if not daemon.clients[ci].authenticated and cmd.kind != dckHandshake:
                  var rejResp = %*{"ok": false, "error": "handshake required"}
                  if cmdJson.hasKey("id"): rejResp["id"] = cmdJson["id"]
                  let rejStr = $rejResp & "\n"
                  if debugMode: stderr.writeLine("[gtm] daemon resp: " & rejStr.strip())
                  if not trySend(daemon.clients[ci].sock, rejStr):
                    daemon.clients[ci].sock.close()
                    daemon.clients.delete(ci)
                    break
                else:
                  let resp = try:
                    executeCommand(daemon, cmd, cmdJson)
                  except Exception as ex:
                    if debugMode: stderr.writeLine("[gtm] command error: " & ex.msg)
                    %*{"ok": false, "error": ex.msg}
                  if cmdJson.hasKey("id"):
                    resp["id"] = cmdJson["id"]
                  if cmd.kind == dckHandshake:
                    daemon.clients[ci].authenticated = true
                    daemon.clients[ci].framesSinceConnect = 0
                  let respStr = $resp & "\n"
                  if debugMode: stderr.writeLine("[gtm] daemon resp: " & respStr.strip())
                  if not trySend(daemon.clients[ci].sock, respStr):
                    daemon.clients[ci].sock.close()
                    daemon.clients.delete(ci)
                    break
                if not daemon.running: break
        # Handshake timeout: disconnect unauthed clients after 600 frames (~10s)
        if ci < daemon.clients.len and not daemon.clients[ci].authenticated:
          daemon.clients[ci].framesSinceConnect.inc
          if daemon.clients[ci].framesSinceConnect > 600:
            if debugMode: stderr.writeLine("[gtm] handshake timeout, disconnecting client")
            daemon.clients[ci].sock.close()
            daemon.clients.delete(ci)
            continue
        ci.inc
      # Drain pulse client disconnections
      var pci = 0
      while pci < daemon.pulseClients.len:
        if daemon.pulseClients[pci].getFd in readFds:
          var tmp: array[256, char]
          let n = posix.recv(daemon.pulseClients[pci].getFd, addr tmp[0], tmp.len.cint, 0)
          if n <= 0:
            try: daemon.pulseClients[pci].close() except: discard
            daemon.pulseClients.delete(pci)
            continue
        pci.inc
    let daemonEvents = daemon.player.pollEvents()
    if daemonEvents.len > 0 and daemon.clients.len > 0:
      let evLines = serializeEvents(daemonEvents, daemon)
      daemon.broadcastAllLines(evLines)
    # Auto-advance on track ended
    for ev in daemonEvents:
      if ev.kind == aekTrackEnded:
        if daemon.crossfadeNextPath.len > 0:
          daemon.currentTrackPath = daemon.crossfadeNextPath
          daemon.upNextSent = false
          if daemon.lib != nil:
            let cfId = daemon.lib.findTrackByPath(daemon.crossfadeNextPath)
            if cfId > 0:
              daemon.lib.updatePlayCount(cfId)
          # Consume queue now that crossfade completed
          if not daemon.shuffleEnabled and daemon.playbackQueue.len > 0:
            daemon.playbackQueue.delete(0)
            if daemon.repeatMode == 1:
              daemon.playbackQueue.add(daemon.crossfadeNextPath)
          daemon.crossfadePrepared = false
          daemon.crossfadeStarted = false
          daemon.crossfadeConsumed = false
          daemon.crossfadeNextPath = ""
          daemon.sendQueueEvent()
        elif daemon.playbackQueue.len > 0:
          discard daemon.advanceToNextTrack(true)
          daemon.sendQueueEvent()
        when defined(useMpris):
          emitMprisPlayerChanged(daemon)

    # yt-dlp download task management (poll BEFORE retry so completed downloads are visible)
    let dlTimeout = 600.0
    var dlDone: seq[int] = @[]
    for i in 0..<daemon.ytDownloadTasks.len:
      if not daemon.ytDownloadTasks[i].completed:
        let p = daemon.ytDownloadTasks[i].process
        if epochTime() - daemon.ytDownloadTasks[i].startedAt > dlTimeout:
          try: p.terminate() except: discard
          close(p)
          daemon.ytDownloadTasks[i].completed = true
          dlDone.add(i)
        elif not p.running():
          var path = ""
          try: path = pollDownload(daemon.ytDownloadTasks[i].process, daemon.ytDownloadTasks[i].buf)
          except: discard
          daemon.ytDownloadTasks[i].completed = true
          dlDone.add(i)
          if path.len > 0:
            let dlUrl = daemon.ytDownloadTasks[i].url
            daemon.ytDownloaded[dlUrl] = path
            daemon.ytDownloadedMeta[dlUrl] = (title: daemon.ytDownloadTasks[i].title, channel: daemon.ytDownloadTasks[i].channel)
            daemon.ytLastCompletedPath = path
            daemon.ytLastCompletedUrl = dlUrl
            if daemon.lib != nil:
              daemon.lib.addDownload(dlUrl, path, daemon.ytDownloadTasks[i].title, daemon.ytDownloadTasks[i].channel)
              daemon.lib.updateTrackPath(dlUrl, path, daemon.ytDownloadTasks[i].title)
              # Add as a new library track if not already present
              let existingId = daemon.lib.findTrackByPath(path)
              if existingId == 0:
                discard daemon.lib.addTrack(path, daemon.ytDownloadTasks[i].title,
                  daemon.ytDownloadTasks[i].channel, "", 0.0, 0, 0, "")
            let ev = %*{"event": "custom", "name": "yt_download_done", "url": %dlUrl, "path": %path, "title": %daemon.ytDownloadTasks[i].title}
            daemon.broadcastEvent(ev)
      else:
        dlDone.add(i)
    for i in countdown(dlDone.len - 1, 0):
      daemon.ytDownloadTasks.delete(dlDone[i])

    # yt-dlp stream URL resolution for queue items
    if daemon.ytStreamResolving:
      if not daemon.ytStreamResolveProcess.running():
        let url = pollStreamUrlFetch(daemon.ytStreamResolveProcess, daemon.ytStreamResolveBuf)
        daemon.ytStreamResolving = false
        daemon.ytStreamResolveBuf = ""
        if url.len > 0:
          daemon.ytStreamUrls[daemon.ytStreamResolveUrl] = url
          daemon.ytStreamResolveUrl = ""

    # Auto-poll yt-dlp search results & broadcast via events (no client polling needed)
    if daemon.ytSearchActive:
      let newResults = pollYoutubeSearch(daemon.ytSearchProcess, daemon.ytSearchBuf)
      for r in newResults:
        daemon.ytSearchResults.add(r)
      if newResults.len > 0 and daemon.ytSearchResults.len > 0:
        var arr = newJArray()
        for r in daemon.ytSearchResults:
          arr.add(%*{"title": %r.title, "url": %r.url, "duration": %r.duration, "channel": %r.channel, "kind": %r.kind.int})
        let ev = %*{"event": "custom", "name": "yt_search_partial", "results": arr}
        daemon.broadcastEvent(ev)
      if not daemon.ytSearchProcess.running():
        let finalResults = finishYoutubeSearch(daemon.ytSearchProcess, daemon.ytSearchBuf)
        for r in finalResults:
          daemon.ytSearchResults.add(r)
        daemon.ytSearchActive = false
        daemon.ytSearchBuf = ""
        var arr = newJArray()
        for r in daemon.ytSearchResults:
          arr.add(%*{"title": %r.title, "url": %r.url, "duration": %r.duration, "channel": %r.channel, "kind": %r.kind.int})
        let ev = %*{"event": "custom", "name": "yt_search_done", "results": arr}
        daemon.broadcastEvent(ev)

    # Auto-poll yt-dlp playlist fetch results & broadcast via events
    if daemon.ytPlaylistActive:
      let newTracks = pollPlaylistFetch(daemon.ytPlaylistProcess, daemon.ytPlaylistBuf)
      for t in newTracks:
        daemon.ytPlaylistResult.tracks.add(t)
      if not daemon.ytPlaylistProcess.running():
        let finalTracks = finishPlaylistFetch(daemon.ytPlaylistProcess, daemon.ytPlaylistBuf)
        for t in finalTracks:
          daemon.ytPlaylistResult.tracks.add(t)
        # Parse title/channel from first result
        if daemon.ytPlaylistResult.tracks.len > 0:
          let first = daemon.ytPlaylistResult.tracks[0]
          if daemon.ytPlaylistResult.title.len == 0:
            daemon.ytPlaylistResult.title = "Playlist"
            daemon.ytPlaylistResult.channel = first.channel
        daemon.ytPlaylistActive = false
        daemon.ytPlaylistBuf = ""
        # Broadcast playlist fetched event
        var tracksArr = newJArray()
        for t in daemon.ytPlaylistResult.tracks:
          tracksArr.add(%*{"title": %t.title, "url": %t.url, "duration": %t.duration, "channel": %t.channel, "kind": %t.kind.int})
        let ev = %*{"event": "custom", "name": "yt_playlist_fetched",
          "title": %daemon.ytPlaylistResult.title, "tracks": tracksArr}
        daemon.broadcastEvent(ev)

    # Auto-poll explicit stream URL resolution (for user-initiated "Play" on search result)
    if daemon.ytStreamActive:
      if not daemon.ytStreamProcess.running():
        daemon.ytStreamResultUrl = pollStreamUrlFetch(daemon.ytStreamProcess, daemon.ytStreamBuf)
        daemon.ytStreamActive = false
        daemon.ytStreamBuf = ""
        let ev = %*{"event": "custom", "name": "yt_stream_resolved",
          "url": %daemon.ytStreamResultUrl,
          "title": %daemon.ytStreamPendingTitle,
          "channel": %daemon.ytStreamPendingChannel}
        daemon.broadcastEvent(ev)

    # Retry advancing if player stopped with items pending (e.g. waiting for YT download)
    if daemon.player.state == 0 and daemon.playbackQueue.len > 0:
      if daemon.advanceToNextTrack(true):
        daemon.sendQueueEvent()

    # Determine next queue path for up_next and crossfade scheduling
    var nextQueuedPath = ""
    if daemon.player.state == 1:
      if daemon.shuffleEnabled and daemon.shuffleOrder.len > 0 and daemon.shuffleIndex < daemon.shuffleOrder.len:
        let sIdx = daemon.shuffleOrder[daemon.shuffleIndex]
        if sIdx >= 0 and sIdx < daemon.playbackQueue.len:
          nextQueuedPath = daemon.playbackQueue[sIdx]
      elif not daemon.shuffleEnabled and daemon.playbackQueue.len > 0:
        nextQueuedPath = daemon.playbackQueue[0]

    # Send "up_next" notification when near end of current track
    if nextQueuedPath.len > 0 and not daemon.upNextSent:
      let dur = daemon.player.duration
      let tpos = daemon.player.timePos
      if dur > 0.0 and tpos >= 0.0:
        let timeRemaining = dur - tpos
        if timeRemaining <= 8.0 and timeRemaining > 0.0:
          daemon.upNextSent = true
          var nextTitle = ""; var nextChannel = ""
          if isYtWatchUrl(nextQueuedPath) and nextQueuedPath in daemon.ytDownloadedMeta:
            nextTitle = daemon.ytDownloadedMeta[nextQueuedPath].title
            nextChannel = daemon.ytDownloadedMeta[nextQueuedPath].channel
          let ev = %*{"event": "custom", "name": "up_next",
            "next_path": %nextQueuedPath, "next_title": %nextTitle, "next_channel": %nextChannel}
          daemon.broadcastEvent(ev)

    # Crossfade scheduling
    if daemon.player.state == 1 and daemon.crossfadeDuration > 0:
      if nextQueuedPath.len > 0:
        let dur = daemon.player.duration
        let tpos = daemon.player.timePos
        if dur > 0.0 and tpos >= 0.0:
          let timeRemaining = dur - tpos
          if timeRemaining > 0.0:
            let prepareThreshold = float(daemon.crossfadeDuration) + 2.0
            if not daemon.crossfadePrepared and timeRemaining <= prepareThreshold:
              var loadNextPath = nextQueuedPath
              if isYtWatchUrl(nextQueuedPath) and nextQueuedPath in daemon.ytDownloaded:
                loadNextPath = daemon.ytDownloaded[nextQueuedPath]
              elif isYtWatchUrl(nextQueuedPath) and nextQueuedPath in daemon.ytStreamUrls:
                loadNextPath = daemon.ytStreamUrls[nextQueuedPath]
              daemon.player.prepareNext(loadNextPath)
              daemon.crossfadePrepared = true
              daemon.crossfadeNextPath = loadNextPath
            if daemon.crossfadePrepared and not daemon.crossfadeStarted and timeRemaining <= float(daemon.crossfadeDuration):
              daemon.upNextSent = true
              if daemon.shuffleEnabled and not daemon.crossfadeConsumed:
                daemon.crossfadeConsumed = true
                daemon.shuffleIndex.inc
              daemon.player.startCrossfade(float(daemon.crossfadeDuration))
              daemon.crossfadeStarted = true
    # Background scan: process up to 10 files per iteration
    if daemon.scanningDir.len > 0 and daemon.scanningFiles.len > 0:
      let batchEnd = min(daemon.scanningIdx + 10, daemon.scanningFiles.len)
      while daemon.scanningIdx < batchEnd:
        let p = daemon.scanningFiles[daemon.scanningIdx]
        if daemon.lib != nil:
          let (ftitle, fartist) = parseFilenameForMetadata(p)
          discard daemon.lib.addTrack(p, ftitle, fartist, "", 0.0, 0, 0, "")
        daemon.scanningIdx.inc
      if daemon.scanningIdx >= daemon.scanningFiles.len:
        daemon.scanningDir = ""
        daemon.scanningFiles = @[]
        daemon.scanningIdx = 0
        let ev = %*{"event": "custom", "name": "scan_done"}
        daemon.broadcastEvent(ev)

    if daemon.sleepTimerRemaining > 0:
      daemon.sleepTimerFrames.inc
      if daemon.sleepTimerFrames >= 60:
        daemon.sleepTimerFrames = 0
        daemon.sleepTimerRemaining.dec
        if daemon.sleepTimerRemaining <= 0:
          daemon.broadcastEvent(%*{"event": "sleep_timer_expired"})
          daemon.savePlaybackState()
          when defined(useMpris):
            shutdownMpris()
          if daemon.lib != nil:
            daemon.lib.closeDb()
          daemon.player.shutdown()
          daemon.running = false
          break
        else:
          daemon.broadcastEvent(%*{"event": "sleep_timer_tick", "remaining_secs": %daemon.sleepTimerRemaining})
    daemon.persistFrames.inc
    if signalFlag:
      if debugMode: stderr.writeLine("[gtm] signal received, graceful shutdown")
      daemon.gracefulShutdown()
      break
    if daemon.persistFrames >= 1800:
      daemon.persistFrames = 0
      daemon.savePlaybackState()
    daemon.heartbeatFrames.inc
    # protocol.md §Heartbeat: emit at least every 30 seconds during active
    # playback. selectRead loop runs ~every 16 ms; 1800 frames ~ 28.8 s, so
    # heartbeats fire slightly more often than required. Heartbeats are only
    # sent while playing (state == 1) per spec qualifier.
    if daemon.heartbeatFrames >= 1800:
      daemon.heartbeatFrames = 0
      if daemon.player != nil and daemon.player.state == 1:
        let ev = %*{"event": "heartbeat"}
        daemon.broadcastEvent(ev)
    daemon.idleFrames.inc
    if daemon.idleFrames > daemon.idleTimeout * 60 and daemon.player.state == 0:
      daemon.savePlaybackState()
      when defined(useMpris):
        shutdownMpris()
      if daemon.lib != nil:
        daemon.lib.closeDb()
      daemon.player.shutdown()
      break
  for c in daemon.clients:
    try: c.sock.close() except: discard
  for pc in daemon.pulseClients:
    try: pc.close() except: discard
  daemon.server.close()
  daemon.pulseServer.close()
  removeFile(sockPath())
  removeFile(pulseSockPath())
  removePidFile()
