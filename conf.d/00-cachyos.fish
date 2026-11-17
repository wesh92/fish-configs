# Distro defaults include their own Done plugin. Load them before Fisher's
# conf.d scripts so the explicitly pinned plugin wins, not the bundled copy.
if not status is-interactive
    return
end

# Optional on plain Arch and in minimal containers.
if test -r /usr/share/cachyos-fish-config/cachyos-config.fish
    source /usr/share/cachyos-fish-config/cachyos-config.fish
end
