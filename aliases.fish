# Navigation
function ..    ; cd .. ; end
function ...   ; cd ../.. ; end
function ....  ; cd ../../.. ; end
function ..... ; cd ../../../.. ; end

# Utilities
function grep     ; command grep --color=auto $argv ; end

# mv, rm, cp
abbr mv 'mv -v'
abbr rm 'rm -v'
abbr cp 'cp -v'

alias push="git push"

# `g co`, etc. subcommand expansion with `abbr`.
function subcommand_abbr
  set -l cmd "$argv[1]"
  set -l short "$argv[2]"
  set -l long "$argv[3]"

  # Check that these strings are safe, since we're going to eval. 👺
  if not string match --regex --quiet '^[a-z]*$' "$short"
    or not string match --regex --quiet '^[a-zA-Z0-9 -]*$' "$long"
    echo "Scary unsupported alias or expansion $short $long"; exit 1; 
  end

  set -l abbr_temp_fn_name (string join "_" "abbr" "$cmd" "$short")
  set -l abbr_temp_fn "function $abbr_temp_fn_name
    set --local tokens (commandline --tokenize)
    if test \$tokens[1] = \"$cmd\"
      echo $long
    else
      echo $short
    end; 
  end; 
  abbr --add $short --position anywhere --function $abbr_temp_fn_name"
  eval "$abbr_temp_fn"
end

abbr cl "clear"
abbr c. "clear"
abbr clr "clear"
abbr c.. "clear && cd .."
abbr bye "exit"
abbr pls "sudo"

# Git subcommand abbreviations
abbr g "git"

subcommand_abbr git co "checkout"
subcommand_abbr git br "branch"
subcommand_abbr git c "commit -S -m"
subcommand_abbr git s "status"
subcommand_abbr git d "diff"
subcommand_abbr git l "log"
subcommand_abbr git p "pull"
subcommand_abbr git f "fetch"
subcommand_abbr git t "tag"
subcommand_abbr git rh "reset --hard"
subcommand_abbr git cp "cherry-pick"
subcommand_abbr git add "add ."

# UV/Python subcommand abbreviations
abbr u "uv"

subcommand_abbr uv in "init"
subcommand_abbr uv a "add"
subcommand_abbr uv r "remove"
subcommand_abbr uv sy "sync"
subcommand_abbr uv syy "sync"
subcommand_abbr uv ex "export"
subcommand_abbr uv lo "lock"
subcommand_abbr uv tr "tree"
subcommand_abbr uv py "python"
subcommand_abbr uv pi "python install"
subcommand_abbr uv pu "python uninstall"
subcommand_abbr uv v "version"
subcommand_abbr uv pf "python find"
subcommand_abbr uv pl "python list"
subcommand_abbr uv pin "python pin"
subcommand_abbr uv ve "venv"

# Project Navigation
function proj
  cd ~/projects/
end

#### Additions ####