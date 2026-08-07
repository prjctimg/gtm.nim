# gtm.bash — Bash completions for gtm (TUI + CLI)
#
# Install: source this file, or copy it into
# /etc/bash_completion.d/gtm.bash (or $PREFIX/share/bash-completion/completions/gtm.bash).

_gtm() {
    local cur prev words cword
    if declare -F _init_completion >/dev/null 2>&1; then
        _init_completion || return
    else
        cur="${COMP_WORDS[COMP_CWORD]}"
        prev="${COMP_WORDS[COMP_CWORD-1]}"
    fi

    local commands="play pause toggle stop next prev volume shuffle repeat sleep status now queue kill daemon help"
    local queue_actions="list add remove move clear set"
    local shuffle_vals="on off true false 1 0"
    local repeat_vals="off one all 0 1 2"
    local volume_vals="0 10 20 30 40 50 60 70 80 90 100"
    local sleep_vals="5 10 15 30 60 90 120"

    if [ "$COMP_CWORD" -eq 1 ]; then
        COMPREPLY=( $(compgen -W "$commands --help --version -h -v" -- "$cur") )
        return
    fi

    case "${COMP_WORDS[1]}" in
        queue)
            if [ "$COMP_CWORD" -eq 2 ]; then
                COMPREPLY=( $(compgen -W "$queue_actions" -- "$cur") )
            elif [ "$COMP_CWORD" -ge 3 ]; then
                case "${COMP_WORDS[2]}" in
                    add|set)
                        COMPREPLY=( $(compgen -f -- "$cur"; compgen -d -- "$cur") )
                        ;;
                    remove|move)
                        COMPREPLY=( $(compgen -W "0 1 2 3 4 5 6 7 8 9" -- "$cur") )
                        ;;
                esac
            fi
            ;;
        play)
            COMPREPLY=( $(compgen -f -- "$cur"; compgen -d -- "$cur") )
            ;;
        volume)
            COMPREPLY=( $(compgen -W "$volume_vals" -- "$cur") )
            ;;
        shuffle)
            COMPREPLY=( $(compgen -W "$shuffle_vals" -- "$cur") )
            ;;
        repeat)
            COMPREPLY=( $(compgen -W "$repeat_vals" -- "$cur") )
            ;;
        sleep)
            COMPREPLY=( $(compgen -W "$sleep_vals" -- "$cur") )
            ;;
    esac
}

complete -F _gtm gtm
