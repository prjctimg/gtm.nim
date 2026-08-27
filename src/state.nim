import illwave as iw
import os, tables, sets, osproc, audio, theme, math, json, options, colors

var debugMode*: bool

type
  PlaybackStatus* = enum
    psStopped, psPlaying, psPaused

  ChangeEvent* = enum
    ceTrack, cePlayState, cePosition, ceVolume, ceQueue,
    ceSearchResults, ceSearchLoading, ceSettings,
    cePlaylists, ceQueueCursor, ceFeedback, ceDownloadProgress,
    ceReconnecting

  HighlightAttr* = object
    fg*, bg*: Option[colors.Color]
    bold*, italic*, underline*: bool

  HighlightGroups* = object
    Normal*: HighlightAttr
    TabBar*: HighlightAttr
    TabBarActive*: HighlightAttr
    TabBarInactive*: HighlightAttr
    NowPlayingTitle*: HighlightAttr
    NowPlayingArtist*: HighlightAttr
    NowPlayingProgress*: HighlightAttr
    NowPlayingProgressFill*: HighlightAttr
    NowPlayingStatus*: HighlightAttr
    NowPlayingUpNext*: HighlightAttr
    NowPlayingUpNextCursor*: HighlightAttr
    NowPlayingUpNextHeader*: HighlightAttr
    LibrarySidebar*: HighlightAttr
    LibrarySidebarActive*: HighlightAttr
    LibrarySidebarSelected*: HighlightAttr
    LibraryContentHeader*: HighlightAttr
    LibraryContentRow*: HighlightAttr
    LibraryContentRowSelected*: HighlightAttr
    SettingsSidebar*: HighlightAttr
    SettingsContentRow*: HighlightAttr
    SettingsContentRowSelected*: HighlightAttr
    SettingsSectionHeader*: HighlightAttr
    StatusBar*: HighlightAttr
    StatusBarHints*: HighlightAttr
    StatusBarModule*: HighlightAttr
    FilterBar*: HighlightAttr
    ProgressBar*: HighlightAttr
    ProgressBarTime*: HighlightAttr
    VisualizerBar*: HighlightAttr
    OverlayBorder*: HighlightAttr
    OverlayTitle*: HighlightAttr
    OverlayInput*: HighlightAttr
    OverlayRow*: HighlightAttr
    OverlayRowSelected*: HighlightAttr
    OverlayFooter*: HighlightAttr
    Scrollbar*: HighlightAttr
    ErrorMsg*: HighlightAttr
    WarningMsg*: HighlightAttr
    InfoMsg*: HighlightAttr
    SuccessMsg*: HighlightAttr
    VolumeCue*: HighlightAttr
    FeedbackCue*: HighlightAttr
    NowPlayingCue*: HighlightAttr
    UpNextCue*: HighlightAttr
    EqualizerBar*: HighlightAttr

  FooterPresetName* = enum
    fpnMinimal, fpnCompact, fpnFull, fpnInfo, fpnNavigator, fpnDebug, fpnMusic, fpnClock

  CrossfadeCurveType* = enum
    cctEqualPower, cctQuadratic, cctCubic, cctAsymmetric

  InputMode* = enum
    imNormal, imFilter, imLeaderMode

  LibraryPanel* = enum
    lpSidebar, lpContent

  AppTab* = enum
    tabNowPlaying = 0, tabLibrary, tabSettings

  Track* = object
    path*: string
    title*: string
    artist*: string
    album*: string
    duration*: float
    id*: int64
    trackNum*: int
    year*: int
    genre*: string
    playCount*: int
    artistId*: int64
    albumId*: int64
    isFavourite*: bool
    addedAt*: string
    lastPlayed*: string

  ArtistEnt* = object
    id*: int64
    name*: string

  AlbumEnt* = object
    id*: int64
    title*: string
    artistId*: int64
    artistName*: string
    year*: int
    genre*: string

  UserPlaylist* = object
    id*: int64
    name*: string
    trackIds*: seq[int64]

  ConfigData* = object
    theme*: string
    volume*: int
    lastTab*: AppTab
    refreshTheme*: bool
    idleTimeout*: int
    ipcTimeout*: int

  LibraryItemKind* = enum
    likTrack, likArtist, likAlbum, likPlaylist

  FilterScope* = enum
    fsAll, fsArtists, fsAlbums, fsPlaylists, fsTracks,
    fsRecent, fsFavourites, fsLastPlayed, fsMostPlayed, fsLeastPlayed,
    fsDownloads

  DownloadsTab* = enum
    dtDownloading, dtDownloaded

  YtSearchResultKind* = enum srkVideo, srkPlaylist

  YtSearchResult* = object
    title*: string
    url*: string
    duration*: string
    channel*: string
    playlistTitle*: string
    kind*: YtSearchResultKind

  YtPlaylistDetail* = object
    title*: string
    url*: string
    channel*: string
    trackCount*: int
    tracks*: seq[YtSearchResult]

  OverlayKind* = enum
    okNone
    okYtSearch
    okYtBatch
    okQueuePicker
    okPlaylistSearch
    okThemePicker
    okCommandPalette
    okQueueOverlay
    okFuzzyFinder
    okMetadataEditor

  YtSubTab* = enum ystAll, ystPlaylists

  NotificationKind* = enum nkInfo, nkSuccess, nkWarning, nkError

  OverlayState* = object
    kind*: OverlayKind
    query*: string
    cursor*: int
    results*: seq[int]
    strResults*: seq[string]
    ytResults*: seq[YtSearchResult]
    selected*: HashSet[int]
    multiMode*: bool
    batchItems*: seq[YtSearchResult]
    batchShowPls*: bool
    plMode*: int
    ytSubTab*: YtSubTab
    ytPlaylistDetail*: YtPlaylistDetail
    ytAutocompleteSuggestions*: seq[string]
    ytAutocompleteCursor*: int
    ytAutocompleteVisible*: bool
    mdTrackId*: int64
    mdField*: int
    mdBuffer*: string
    mdValues*: seq[string]
    mdEditing*: bool

  DownloadTask* = object
    process*: Process
    title*: string
    url*: string
    channel*: string
    outputDir*: string
    buf*: string
    completed*: bool
    resultPath*: string
    startedAt*: float

  LibraryItem* = object
    kind*: LibraryItemKind
    trackIdx*: int
    label*: string
    sublabel*: string
    id*: int64

  CommandEntry* = object
    id*: string
    name*: string
    description*: string
    icon*: string
    defaultKeys*: seq[string]
    keyCodes*: seq[seq[iw.Key]]
    handler*: proc(state: var AppState) {.closure.}

  FooterModule* = enum
    fmPlayStatus
    fmVolume
    fmBackend
    fmNextTrack
    fmSelectCount
    fmTime
    fmDate
    fmRepeatShuffle
    fmSleepTimer
    fmElapsedTime
    fmQueueCount
    fmEqPreset
    fmCurrentPlaylist

  SettingsCategory* = enum
    scAudio, scYouTube, scAppearance, scSystem

  LoudnessMode* = enum
    lmOff, lmTrack, lmAlbum, lmAuto

  AppState* = object
    theme*: Theme
    highlightGroups*: HighlightGroups
    userHighlightOverrides*: JsonNode
    footerPreset*: FooterPresetName
    player*: AudioBackend
    status*: PlaybackStatus
    timePos*: float
    duration*: float
    volume*: int
    dirtyFlags*: set[ChangeEvent]
    helpVisible*: bool
    mode*: InputMode
    filterText*: string
    filterScope*: FilterScope
    libraryFocusPanel*: LibraryPanel
    librarySidebarSelect*: int
    settingsCategory*: SettingsCategory
    settingsFocusPanel*: LibraryPanel
    filteredIndices*: seq[int]
    selectIndex*: int
    needsRedraw*: bool
    tab*: AppTab
    selectMode*: bool
    selectedIndices*: HashSet[int]
    selectionAnchor*: int
    config*: ConfigData
    libraryTracks*: seq[Track]
    libraryArtists*: seq[ArtistEnt]
    libraryAlbums*: seq[AlbumEnt]
    libraryPlaylists*: seq[UserPlaylist]
    favouriteIds*: HashSet[int64]
    displayItems*: seq[LibraryItem]
    commands*: seq[CommandEntry]
    cmdRegistry*: Table[string, int]
    keybindings*: Table[string, string]
    keyDispatch*: Table[iw.Key, seq[int]]
    multiKeyDispatch*: Table[seq[iw.Key], int]
    pendingSeq*: seq[iw.Key]
    pendingSeqTimer*: int
    overlay*: OverlayState
    daemonConnected*: bool
    daemonPid*: int
    configPath*: string
    dataDir*: string
    audioAvailable*: bool
    currentPlayingPath*: string
    currentPlayingId*: int64
    volumeCueTimer*: int
    volumeCueVolume*: int
    notificationMsg*: string
    notificationBody*: string
    notificationKind*: NotificationKind
    notificationTimer*: int
    nowPlayingCueMsg*: string
    nowPlayingCueTimer*: int
    lastKeyDisplay*: string
    lastKeyTimer*: int
    lastCommandName*: string
    prevVolume*: int
    shuffleEnabled*: bool
    shuffleOrder*: seq[int]
    shuffleIndex*: int
    repeatMode*: int
    sleepTimerRemaining*: int
    playlistContentsIdx*: int
    playlistInputActive*: bool
    playlistInputPrompt*: string
    playlistInputBuffer*: string
    addingToPlaylistId*: int64
    addingToPlaylistName*: string
    footerModules*: set[FooterModule]
    rawKeybindingsJson*: JsonNode
    feedbackMsg*: string
    feedbackTimer*: int
    playbackQueue*: seq[int]
    ytDebounceAt*: float
    ytStreamPendingItem*: YtSearchResult
    ytStreamTitle*: string
    ytStreamChannel*: string
    ytDownloadDir*: string
    ytDownloadQueue*: seq[YtSearchResult]
    ytDownloadTasks*: seq[DownloadTask]
    ytDownloaded*: Table[string, string]
    downloadCount*: int
    downloadsTab*: DownloadsTab
    downloadProgress*: Table[string, int]
    ytMaxConcurrentDownloads*: int
    ytBatchDownloadMode*: bool
    ytCookieSource*: string
    ytJsRuntime*: string
    ytSearchHistory*: seq[string]
    ytSearchHistoryLower*: seq[string]
    ytSearchQuery*: string
    ytSearchPage*: int
    ytSearchPageSize*: int
    ytSearchLoading*: bool
    ytProgressCurrent*: int
    ytProgressTotal*: int
    crossfadeDuration*: int
    crossfadeCurve*: CrossfadeCurveType
    crossfadePrepared*: bool
    crossfadeStarted*: bool
    crossfading*: bool
    crossfadeNextPath*: string
    gapless*: bool
    loudnessMode*: LoudnessMode
    preGainDb*: float
    reverbEnabled*: bool
    reverbRoomScale*: float
    dynamicModeEnabled*: bool
    scrobbleEnabled*: bool
    aboutVisible*: bool
    reconnecting*: bool
    reconnectAttempts*: int
    giveUpReconnect*: bool
    basePos*: float
    baseTime*: float
    lastDataAt*: float
    nextRetryAt*: float
    retryDelayMs*: int
    spinnerFrame*: int
    queueCursor*: int
    queuePendingConfirm*: int
    eqVisible*: bool
    eqBands*: array[10, float]
    eqPreset*: string
    eqBandSelect*: int
    eqPresetSelect*: int
    eqScrollOffset*: int
    ytPlaybackStartTime*: float
    ytPauseDuration*: float
    ytPauseStartTime*: float
    ytDurationSec*: float
    ytSearchActive*: bool
    ytStreamResolving*: bool
    ytDownloadActive*: bool
    ytPlaylistFetching*: bool
    currentPlayingTitle*: string
    currentPlayingChannel*: string
    upNextMsg*: string
    upNextTimer*: int
    upNextScrollOffset*: int
    cursorVisible*: bool

const
  GTM_VERSION* {.strdefine.} = "0.5.0"
  GTM_BUILD_TIME* {.strdefine.} = ""

  FooterPresets*: Table[FooterPresetName, set[FooterModule]] = {
    fpnMinimal:   {fmPlayStatus},
    fpnCompact:   {fmPlayStatus, fmTime, fmBackend, fmQueueCount, fmEqPreset},
    fpnFull:      {fmPlayStatus, fmVolume, fmBackend, fmNextTrack, fmSelectCount, fmTime, fmDate, fmRepeatShuffle, fmSleepTimer, fmQueueCount, fmEqPreset, fmCurrentPlaylist},
    fpnInfo:      {fmPlayStatus, fmNextTrack, fmVolume, fmBackend, fmQueueCount},
    fpnNavigator: {fmPlayStatus, fmRepeatShuffle, fmSelectCount, fmTime, fmDate},
    fpnDebug:     {fmPlayStatus, fmTime, fmDate, fmSleepTimer, fmBackend, fmVolume, fmQueueCount, fmEqPreset},
    fpnMusic:     {fmPlayStatus, fmNextTrack, fmRepeatShuffle, fmVolume, fmQueueCount, fmEqPreset},
    fpnClock:     {fmPlayStatus, fmTime, fmDate}
  }.toTable()

type
  TrackInfo* = object
    id*: string
    title*: string
    artist*: string
    album*: string
    genre*: string
    path*: string
    duration*: float
    actualDuration*: float
    coverArt*: string
    favourite*: bool
    trackNumber*: int
    year*: int

  CrossfadeConfigState* = object
    enabled*: bool
    durationSecs*: int
    easing*: string

  ReverbConfigState* = object
    enabled*: bool
    roomScale*: float
    damping*: float
    preDelay*: float
    wet*: float
    dry*: float

  DynamicModeConfigState* = object
    enabled*: bool
    minQueueRemaining*: int
    maxHistory*: int

  ScrobbleConfigState* = object
    enabled*: bool
    apiKey*: string
    sessionToken*: string
    minPlaySecs*: int
    minPlayPct*: float

  DaemonState* = object
    version*: uint64
    status*: PlaybackStatus
    currentTrack*: TrackInfo
    queue*: seq[string]
    queueCursor*: uint64
    volume*: int
    shuffle*: bool
    repeat*: string
    mute*: bool
    timePos*: float
    duration*: float
    sleepTimer*: int
    crossfade*: CrossfadeConfigState
    eqPreset*: string
    eqEnabled*: bool
    loudnessMode*: LoudnessMode
    gapless*: bool
    preGainDb*: float
    reverb*: ReverbConfigState
    dynamicMode*: DynamicModeConfigState
    scrobble*: ScrobbleConfigState

proc stateDir*(): string =
  # Socket Locations fallback chain:
  #   $XDG_RUNTIME_DIR/gtm  ->  /tmp/gtm-$USER/gtm  ->
  #   $TMPDIR/gtm  ->  $HOME/.gtm/gtm
  let xdg = getEnv("XDG_RUNTIME_DIR", "")
  if xdg.len > 0:
    return xdg & "/gtm"
  let tmpUser = "/tmp/gtm-" & getEnv("USER", "unknown") & "/gtm"
  if dirExists(tmpUser.parentDir()) or getEnv("USER", "") != "":
    return tmpUser
  let tmpdir = getEnv("TMPDIR", "")
  if tmpdir.len > 0:
    return tmpdir & "/gtm"
  let home = getEnv("HOME", "")
  if home.len > 0:
    return home & "/.gtm/gtm"
  # Last resort: /tmp/gtm-$USER/gtm (regardless of dirExists)
  return tmpUser

proc statePath*(): string =
  stateDir() & "/gtm_state.json"

proc saveDaemonState*(s: DaemonState) =
  try:
    let dir = stateDir()
    if not dirExists(dir): createDir(dir)
    let j = %*{
      "version": s.version,
      "volume": s.volume,
      "shuffle": s.shuffle,
      "repeat": s.repeat,
      "mute": s.mute,
      "crossfade_enabled": s.crossfade.enabled,
      "crossfade_duration": s.crossfade.durationSecs,
      "crossfade_easing": s.crossfade.easing,
      "eq_preset": s.eqPreset,
      "eq_enabled": s.eqEnabled,
      "queue": s.queue,
      "queue_cursor": s.queueCursor,
      "gapless": s.gapless,
      "loudness_mode": s.loudnessMode.int,
      "pre_gain_db": s.preGainDb,
      "reverb_enabled": s.reverb.enabled,
      "reverb_room_scale": s.reverb.roomScale,
      "reverb_damping": s.reverb.damping,
      "reverb_pre_delay": s.reverb.preDelay,
      "reverb_wet": s.reverb.wet,
      "reverb_dry": s.reverb.dry,
      "dynamic_mode": s.dynamicMode.enabled,
      "dynamic_min_queue": s.dynamicMode.minQueueRemaining,
      "dynamic_max_history": s.dynamicMode.maxHistory,
      "scrobble_enabled": s.scrobble.enabled,
      "scrobble_api_key": s.scrobble.apiKey,
      "scrobble_session_token": s.scrobble.sessionToken,
      "scrobble_min_play_secs": s.scrobble.minPlaySecs,
      "scrobble_min_play_pct": s.scrobble.minPlayPct
    }
    writeFile(statePath(), $j)
  except:
    stderr.writeLine("[gtm] saveDaemonState: " & getCurrentExceptionMsg())

proc loadDaemonState*(): DaemonState =
  result = DaemonState(
    version: 0, status: psStopped, volume: 80,
    shuffle: false, repeat: "off", mute: false,
    crossfade: CrossfadeConfigState(enabled: false, durationSecs: 5, easing: "equal_power"),
    eqPreset: "flat", eqEnabled: false,
    loudnessMode: lmOff, gapless: true,
    preGainDb: -14.0,
    reverb: ReverbConfigState(enabled: false, roomScale: 0.7, damping: 0.5,
      preDelay: 0.02, wet: 0.3, dry: 0.7),
    dynamicMode: DynamicModeConfigState(enabled: false, minQueueRemaining: 3, maxHistory: 50),
    scrobble: ScrobbleConfigState(enabled: false, apiKey: "", sessionToken: "",
      minPlaySecs: 240, minPlayPct: 0.5)
  )
  let p = statePath()
  if not fileExists(p): return
  try:
    let j = parseJson(readFile(p))
    result.volume = j{"volume"}.getInt(80)
    result.shuffle = j{"shuffle"}.getBool(false)
    result.repeat = j{"repeat"}.getStr("off")
    result.mute = j{"mute"}.getBool(false)
    result.crossfade.enabled = j{"crossfade_enabled"}.getBool(false)
    result.crossfade.durationSecs = j{"crossfade_duration"}.getInt(5)
    result.crossfade.easing = j{"crossfade_easing"}.getStr("equal_power")
    result.eqPreset = j{"eq_preset"}.getStr("flat")
    result.eqEnabled = j{"eq_enabled"}.getBool(false)
    result.gapless = j{"gapless"}.getBool(true)
    result.loudnessMode = j{"loudness_mode"}.getInt(0).LoudnessMode
    result.preGainDb = j{"pre_gain_db"}.getFloat(-14.0)
    result.reverb.enabled = j{"reverb_enabled"}.getBool(false)
    result.reverb.roomScale = j{"reverb_room_scale"}.getFloat(0.7)
    result.reverb.damping = j{"reverb_damping"}.getFloat(0.5)
    result.reverb.preDelay = j{"reverb_pre_delay"}.getFloat(0.02)
    result.reverb.wet = j{"reverb_wet"}.getFloat(0.3)
    result.reverb.dry = j{"reverb_dry"}.getFloat(0.7)
    result.dynamicMode.enabled = j{"dynamic_mode"}.getBool(false)
    result.dynamicMode.minQueueRemaining = j{"dynamic_min_queue"}.getInt(3)
    result.dynamicMode.maxHistory = j{"dynamic_max_history"}.getInt(50)
    result.scrobble.enabled = j{"scrobble_enabled"}.getBool(false)
    result.scrobble.apiKey = j{"scrobble_api_key"}.getStr("")
    result.scrobble.sessionToken = j{"scrobble_session_token"}.getStr("")
    result.scrobble.minPlaySecs = j{"scrobble_min_play_secs"}.getInt(240)
    result.scrobble.minPlayPct = j{"scrobble_min_play_pct"}.getFloat(0.5)
    if j.hasKey("queue") and j["queue"].kind == JArray:
      for item in j["queue"]:
        if item.kind == JString:
          result.queue.add(item.getStr())
    result.queueCursor = uint64(j{"queue_cursor"}.getInt(0))
    result.version = uint64(j{"version"}.getInt(0))
  except:
    stderr.writeLine("[gtm] loadDaemonState: " & getCurrentExceptionMsg())

proc configDir*(): string =
  let xdg = getEnv("XDG_CONFIG_HOME", "")
  if xdg.len > 0:
    result = xdg & "/gtm"
  else:
    result = getEnv("HOME", "") & "/.config/gtm"

proc dataDir*(): string =
  let xdg = getEnv("XDG_DATA_HOME", "")
  if xdg.len > 0:
    result = xdg & "/gtm"
  else:
    result = getEnv("HOME", "") & "/.local/share/gtm"

proc pidPath*(): string = stateDir() & "/gtmd.pid"
proc sockPath*(): string = stateDir() & "/gtmd.sock"
proc pulseSockPath*(): string = stateDir() & "/gtmd.pulse"

proc clear*(o: var OverlayState) =
  o = OverlayState(kind: okNone)

proc isPlaylistView*(state: AppState): bool =
  state.tab == tabLibrary and state.filterScope == fsPlaylists

proc getPlayingTrack*(state: AppState): Track =
  if state.currentPlayingPath.len > 0:
    for t in state.libraryTracks:
      if t.path == state.currentPlayingPath:
        return t
    if state.currentPlayingTitle.len > 0:
      return Track(title: state.currentPlayingTitle, artist: state.currentPlayingChannel, path: state.currentPlayingPath)
  Track()

template markDirty*(state: var AppState, event: ChangeEvent) =
  state.dirtyFlags.incl(event)

template markDirtyBatch*(state: var AppState, events: varargs[ChangeEvent]) =
  for e in events: state.dirtyFlags.incl(e)

template clearDirty*(state: var AppState) =
  state.dirtyFlags = {}

template isDirty*(state: AppState, event: ChangeEvent): bool =
  event in state.dirtyFlags


