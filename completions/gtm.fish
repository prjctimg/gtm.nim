# gtm.fish — Fish completions for gtm (TUI + CLI)
#
# Install: copy into ~/.config/fish/completions/gtm.fish

complete -c gtm -f

# Global options
complete -c gtm -n __fish_use_subcommand -l help -s h -d "Show help and exit"
complete -c gtm -n __fish_use_subcommand -l version -s v -d "Show version and exit"
complete -c gtm -n __fish_use_subcommand -l debug -d "Enable debug logging"

# Top-level subcommands
complete -c gtm -n __fish_use_subcommand -a play -d "Play a file, URL or stream"
complete -c gtm -n __fish_use_subcommand -a pause -d "Toggle play/pause"
complete -c gtm -n __fish_use_subcommand -a toggle -d "Toggle play/pause"
complete -c gtm -n __fish_use_subcommand -a stop -d "Stop playback"
complete -c gtm -n __fish_use_subcommand -a next -d "Skip to next track"
complete -c gtm -n __fish_use_subcommand -a prev -d "Go to previous track"
complete -c gtm -n __fish_use_subcommand -a volume -d "Get or set volume (0-100)"
complete -c gtm -n __fish_use_subcommand -a shuffle -d "Toggle shuffle mode"
complete -c gtm -n __fish_use_subcommand -a repeat -d "Set repeat mode (off/one/all)"
complete -c gtm -n __fish_use_subcommand -a sleep -d "Set sleep timer in minutes"
complete -c gtm -n __fish_use_subcommand -a status -d "Show current playback status"
complete -c gtm -n __fish_use_subcommand -a now -d "Show current track info"
complete -c gtm -n __fish_use_subcommand -a queue -d "Manage the playback queue"
complete -c gtm -n __fish_use_subcommand -a kill -d "Stop the daemon process"
complete -c gtm -n __fish_use_subcommand -a daemon -d "Start the background daemon"
complete -c gtm -n __fish_use_subcommand -a help -d "Show help and exit"

# play — audio files, URLs and directories
complete -c gtm -n "__fish_seen_subcommand_from play" -F -d "Audio file or URL"
complete -c gtm -n "__fish_seen_subcommand_from play" -a "(__fish_complete_directories)" -d "Music folder"

# volume — predefined levels
complete -c gtm -n "__fish_seen_subcommand_from volume" -a "0 10 20 30 40 50 60 70 80 90 100" -d "Volume level (0-100)"

# shuffle — predefined options
complete -c gtm -n "__fish_seen_subcommand_from shuffle" -a "on off" -d "Enable or disable shuffle"
complete -c gtm -n "__fish_seen_subcommand_from shuffle" -a "true false" -d "Enable or disable shuffle"
complete -c gtm -n "__fish_seen_subcommand_from shuffle" -a "1 0" -d "Enable or disable shuffle"

# repeat — predefined modes
complete -c gtm -n "__fish_seen_subcommand_from repeat" -a "off" -d "No repeat"
complete -c gtm -n "__fish_seen_subcommand_from repeat" -a "one" -d "Repeat the current track"
complete -c gtm -n "__fish_seen_subcommand_from repeat" -a "all" -d "Repeat the whole queue"
complete -c gtm -n "__fish_seen_subcommand_from repeat" -a "0 1 2" -d "Repeat mode (0=none, 1=all, 2=one)"

# sleep — common minute presets
complete -c gtm -n "__fish_seen_subcommand_from sleep" -a "5 10 15 30 60 90 120" -d "Minutes until sleep timer"

# queue subcommands
complete -c gtm -n "__fish_seen_subcommand_from queue" -a "list" -d "Show the playback queue"
complete -c gtm -n "__fish_seen_subcommand_from queue" -a "add" -d "Add files, URLs or folders to the queue"
complete -c gtm -n "__fish_seen_subcommand_from queue" -a "remove" -d "Remove a queue item by index"
complete -c gtm -n "__fish_seen_subcommand_from queue" -a "move" -d "Move a queue item to another index"
complete -c gtm -n "__fish_seen_subcommand_from queue" -a "clear" -d "Clear the whole queue"
complete -c gtm -n "__fish_seen_subcommand_from queue" -a "set" -d "Replace the queue with the given items"

# queue add / set — audio files, URLs and folders (added recursively)
complete -c gtm -n "__fish_seen_subcommand_from queue; and __fish_seen_subcommand_from add set" -F -d "Audio file or URL"
complete -c gtm -n "__fish_seen_subcommand_from queue; and __fish_seen_subcommand_from add set" -a "(__fish_complete_directories)" -d "Music folder (added recursively)"

# queue remove / move — queue indices
complete -c gtm -n "__fish_seen_subcommand_from queue; and __fish_seen_subcommand_from remove" -a "0 1 2 3 4 5 6 7 8 9" -d "Queue index"
complete -c gtm -n "__fish_seen_subcommand_from queue; and __fish_seen_subcommand_from move" -a "0 1 2 3 4 5 6 7 8 9" -d "Queue index"
