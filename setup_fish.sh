#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
readonly SCRIPT_DIR
# Same Fisher release as the Arch package; used only when Fisher is not installed.
readonly FISHER_REF=a04308be92daa6cfecdbb0ca58b1e8508664cff2
config_dir="${XDG_CONFIG_HOME:-$HOME/.config}/fish"
backup_dir=''
bootstrap=''
worker_config_home=''

log() { printf '%s\n' "$*" >&2; }
die() { log "Error: $*"; exit 1; }

cleanup() {
    local result=$?
    if [[ -n $bootstrap ]]; then
        rm -f -- "$bootstrap"
    fi
    if [[ -n $worker_config_home ]]; then
        rm -f -- "$worker_config_home/fish/fish_variables"
        rmdir -- "$worker_config_home/fish" "$worker_config_home" 2>/dev/null || true
    fi
    if [[ $result -ne 0 && -n $backup_dir ]]; then
        log "Setup failed. Original configuration is retained at: $backup_dir"
    fi
}
trap cleanup EXIT

show_help() {
    cat <<'EOF'
Usage: setup_fish.sh [OPTIONS]

Install this checkout's Fish 4+ configuration for the current user.

  -h, --help          Show help
  --force             Skip the confirmation prompt
  --dry-run           Describe the setup without changing files or installing anything
  --no-backup         Do not back up the existing Fish configuration
  --install-missing   Install dependencies from Arch/CachyOS or Ubuntu repositories
  --skip-plugins      Install only config.fish and aliases.fish (no network required)
  --no-change-shell   Leave the login shell unchanged (recommended in containers)

Uses files next to this script, regardless of the current directory, and honors
XDG_CONFIG_HOME. Existing configuration, including plugins and legacy conf.d
aliases, is backed up together. Restore that directory manually if needed;
package installation and login-shell changes are not automatically rolled back.
EOF
}

as_root() {
    if [[ $(id -u) -eq 0 ]]; then
        "$@"
    elif command -v sudo >/dev/null 2>&1; then
        sudo "$@"
    else
        die "sudo is required to install dependencies or register a login shell"
    fi
}

missing_dependencies() {
    command -v fish >/dev/null 2>&1 || missing+=(fish)
    if [[ $skip_plugins == false ]]; then
        command -v curl >/dev/null 2>&1 || missing+=(curl)
        command -v tar >/dev/null 2>&1 || missing+=(tar)
        command -v fzf >/dev/null 2>&1 || missing+=(fzf)
        command -v fd >/dev/null 2>&1 || command -v fdfind >/dev/null 2>&1 || missing+=(fd)
        command -v bat >/dev/null 2>&1 || command -v batcat >/dev/null 2>&1 || missing+=(bat)
        command -v ssh-agent >/dev/null 2>&1 || missing+=(ssh-agent)
    fi
}

ensure_dependencies() {
    local -a missing=()
    missing_dependencies
    if [[ ${#missing[@]} -eq 0 ]]; then
        return
    fi
    if [[ $install_missing == false ]]; then
        die "Missing dependencies: ${missing[*]}. Use --install-missing or --skip-plugins."
    fi
    [[ -r /etc/os-release ]] || die 'Cannot detect the package manager'
    local os
    os=$(. /etc/os-release; printf '%s' "${ID:-}")
    case "$os" in
        arch|cachyos)
            local -a packages=(fish)
            if [[ $skip_plugins == false ]]; then
                packages+=(fisher curl tar fzf fd bat openssh)
            fi
            # Fish and its dependencies are official packages: no yay/AUR bootstrap.
            as_root pacman -S --needed --noconfirm "${packages[@]}"
            ;;
        ubuntu)
            local -a packages=(fish)
            if [[ $skip_plugins == false ]]; then
                packages+=(curl tar fzf fd-find bat openssh-client)
            fi
            as_root apt-get update
            as_root apt-get install -y "${packages[@]}"
            ;;
        *) die "Unsupported OS: $os. Install Fish 4+ and the dependencies first." ;;
    esac
    missing=()
    missing_dependencies
    [[ ${#missing[@]} -eq 0 ]] || die "Still missing dependencies: ${missing[*]}"
}

# --no-config also skips Fish's default function path on Fish 4.9. Restore only
# autoload directories, never the old user's config or conf.d startup scripts.
clean_fish() {
    FISH_WORKER_CONFIG_HOME="$worker_config_home" fish --no-config --init-command '
        set -g fish_function_path "$__fish_config_dir/functions" "$__fish_sysconf_dir/functions" "$__fish_data_dir/vendor_functions.d" "$__fish_data_dir/functions"
        # __fish_config_dir is already fixed to the real target. Only child
        # processes (including Fisher download workers) see this empty config.
        if test -n "$FISH_WORKER_CONFIG_HOME"
            set -gx XDG_CONFIG_HOME "$FISH_WORKER_CONFIG_HOME"
        end
    ' "$@"
}

install_plugins() {
    worker_config_home=$(mktemp -d "${TMPDIR:-/tmp}/fish-workers.XXXXXX")
    install -d -m 0700 "$worker_config_home/fish"
    if ! clean_fish -c 'functions --query fisher'; then
        bootstrap=$(mktemp "${TMPDIR:-/tmp}/fisher.XXXXXX")
        curl --fail --silent --show-error --location \
            "https://raw.githubusercontent.com/jorgebucaran/fisher/$FISHER_REF/functions/fisher.fish" \
            --output "$bootstrap"
        FISHER_BOOTSTRAP="$bootstrap" FISHER_BOOTSTRAP_REF="$FISHER_REF" \
            clean_fish -c 'source "$FISHER_BOOTSTRAP"; and fisher install "jorgebucaran/fisher@$FISHER_BOOTSTRAP_REF"'
    fi
    FISH_PLUGIN_MANIFEST="$SCRIPT_DIR/fish_plugins" clean_fish -c '
        set -l plugins (string match --regex --invert "^\\s*(#|\$)" < "$FISH_PLUGIN_MANIFEST")
        test (count $plugins) -gt 0; or exit 1
        fisher install $plugins; or exit $status
        # Fisher may return zero after only some downloads/installs succeeded.
        if not test -r "$__fish_config_dir/fish_plugins"
            printf "Error: Fisher did not write its installed plugin manifest\\n" >&2
            exit 1
        end
        set -l installed (string match --regex --invert "^\\s*(#|\$)" < "$__fish_config_dir/fish_plugins")
        for plugin in $plugins
            if not contains -- "$plugin" $installed
                printf "Error: requested plugin was not installed: %s\\n" "$plugin" >&2
                exit 1
            end
        end
    '
}

change_shell() {
    local fish_path current_shell
    fish_path=$(command -v fish)
    current_shell=$(getent passwd "$(id -un)" | cut -d: -f7)
    if [[ $current_shell == "$fish_path" ]]; then
        return
    fi
    if ! grep -Fxq -- "$fish_path" /etc/shells; then
        printf '%s\n' "$fish_path" | as_root tee -a /etc/shells >/dev/null
    fi
    chsh -s "$fish_path"
}

main() {
    local force=false dry_run=false no_backup=false
    local install_missing=false skip_plugins=false no_change_shell=false
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -h|--help) show_help; return ;;
            --force) force=true ;;
            --dry-run) dry_run=true ;;
            --no-backup) no_backup=true ;;
            --install-missing) install_missing=true ;;
            --skip-plugins) skip_plugins=true ;;
            --no-change-shell) no_change_shell=true ;;
            --rollback) die 'Restore the retained backup directory manually; automatic rollback is not supported.' ;;
            *) die "Unknown option: $1 (see --help)" ;;
        esac
        shift
    done

    local filename
    for filename in config.fish aliases.fish conf.d/00-cachyos.fish fish_plugins; do
        [[ -r $SCRIPT_DIR/$filename ]] || die "Missing $SCRIPT_DIR/$filename; run from a complete checkout"
    done
    if [[ $dry_run == true ]]; then
        log "Would install configuration from $SCRIPT_DIR into $config_dir"
        log "Install missing dependencies: $install_missing; back up existing configuration: $([[ $no_backup == false ]] && printf yes || printf no)"
        log "Install pinned plugins: $([[ $skip_plugins == false ]] && printf yes || printf no); change login shell: $([[ $no_change_shell == false ]] && printf yes || printf no)"
        return
    fi
    if [[ $force == false ]]; then
        local reply
        read -r -p "Install Fish configuration into $config_dir? [y/N] " reply || return 1
        [[ ${reply,,} == y || ${reply,,} == yes ]] || return 0
    fi

    ensure_dependencies
    fish --no-config -c 'test (string split -- . "$version")[1] -ge 4' \
        || die 'Fish 4+ is required. Upgrade Fish before installing this configuration.'
    fish --no-config --no-execute "$SCRIPT_DIR/config.fish"
    fish --no-config --no-execute "$SCRIPT_DIR/aliases.fish"
    fish --no-config --no-execute "$SCRIPT_DIR/conf.d/00-cachyos.fish"

    if [[ -d $config_dir && $no_backup == false ]]; then
        backup_dir=$(mktemp -d "$config_dir.backup.XXXXXX")
        cp -a -- "$config_dir/." "$backup_dir/"
        log "Backup: $backup_dir"
    fi
    install -d -m 0700 "$config_dir" "$config_dir/conf.d"
    if [[ $skip_plugins == false ]]; then
        # The pinned SSH-agent plugin writes here as soon as Fisher sources it.
        install -d -m 0700 "$HOME/.ssh"
        install_plugins
    fi
    install -m 0600 "$SCRIPT_DIR/config.fish" "$config_dir/config.fish"
    install -m 0600 "$SCRIPT_DIR/aliases.fish" "$config_dir/aliases.fish"
    install -m 0600 "$SCRIPT_DIR/conf.d/00-cachyos.fish" "$config_dir/conf.d/00-cachyos.fish"
    # The old installer put this managed file in conf.d, causing double/early loading.
    rm -f -- "$config_dir/conf.d/aliases.fish"
    if [[ $no_change_shell == false ]]; then
        change_shell
    fi
    log 'Fish configuration installed. Open a new interactive Fish session.'
}

main "$@"
