import unittest, json, strutils, os, sequtils
import ../src/ytdlp, ../src/state
import ../src/library, ../src/cli

suite "parseYtJsonLine":
  test "parses a valid video result":
    let raw = """{"id":"abc123","title":"Test Video","webpage_url":"https://youtube.com/watch?v=abc123","duration":245.5,"channel":"TestChannel","ie_key":"Youtube"}"""
    let r = parseYtJsonLine(raw)
    check r.title == "Test Video"
    check r.url == "https://youtube.com/watch?v=abc123"
    check r.duration == "4:05"
    check r.channel == "TestChannel"
    check r.kind == srkVideo

  test "parses a playlist result":
    let raw = """{"title":"Mix","webpage_url":"https://youtube.com/playlist?list=PL123","ie_key":"YoutubePlaylist","channel":"Channel"}"""
    let r = parseYtJsonLine(raw)
    check r.kind == srkPlaylist
    check r.title == "Mix"

  test "parses result with uploader instead of channel":
    let raw = """{"id":"xyz","title":"Song","url":"https://youtube.com/watch?v=xyz","duration":180,"uploader":"ArtistName"}"""
    let r = parseYtJsonLine(raw)
    check r.channel == "ArtistName"
    check r.kind == srkVideo

  test "handles missing duration":
    let raw = """{"id":"x","title":"No Dur","url":"https://youtube.com/watch?v=x"}"""
    let r = parseYtJsonLine(raw)
    check r.duration == ""
    check r.title == "No Dur"

  test "handles empty string":
    let r = parseYtJsonLine("")
    check r.title.len == 0

  test "handles invalid JSON":
    let r = parseYtJsonLine("this is not json")
    check r.title.len == 0

  test "parses flat playlist format":
    let raw = """{"_type":"playlist","title":"My Playlist","webpage_url":"https://youtube.com/playlist?list=PL1","ie_key":"Youtube","entries":[]}"""
    let r = parseYtJsonLine(raw)
    check r.kind == srkPlaylist
    check r.title == "My Playlist"

  test "duration formats correctly":
    let cases = [
      ("""{"title":"A","url":"x","duration":0}""", "0:00"),
      ("""{"title":"B","url":"x","duration":59}""", "0:59"),
      ("""{"title":"C","url":"x","duration":60}""", "1:00"),
      ("""{"title":"D","url":"x","duration":3661}""", "61:01"),
    ]
    for (raw, expected) in cases:
      let r = parseYtJsonLine(raw)
      check r.duration == expected

suite "cookieFlags":
  test "empty source returns empty string":
    check cookieFlags("") == ""

  test "file path uses --cookies":
    let r = cookieFlags("/path/to/cookies.txt")
    check "--cookies" in r
    check "/path/to/cookies.txt" in r

  test "browser name uses --cookies-from-browser":
    let r = cookieFlags("firefox")
    check "--cookies-from-browser" in r
    check "firefox" in r

suite "jsRuntimeFlags":
  test "empty runtime returns empty string":
    check jsRuntimeFlags("") == ""

  test "runtime flag includes ejs":
    let r = jsRuntimeFlags("node")
    check "node" in r
    check "ejs:github" in r

suite "queue CLI parse":
  test "bare queue defaults to list":
    let r = parseArgs(@["queue"])
    check r.subcmd == scQueue
    check r.queueAction == "list"

  test "queue add collects all targets":
    let r = parseArgs(@["queue", "add", "a.mp3", "~/Music/album/", "https://youtu.be/x"])
    check r.subcmd == scQueue
    check r.queueAction == "add"
    check r.queueTargets == @["a.mp3", "~/Music/album/", "https://youtu.be/x"]

  test "queue remove parses index":
    let r = parseArgs(@["queue", "remove", "3"])
    check r.queueAction == "remove"
    check r.queueIndex == 3

  test "queue move parses from/to":
    let r = parseArgs(@["queue", "move", "1", "5"])
    check r.queueAction == "move"
    check r.queueFrom == 1
    check r.queueTo == 5

  test "queue clear takes no targets":
    let r = parseArgs(@["queue", "clear"])
    check r.queueAction == "clear"
    check r.queueTargets.len == 0

  test "queue set collects targets":
    let r = parseArgs(@["queue", "set", "x.mp3", "y.mp3"])
    check r.queueAction == "set"
    check r.queueTargets == @["x.mp3", "y.mp3"]

suite "loadFromArgs expansion":
  test "existing file path passes through":
    let tmp = getTempDir() / "gtm_single_" & $os.getCurrentProcessId() & ".mp3"
    writeFile(tmp, "x")
    defer: removeFile(tmp)
    check loadFromArgs(@[tmp]) == @[tmp]

  test "directory is expanded recursively":
    let base = getTempDir() / "gtm_test_dir_" & $os.getCurrentProcessId()
    removeDir(base)
    createDir(base / "sub")
    writeFile(base / "a.mp3", "x")
    writeFile(base / "b.flac", "x")
    writeFile(base / "sub" / "c.wav", "x")
    writeFile(base / "notes.txt", "x")
    defer: removeDir(base)
    let expanded = loadFromArgs(@[base])
    let names = expanded.mapIt(it.extractFilename())
    check "a.mp3" in names
    check "b.flac" in names
    check "c.wav" in names
    check "notes.txt" notin names

  test "URL passes through unexpanded":
    let url = "https://youtu.be/abc123"
    check loadFromArgs(@[url]) == @[url]
