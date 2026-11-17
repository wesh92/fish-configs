# This file may also be encountered in conf.d after an older installation.
if not status is-interactive
    return
end

# Navigation
function ..
    cd ..
end
function ...
    cd ../..
end
function ....
    cd ../../..
end
function .....
    cd ../../../..
end

# Utilities
function grep
    command grep --color=auto $argv
end

abbr --add mv 'mv -v'
abbr --add rm 'rm -v'
abbr --add cp 'cp -v'

if command -sq git
    alias push 'git push'
end
if command -sq zeditor
    alias zed 'zeditor .'
end

# Abbreviations affect typed commands, not cat/find calls inside other functions.
if command -sq bat
    abbr --add cat bat
else if command -sq batcat
    abbr --add cat batcat
end
if command -sq fd
    abbr --add ff fd
else if command -sq fdfind
    abbr --add ff fdfind
end

# Preserve an explicit editor; prefer an installed editor over a desktop-only path.
if not set -q EDITOR; or test -z "$EDITOR"
    set -l editor_command
    for editor_command in zeditor nvim vim vi
        if command -sq "$editor_command"
            set -gx EDITOR "$editor_command"
            break
        end
    end
end

if command -sq fzf; and functions -q fzf_configure_bindings
    fzf_configure_bindings --directory=ctrl-f
    if set -q EDITOR; and not set -q fzf_directory_opts
        set -g fzf_directory_opts --bind "ctrl-o:execute($EDITOR {} </dev/tty >/dev/tty 2>&1)"
    end
end

# Fish 4 can scope abbreviations to a command without eval or generated functions.
# Unique names keep `git cp` separate from the command-position `cp -v` abbreviation.
function subcommand_abbr --argument-names cmd short expansion
    abbr --add --command "$cmd" --regex "$short" -- "$cmd"_"$short" "$expansion"
end

abbr --add cl clear
abbr --add c. clear
abbr --add clr clear
abbr --add c.. 'clear && cd ..'
abbr --add bye exit
abbr --add pls sudo

# Git subcommand abbreviations
abbr --add g git
subcommand_abbr git co checkout
subcommand_abbr git br branch
subcommand_abbr git c 'commit -S -m'
subcommand_abbr git s status
subcommand_abbr git d diff
subcommand_abbr git l log
subcommand_abbr git p pull
subcommand_abbr git f fetch
subcommand_abbr git t tag
subcommand_abbr git rh 'reset --hard'
subcommand_abbr git cp cherry-pick
subcommand_abbr git add 'add .'

# UV/Python subcommand abbreviations
abbr --add u uv
subcommand_abbr uv in init
subcommand_abbr uv a add
subcommand_abbr uv r remove
subcommand_abbr uv sy sync
subcommand_abbr uv syy sync
subcommand_abbr uv ex export
subcommand_abbr uv lo lock
subcommand_abbr uv tr tree
subcommand_abbr uv py python
subcommand_abbr uv pi 'python install'
subcommand_abbr uv pu 'python uninstall'
subcommand_abbr uv v version
subcommand_abbr uv pf 'python find'
subcommand_abbr uv pl 'python list'
subcommand_abbr uv pin 'python pin'
subcommand_abbr uv ve venv
