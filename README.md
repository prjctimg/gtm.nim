# gtm.nim 👑

[![Version](https://img.shields.io/github/v/release/prjctimg/gtm)](https://github.com/prjctimg/gtm/releases)
[![License: GPL-3.0](https://img.shields.io/badge/License-GPL--3.0-blue.svg)](LICENSE)
[![Nim 2.0+](https://img.shields.io/badge/nim-2.0+-orange.svg)](https://nim-lang.org)

Terminal music player with YouTube integration, crossfade, and loudness compensation. Nim implementation of the GTM protocol.

## Install

```bash
curl -fsSL https://raw.githubusercontent.com/prjctimg/gtm/main/install.sh | bash
```

## CLI Subcommands

```
gtm play [file]       # Play a file or URL
gtm pause             # Toggle play/pause
gtm stop              # Stop playback
gtm next              # Skip to next track
gtm prev              # Go to previous track
gtm volume [0-100]    # Get/set volume
gtm shuffle           # Toggle shuffle mode
gtm repeat [0-2]      # Set repeat mode (0=none, 1=all, 2=one)
gtm sleep [minutes]   # Set sleep timer
gtm status            # Show playback status
gtm now               # Show current track info
gtm kill              # Stop the daemon process
gtm daemon            # Start daemon manually
gtm help              # Show help
gtm version           # Show version
```

## Links

- **Full specification**: [gtm.spec](https://github.com/prjctimg/gtm.spec)
- **Protocol**: [protocol.md](https://github.com/prjctimg/gtm.spec/blob/main/protocol.md)
- **Configuration**: [gtm-config(1)](https://github.com/prjctimg/gtm.spec/blob/main/man/gtm-config.1.md)
- **Keybindings**: [gtm-keybindings(1)](https://github.com/prjctimg/gtm.spec/blob/main/man/gtm-keybindings.1.md)

## License

GPL-3.0 — © 2026 [prjctimg](https://prjctimg.me)
