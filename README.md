# gtm.nim 👑

[![Version](https://img.shields.io/github/v/release/prjctimg/gtm)](https://github.com/prjctimg/gtm/releases/latest)
[![License: GPL-3.0](https://img.shields.io/badge/License-GPL--3.0-blue.svg)](LICENSE)
[![Nim 2.0+](https://img.shields.io/badge/nim-2.0+-orange.svg)](https://nim-lang.org)

Feature rich terminal audio player with background playback support and YouTube/Spotify integration. The original Nim implementation of the [gtm spec](https://github.com/prjctimg/gtm.spec).

## Install

You can use the shared [`install.sh`](https://github.com/prjctimg/gtm.spec/blob/main/install.sh) script for an interactive, hassle free installation. It asks which implementation (gtm.rs or gtm.nim) and which install type you want:

```bash
curl -fsSL https://raw.githubusercontent.com/prjctimg/gtm.spec/main/install.sh | bash
```

Or pick this implementation directly:

```bash
curl -fsSL https://raw.githubusercontent.com/prjctimg/gtm.spec/main/install.sh | bash -s -- --impl nim
```

### Build from Source

Requires Nim 2.0+, `nimble`, and the FFmpeg development libraries (`libavformat`, `libavcodec`, `libavutil`, `libswresample`, plus ALSA on Linux). Install the Nim dependencies first:

```bash
nimble install -y
```

Then build the daemon and TUI:

```bash
nim c -d:release src/gtmd.nim
nim c -d:release src/gtm.nim
```

Alternatively run the full build script (also generates the man page):

```bash
nim e build.nims
```

If the dependencies live outside the standard `~/.nimble/pkgs` layout, point to them via env vars: `NIMWAVE_PATH`, `ILLWAVE_PATH`, `ANSIUTILS_PATH`.

### Pre-built binaries

Grab one for your target system from the [releases page](https://github.com/prjctimg/gtm.nim/releases/latest).

## Codebase layout

The codebase mirrors the architecture of the gtm spec, with the TUI client talking to a background daemon over a Unix socket:

| File | Description |
|---|---|
| `src/gtm.nim` | TUI client entry point |
| `src/gtmd.nim` | Daemon entry point |
| `src/daemon.nim` | Daemon — manages queue, library, IPC socket, FFmpeg playback |
| `src/client.nim` | `DaemonClient` — IPC client over Unix socket |
| `src/cli.nim` | CLI mode and subcommands |
| `src/audio.nim` | Audio backends (FFmpeg, mixer with crossfade/EQ, daemon client) |
| `src/library.nim` | SQLite library database |
| `src/ytdlp.nim` | YouTube search/resolve via yt-dlp |
| `src/state.nim` | `AppState`, config, event system |
| `src/ui.nim` | TUI views and overlays (help, equalizer, about) |
| `src/theme.nim` | Colorscheme / theming |
| `src/commands.nim` | Keybindings and command dispatch |
| `src/icons.nim` | Icon packs |
| `src/mpris.nim` | MPRIS D-Bus interface (optional) |

## Docs

- [Wiki](https://github.com/prjctimg/gtm.nim/wiki)
- [gtm.spec](https://github.com/prjctimg/gtm.spec)
- [gtm-config(1)](https://github.com/prjctimg/gtm.spec.wiki/Manpages)
- [gtm-keybindings(1)](https://github.com/prjctimg/gtm.spec.wiki/Manpages)

## Dependencies

The Nim implementation relies on the following libraries:

| Library | Used for |
|---|---|
| `nimwave` | TUI toolkit (rendering, input) |
| `illwave` | Immediate-mode UI and key handling |
| `ansiutils` | ANSI terminal utilities |
| `msgpack4nim` | MessagePack serialization for IPC (vendored in `vendor/`) |
| SQLite (amalgamation) | Library database (vendored C in `vendor/sqlite`) |
| FFmpeg (`ffmpeg_impl.c`) | Audio decoding, crossfade, equalizer (vendored C in `vendor/ffmpeg`, links `libavformat`/`libavcodec`/`libavutil`/`libswresample` + ALSA) |
| nim-dbus | MPRIS D-Bus interface (optional) |

System dependencies: Nim 2.0+, GCC (compiles the vendored C code), FFmpeg development libraries, and `yt-dlp` (falls back to `youtube-dl`) for YouTube integration.

## Contributing

I'm currently unable to handle external contributions because I'm actively working on it and any bugs or issues you may notice  may well already be noted . Also I am doing this for fun and learning reasons.

Feel free to [fork off](https://github.com/prjctimg/gtm.nim/fork) though and on your way out don't forget to  checkout the [gtm spec](https://github.com/prjctimg/gtm.spec) for some domain specific notes on the reasons why the code is structured as it is.

---

> ## License 📜
>
> (c) 2025 - present, [prjctimg](https://prjctimg.me)
>
> This is free software, released under the GPL-3.0 license.

---
