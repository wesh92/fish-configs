#!/usr/bin/env bash
set -uo pipefail
IFS=$'\n\t'

# Global variables for logging and rollback
# shellcheck disable=SC2155
readonly SCRIPT_NAME=$(basename "$0")
# shellcheck disable=SC2155
readonly LOG_FILE="/tmp/${SCRIPT_NAME%.*}_$(date +%Y%m%d_%H%M%S).log"
# Declare associative array for rollback operations
declare -A ROLLBACK_STEPS

#######################
# Logging Functions #
#######################

log() {
    local level="$1"
    shift
    local message="$*"
    # shellcheck disable=SC2155
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[$timestamp] [$level] $message" | tee -a "$LOG_FILE"
}

init_logging() {
    touch "$LOG_FILE"
    chmod 600 "$LOG_FILE"
    log "INFO" "Started logging to $LOG_FILE"
    log "INFO" "Script version 1.0.0"
    log "INFO" "Running as user: $USER"
}

#######################
# Help and Documentation #
#######################

show_help() {
    cat << EOF
Usage: $SCRIPT_NAME [OPTIONS]

Installs and configures Fish shell with common plugins on Arch Linux or Ubuntu.

Options:
    -h, --help          Show this help message and exit
    --dry-run           Show what would be done without making changes
    --no-backup         Skip backup of existing configurations
    --force             Skip all confirmations and update existing installation
    --rollback          Rollback the last failed installation
    --install-missing   Install missing dependencies (e.g., yay on Arch)

Configuration:
    The script will look for config.fish and aliases.fish in the current directory.
    If not found, it will fetch them from https://github.com/wesh92/fish-configs.
    Existing configurations will be backed up before any changes.

Examples:
    $SCRIPT_NAME                        # Normal installation
    $SCRIPT_NAME --force               # Update existing installation
    $SCRIPT_NAME --install-missing     # Install with missing dependencies

The script will:
    1. Check if Fish is already installed
    2. Detect your operating system
    3. Install missing dependencies (if --install-missing is used)
    4. Backup existing shell configurations
    5. Install Fish shell (if needed)
    6. Install Fisher package manager
    7. Install commonly used Fish plugins
    8. Set up configuration files (local or from GitHub)
    9. Set Fish as your default shell (if needed)

Log file will be created at: $LOG_FILE
EOF
}

#######################
# Installation Check Functions #
#######################

check_fish_installation() {
    log "INFO" "Checking existing Fish installation"
    
    if command -v fish >/dev/null 2>&1; then
        if getent passwd "$USER" | grep -q "fish"; then
            log "INFO" "Fish is already installed and set as default shell"
            echo 0
            return 0
        else
            log "INFO" "Fish is installed but not set as default shell"
            echo 2
            return 0
        fi
    else
        log "INFO" "Fish is not installed"
        echo 1
        return 0
    fi
}

#######################
# Configuration Functions #
#######################

setup_fish_config() {
    local config_dir="$HOME/.config/fish"
    local local_config="./config.fish"
    local local_aliases="./aliases.fish"
    local github_repo="https://raw.githubusercontent.com/wesh92/fish-configs/main"
    
    log "INFO" "Setting up Fish configuration"
    
    mkdir -p "$config_dir/conf.d"
    
    backup_existing_config() {
        local file="$1"
        if [ -f "$file" ]; then
            # shellcheck disable=SC2155
            local backup="${file}.backup.$(date +%Y%m%d_%H%M%S)"
            log "INFO" "Backing up existing $file to $backup"
            mv "$file" "$backup"
            ROLLBACK_STEPS["config_backup_${file##*/}"]="mv $backup $file"
        fi
    }
    
    fetch_remote_file() {
        local filename="$1"
        local url="$github_repo/$filename"
        local output="$config_dir/$filename"
        
        log "INFO" "Fetching $filename from GitHub"
        if curl -sL "$url" -o "$output"; then
            ROLLBACK_STEPS["remote_${filename}"]="rm -f $output"
            return 0
        else
            log "ERROR" "Failed to fetch $filename from GitHub"
            return 1
        fi
    }
    
    if [ -f "$local_config" ]; then
        log "INFO" "Using local config.fish"
        backup_existing_config "$config_dir/config.fish"
        cp "$local_config" "$config_dir/config.fish" || return 1
        ROLLBACK_STEPS["local_config"]="rm -f $config_dir/config.fish"
    else
        log "INFO" "Local config.fish not found, fetching from GitHub"
        backup_existing_config "$config_dir/config.fish"
        fetch_remote_file "config.fish" || return 1
    fi
    
    if [ -f "$local_aliases" ]; then
        log "INFO" "Using local aliases.fish"
        cp "$local_aliases" "$config_dir/conf.d/aliases.fish" || return 1
        ROLLBACK_STEPS["local_aliases"]="rm -f $config_dir/conf.d/aliases.fish"
    else
        log "INFO" "Local aliases.fish not found, fetching from GitHub"
        fetch_remote_file "aliases.fish" || return 1
        mv "$config_dir/aliases.fish" "$config_dir/conf.d/aliases.fish" || return 1
        ROLLBACK_STEPS["remote_aliases"]="rm -f $config_dir/conf.d/aliases.fish"
    fi
    
    chmod 600 "$config_dir/config.fish" "$config_dir/conf.d/aliases.fish"
    
    log "INFO" "Fish configuration setup completed"
    return 0
}

#######################
# Backup Functions #
#######################

backup_config() {
    # shellcheck disable=SC2155
    local backup_dir="$HOME/.shell_backup_$(date +%Y%m%d_%H%M%S)"
    log "INFO" "Creating backup at $backup_dir"
    
    if mkdir -p "$backup_dir"; then
        ROLLBACK_STEPS["backup"]="rm -rf $backup_dir"
        
        for file in "$HOME/.bashrc" "$HOME/.config/fish/config.fish"; do
            if [ -f "$file" ]; then
                log "INFO" "Backing up $file"
                cp "$file" "$backup_dir/" || {
                    log "ERROR" "Failed to backup $file"
                    return 1
                }
            fi
        done
        log "INFO" "Backup completed successfully"
    else
        log "ERROR" "Failed to create backup directory"
        return 1
    fi
}

#######################
# Installation Functions #
#######################

install_fisher_and_plugins() {
    log "INFO" "Starting Fisher and plugin installation"
    
    mkdir -p "$HOME/.config/fish"
    
    log "INFO" "Installing Fisher"
    if fish -c 'curl -sL https://git.io/fisher | source && fisher install jorgebucaran/fisher'; then
        ROLLBACK_STEPS["fisher"]="fish -c 'fisher remove jorgebucaran/fisher'"
        
        local plugins=("jethrokuan/z" "jethrokuan/fzf" "jethrokuan/fzf.fish")
        for plugin in "${plugins[@]}"; do
            log "INFO" "Installing plugin: $plugin"
            if fish -c "fisher install $plugin"; then
                ROLLBACK_STEPS["plugin_${plugin##*/}"]="fish -c 'fisher remove $plugin'"
            else
                log "ERROR" "Failed to install plugin: $plugin"
                return 1
            fi
        done
    else
        log "ERROR" "Failed to install Fisher"
        return 1
    fi
}

install_yay() {
    log "INFO" "Installing yay package manager"
    
    if ! pacman -Qi base-devel &>/dev/null; then
        log "INFO" "Installing base-devel package group"
        sudo pacman -S --noconfirm --needed base-devel || {
            log "ERROR" "Failed to install base-devel"
            return 1
        }
    fi
    
    local temp_dir
    temp_dir=$(mktemp -d)
    ROLLBACK_STEPS["temp_dir"]="rm -rf $temp_dir"
    
    log "INFO" "Cloning yay repository"
    if git clone https://aur.archlinux.org/yay.git "$temp_dir"; then
        local original_dir=$PWD
        
        cd "$temp_dir" || {
            log "ERROR" "Failed to change to yay directory"
            return 1
        }
        
        log "INFO" "Building and installing yay"
        if makepkg -si --noconfirm; then
            ROLLBACK_STEPS["yay_install"]="sudo pacman -Rns --noconfirm yay"
            cd "$original_dir" || log "WARNING" "Failed to return to original directory"
            log "INFO" "Successfully installed yay"
            return 0
        else
            log "ERROR" "Failed to build and install yay"
            cd "$original_dir" || log "WARNING" "Failed to return to original directory"
            return 1
        fi
    else
        log "ERROR" "Failed to clone yay repository"
        return 1
    fi
}

setup_arch() {
    log "INFO" "Setting up Fish on Arch Linux"
    
    local install_missing="$1"
    
    if ! command -v yay &> /dev/null; then
        if [ "$install_missing" = true ]; then
            log "INFO" "yay not found, attempting to install it"
            if ! install_yay; then
                log "ERROR" "Failed to install yay"
                return 1
            fi
        else
            log "ERROR" "yay not found. Run with --install-missing to install it automatically"
            return 1
        fi
    fi
    
    if yay -S --noconfirm fish; then
        ROLLBACK_STEPS["fish_install"]="yay -Rns --noconfirm fish"
        log "INFO" "Successfully installed Fish on Arch"
    else
        log "ERROR" "Failed to install Fish on Arch"
        return 1
    fi
}

setup_ubuntu() {
    log "INFO" "Setting up Fish on Ubuntu"
    
    if sudo add-apt-repository -y ppa:fish-shell/beta-4; then
        ROLLBACK_STEPS["ppa"]="sudo add-apt-repository -y -r ppa:fish-shell/beta-4"
        
        log "INFO" "Updating package lists"
        sudo apt-get update
        
        log "INFO" "Installing Fish"
        if DEBIAN_FRONTEND=noninteractive sudo apt-get install -y fish; then
            ROLLBACK_STEPS["fish_install"]="sudo apt-get remove -y fish"
            log "INFO" "Successfully installed Fish on Ubuntu"
        else
            log "ERROR" "Failed to install Fish"
            return 1
        fi
    else
        log "ERROR" "Failed to add Fish repository"
        return 1
    fi
}

change_shell() {
    log "INFO" "Changing default shell to Fish"
    
    # shellcheck disable=SC2155
    local fish_path=$(which fish)
    if ! grep -q "$fish_path" /etc/shells; then
        log "INFO" "Adding Fish to /etc/shells"
        echo "$fish_path" | sudo tee -a /etc/shells
        ROLLBACK_STEPS["etc_shells"]="sudo sed -i '\%$fish_path%d' /etc/shells"
    fi
    
    # shellcheck disable=SC2155
    local original_shell=$(getent passwd "$USER" | cut -d: -f7)
    ROLLBACK_STEPS["default_shell"]="chsh -s $original_shell $USER"
    
    if chsh -s "$fish_path" "$USER"; then
        log "INFO" "Successfully changed default shell to Fish"
    else
        log "ERROR" "Failed to change default shell"
        return 1
    fi
}

#######################
# Rollback Function #
#######################

rollback() {
    log "WARNING" "Starting rollback procedure..."
    
    for step in "${!ROLLBACK_STEPS[@]}"; do
        log "INFO" "Rolling back: $step"
        if eval "${ROLLBACK_STEPS[$step]}"; then
            log "INFO" "Successfully rolled back: $step"
        else
            log "ERROR" "Failed to roll back: $step"
        fi
    done
}

#######################
# Main Function #
#######################

main() {
    local skip_backup=false
    local force=false
    local install_missing=false
    
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -h|--help)
                show_help
                exit 0
                ;;
            --no-backup)
                skip_backup=true
                ;;
            --force)
                force=true
                ;;
            --install-missing)
                install_missing=true
                ;;
            --rollback)
                rollback
                exit $?
                ;;
            *)
                log "ERROR" "Unknown option: $1"
                show_help
                exit 1
                ;;
        esac
        shift
    done
    
    init_logging
    
    if [ "$(id -u)" -eq 0 ]; then
        log "ERROR" "Please run this script as a normal user with sudo privileges, not as root"
        exit 1
    fi
    
    # Modify this section to explicitly handle the return value
    local fish_status
    fish_status=$(check_fish_installation || echo $?)
    log "INFO" "Fish installation status: $fish_status"

    # Proceed with OS detection and rest of installation
    if ! command -v lsb_release >/dev/null 2>&1 && [ ! -f /etc/os-release ]; then
        log "ERROR" "Unable to detect operating system"
        exit 1
    fi
    
    case $fish_status in
        0)  # Fish is installed and is default shell
            log "INFO" "Fish is already installed and configured"
            if [ "$force" = true ]; then
                log "INFO" "Force flag set, proceeding with configuration update"
            else
                log "INFO" "Nothing to do. Use --force to update configuration"
                exit 0
            fi
            ;;
        2)  # Fish is installed but not default shell
            log "INFO" "Fish is installed but not set as default shell"
            ;;
        1)  # Fish is not installed
            log "INFO" "Proceeding with Fish installation"
            ;;
    esac
    
    if command -v lsb_release >/dev/null 2>&1; then
        OS=$(lsb_release -si)
    elif [ -f /etc/os-release ]; then
        # shellcheck disable=SC1091
        OS=$(. /etc/os-release && echo "$ID")
    else
        OS="unknown"
    fi
    
    log "INFO" "Detected OS: $OS"
    
    if [ "$force" = false ]; then
        read -p "Ready to install Fish shell on $OS. Continue? [y/N] " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            log "INFO" "Installation cancelled by user"
            exit 0
        fi
    fi
    
    if [ "$skip_backup" = false ]; then
        backup_config || {
            log "ERROR" "Backup failed, aborting installation"
            rollback
            exit 1
        }
    fi
    
    case "${OS,,}" in
        "arch")
            setup_arch "$install_missing" || { rollback; exit 1; }
            ;;
        "ubuntu")
            setup_ubuntu || { rollback; exit 1; }
            ;;
        *)
            log "ERROR" "Unsupported OS: $OS"
            exit 1
            ;;
    esac
    
    if [ $fish_status -eq 1 ] || [ $fish_status -eq 2 ]; then
            install_fisher_and_plugins || {
                log "ERROR" "Failed to install Fisher and plugins"
                rollback
                exit 1
            }
        fi
        
        if ! setup_fish_config; then
            log "ERROR" "Failed to setup Fish configuration"
            rollback
            exit 1
        fi
        
        if [ $fish_status -eq 1 ] || [ $fish_status -eq 2 ]; then
            change_shell || { rollback; exit 1; }
        fi
        
        log "INFO" "Fish shell setup complete! Please log out and back in for changes to take effect."
        log "INFO" "Installation log available at: $LOG_FILE"
    }

# Trap errors and handle cleanup
trap 'log "ERROR" "An error occurred. Starting rollback..."; rollback; exit 1' ERR

# Execute main function with all arguments
main "$@"