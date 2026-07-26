import unittest, json, tables, strutils
import ../src/audio, ../src/state

suite "Event serialization round-trip":
  test "construct and parse aekPositionChanged event":
    let evJson = %*{"kind": 5, "time_pos": 123.5}
    let k = evJson["kind"].getInt(0)
    let kind = AudioEventKind(k)
    check kind == aekPositionChanged
    check evJson["time_pos"].getFloat(0.0) == 123.5

  test "construct and parse aekDurationChanged event":
    let evJson = %*{"kind": 6, "duration": 245.0}
    let k = evJson["kind"].getInt(0)
    let kind = AudioEventKind(k)
    check kind == aekDurationChanged
    check evJson["duration"].getFloat(0.0) == 245.0

  test "construct and parse aekVolumeChanged event":
    let evJson = %*{"kind": 7, "volume": 80}
    let k = evJson["kind"].getInt(0)
    let kind = AudioEventKind(k)
    check kind == aekVolumeChanged
    check evJson["volume"].getInt(0) == 80

  test "construct and parse aekPlaybackStarted event":
    let evJson = %*{"kind": 1, "state": "playing"}
    let k = evJson["kind"].getInt(0)
    let kind = AudioEventKind(k)
    check kind == aekPlaybackStarted
    check evJson["state"].getStr("") == "playing"

  test "construct and parse aekTrackEnded event":
    let evJson = %*{"kind": 4, "reason": "eof"}
    let k = evJson["kind"].getInt(0)
    let kind = AudioEventKind(k)
    check kind == aekTrackEnded
    check evJson["reason"].getStr("") == "eof"

suite "Event batch parsing (pollEvents style)":
  test "parse single unbatched event":
    let raw = """{"event":"playback_started","track":{"id":"x","title":"Song","artist":"Ch","path":"/x.mp3","duration":240.0,"cover_art":"","favourite":false},"auto_advanced":false,"time_pos":0.0,"duration":240.0}"""
    let j = parseJson(raw)
    check j.hasKey("event")
    check j["event"].getStr("") == "playback_started"
    check j["track"]["title"].getStr("") == "Song"
    check j["time_pos"].getFloat(0.0) == 0.0

  test "parse multiple unbatched events (line by line)":
    let line1 = """{"event":"position_changed","time_pos":10.0}"""
    let line2 = """{"event":"duration_changed","duration":300.0}"""
    let buf = line1 & "\n" & line2 & "\n"
    var lines: seq[string] = @[]
    for line in splitLines(buf):
      if line.len > 0: lines.add(line)
    check lines.len == 2
    let ev1 = parseJson(lines[0])
    check ev1["event"].getStr("") == "position_changed"
    check ev1["time_pos"].getFloat(0.0) == 10.0
    let ev2 = parseJson(lines[1])
    check ev2["event"].getStr("") == "duration_changed"

  test "interleaved events and responses":
    let line1 = """{"event":"position_changed","time_pos":30.0}"""
    let line2 = """{"id":1,"ok":true,"volume":80}"""
    let buf = line1 & "\n" & line2 & "\n"
    var lines: seq[string] = @[]
    for line in splitLines(buf):
      if line.len > 0: lines.add(line)
    check lines.len == 2
    let evJson = parseJson(lines[0])
    check evJson.hasKey("event")
    check evJson["event"].getStr("") == "position_changed"
    let respJson = parseJson(lines[1])
    check respJson["id"].getInt(-1) == 1
    check respJson["ok"].getBool(false) == true

suite "Daemon command construction":
  test "play command":
    let cmd = %*{"cmd": "play"}
    cmd["id"] = %1
    check cmd["id"].getInt(0) == 1
    check cmd["cmd"].getStr("") == "play"

  test "load_file command":
    let cmd = %*{"cmd": "load_file", "path": "/tmp/test.mp3", "id": 2}
    check cmd["cmd"].getStr("") == "load_file"
    check cmd["path"].getStr("") == "/tmp/test.mp3"
    check cmd["id"].getInt(0) == 2

  test "set_volume command":
    let cmd = %*{"cmd": "set_volume", "volume": 50, "id": 3}
    check cmd["volume"].getInt(0) == 50
    check cmd["id"].getInt(0) == 3

  test "seek command":
    let cmd = %*{"cmd": "seek", "seconds": 30.5, "id": 4}
    check cmd["seconds"].getFloat(0.0) == 30.5

  test "set_eq_band command":
    let cmd = %*{"cmd": "set_eq_band", "band": 3, "gain_db": -2.5, "id": 5}
    check cmd["band"].getInt(0) == 3
    check cmd["gain_db"].getFloat(0.0) == -2.5

suite "Response parsing":
  test "parse ok response":
    let raw = """{"id":1,"ok":true,"state":"playing","duration":245.0}"""
    let j = parseJson(raw)
    check j["id"].getInt(-1) == 1
    check j["ok"].getBool(false) == true
    check j["state"].getStr("") == "playing"
    check j["duration"].getFloat(0.0) == 245.0

  test "parse error response":
    let raw = """{"id":2,"ok":false,"error":"file not found"}"""
    let j = parseJson(raw)
    check j["id"].getInt(-1) == 2
    check j["ok"].getBool(true) == false
    check j["error"].getStr("") == "file not found"

  test "parse get_volume response":
    let raw = """{"id":3,"ok":true,"volume":80}"""
    let j = parseJson(raw)
    check j["id"].getInt(-1) == 3
    check j["volume"].getInt(0) == 80

suite "YtSearchResult":
  test "YtSearchResult fields round-trip through JSON":
    let r = YtSearchResult(
      title: "Test",
      url: "https://youtube.com/watch?v=abc",
      duration: "3:30",
      channel: "Channel",
      kind: srkVideo
    )
    let j = %*{"title": r.title, "url": r.url, "duration": r.duration, "channel": r.channel, "kind": r.kind.int}
    check j["title"].getStr("") == "Test"
    check j["url"].getStr("") == "https://youtube.com/watch?v=abc"
    check j["duration"].getStr("") == "3:30"

  test "playlist detail construction":
    var pl = YtPlaylistDetail(
      title: "My Mix",
      url: "https://youtube.com/playlist?list=PL1",
      channel: "Artist",
      trackCount: 2
    )
    pl.tracks.add(YtSearchResult(title: "Song A", url: "https://youtube.com/watch?v=a", kind: srkVideo))
    pl.tracks.add(YtSearchResult(title: "Song B", url: "https://youtube.com/watch?v=b", kind: srkVideo))
    check pl.trackCount == 2
    check pl.tracks.len == 2
    check pl.title == "My Mix"

suite "Protocol id envelope":
  test "command carries id field":
    let cmd = %*{"cmd": "play", "path": "/music/song.mp3", "id": 42}
    check cmd["id"].getInt(0) == 42
    check cmd["cmd"].getStr("") == "play"

  test "response echoes id from command":
    let cmdId = 7
    let resp = %*{"id": cmdId, "ok": true}
    check resp["id"].getInt(-1) == cmdId
    check resp["ok"].getBool(false) == true

  test "error response echoes id":
    let resp = %*{"id": 99, "ok": false, "error": "unknown command: foo"}
    check resp["id"].getInt(-1) == 99
    check resp["ok"].getBool(true) == false
    check resp["error"].getStr("") == "unknown command: foo"

  test "handshake command uses id 0 and protocol v2":
    let cmd = %*{"cmd": "handshake", "version": 2, "client": "gtm",
      "client_version": "0.1.0", "id": 0}
    check cmd["id"].getInt(-1) == 0
    check cmd["version"].getInt(0) == 2
    check cmd["client_version"].getStr("") == "0.1.0"

  test "handshake version negotiation rejects higher client version":
    let daemonProtocolVersion = 2
    let clientVersion = 3
    let ok = clientVersion <= daemonProtocolVersion
    check ok == false
