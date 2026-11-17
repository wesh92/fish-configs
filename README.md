# fish-configs

Personal **Fish 4+** configuration for Arch/CachyOS and development containers.
The command-scoped abbreviations use Fish 4's `abbr --command` support.

## Configuration

Install all three managed files under `${XDG_CONFIG_HOME:-$HOME/.config}/fish/`:
`config.fish`, `aliases.fish`, and `conf.d/00-cachyos.fish`. Prefer the installer
below so the early startup file is not omitted. Do not also put `aliases.fish`
in `conf.d`: aliases belong beside `config.fish`, after plugin initialization.

- Prompt styling, abbreviations, and key bindings load only in interactive Fish.
  Non-interactive `fish -c` commands do not run this interactive setup.
- CachyOS defaults are sourced only when their file is readable. Plain Arch does
  not need `cachyos-fish-config` just to load these files. The early
  `00-cachyos.fish` file loads those defaults before Fisher's scripts, so the
  pinned Done plugin replaces the older bundled copy, not the other way round.
- Existing `EDITOR` values are preserved. Otherwise the first installed command
  from `zeditor`, `nvim`, `vim`, and `vi` is exported as `EDITOR`. No editor is
  assumed when none is installed. The dev image uses its installed Neovim.
- `GPG_TTY` is updated only for an interactive session with a real stdin TTY.
- `cat` is a typed abbreviation for `bat` (or `batcat`) when installed, not a
  function that changes other functions' calls to `cat`. Standard `find` is left
  intact; `ff` abbreviates `fd` (or `fdfind`).
- `g co`, `git add`, `git cp`, and `u pi` expand in Git/UV context without `eval`.
  Command-position `cp` still expands to `cp -v`.
- PatrickF1's optional fzf plugin gets Ctrl-F for file search. Ctrl-O in that
  search opens the selection using `EDITOR`; existing `fzf_directory_opts` are
  preserved. No fzf plugin is required for normal shell startup.
- `fish_plugins` pins the same plugin revisions as the reviewed Arch personal
  image, including Tide v6.2.1. Pure-only settings have been removed. Fisher is
  a package manager, not a plugin in this manifest: the image supplies it via
  pacman.

## Installer

Run the script from a complete checkout; it uses its own directory, not your
current directory, and never silently downloads different configs from `main`.
Run it as the user whose configuration you want to install, not via `sudo`.

```bash
# Preview only: no files, packages, network requests, or shell changes.
bash setup_fish.sh --dry-run --no-change-shell

# Container with Fish/Fisher and the CLI dependencies already installed.
bash setup_fish.sh --force --no-change-shell

# Config-only/offline setup; all plugins remain optional.
bash setup_fish.sh --force --skip-plugins --no-change-shell

# Standalone Arch/CachyOS setup, opting in to package installation if needed.
bash setup_fish.sh --install-missing
```

Without `--skip-plugins`, dependencies are `fish`, `curl`, `tar`, `fzf`, `fd`
(or Ubuntu's `fdfind`), `bat` (or `batcat`), and `ssh-agent`. The Arch Containerfile
already supplies these. Missing dependencies cause an error unless
`--install-missing` is given. Arch uses official pacman packages, not yay or AUR.
Ubuntu uses its configured apt repositories; if they provide Fish older than 4,
upgrade Fish first. The script does not add the obsolete beta PPA.

The installer reuses installed Fisher, or bootstraps the pinned Fisher 4.4.8
revision if none is available, then installs the pinned manifest. It preserves
unrelated installed plugins instead of removing them.
Installation runs with startup files disabled and explicitly restores the
function-autoload paths: Fish 4.9's bare `--no-config` otherwise cannot find
even the system-installed Fisher.
Fisher's child download workers receive an empty temporary XDG config directory
so they cannot execute the old user's startup files either. Every requested pin
is checked against Fisher's resulting manifest before the new configs are
copied: Fisher can otherwise report success after a partial installation.

Existing Fish configuration (including plugin files) is copied to a sibling
`fish.backup.XXXXXX` directory before changes. The old installer's
`conf.d/aliases.fish` is backed up and removed so aliases load once, beside
`config.fish`. `--no-backup` explicitly disables that snapshot. To restore, move
the changed `fish` directory aside and copy the retained backup back to `fish`.
The old `--rollback` option is rejected: its in-memory, unordered rollback list
could not restore a previous run. Package installation and login-shell changes
are not automatically rolled back.

Use `--no-change-shell` in automation/containers. Without it, the script changes
the current user's login shell only if it differs; `chsh` may require user
interaction. Dependency installation may require sudo even with `--force`.

## Arch image integration

The personal stage already installs `cachyos-fish-config` and the plugin
dependencies. No extra desktop editor or AUR package is necessary for this
configuration. Replace **both** the old personal-stage plugin-manifest/Fisher
RUN block and its two-file config-copy RUN block with this single block (keep
the base-stage nvm installation):

```dockerfile
RUN git clone --quiet https://github.com/wesh92/fish-configs /tmp/fish-configs \
 && git -C /tmp/fish-configs checkout --quiet --detach "${FISH_CONFIG_REF}" \
 && grep -Fxq "jorgebucaran/nvm.fish@${NVM_FISH_REF}" /tmp/fish-configs/fish_plugins \
 && bash /tmp/fish-configs/setup_fish.sh --force --no-backup --no-change-shell \
 && rm -rf /tmp/fish-configs
```

Run this as the existing `dev` user. It installs the pinned manifest from the
same config checkout, creates the private SSH state directory, verifies every
requested plugin after Fisher finishes, and copies all three managed startup
files. `--no-backup` avoids retaining an unused base-config snapshot in the
image; `--no-change-shell` prevents account changes or prompts. The explicit
nvm check fails if `NVM_FISH_REF` drifts from the manifest. If intentionally
changing that pin, update both sources together.

The pinned SSH-agent plugin writes `$HOME/.ssh/environment` immediately when
Fisher sources it. The installer creates `$HOME/.ssh` with mode 0700 first. In
an image build that still installs plugins directly, also create that directory
as `dev` **before** the personal-stage `fisher update`:

```dockerfile
RUN install -d -m 0700 "$HOME/.ssh"
```

The original image build log contains missing-directory warnings without this
prerequisite, even though Fisher reports success. The currently running dev
user already has the directory; that alone does not validate a clean rebuild.
Bare `fisher update` can also exit successfully after a partial installation;
creating the SSH directory alone does not verify the manifest. Prefer the
installer block above over maintaining another partial-install check in the
Containerfile.

The Containerfile pins `FISH_CONFIG_REF` to a commit; a rebuild does **not** fetch
the tip of this branch automatically. After publishing the reviewed commit to
GitHub, update that pin or pass `--build-arg FISH_CONFIG_REF=<published-commit>`
when building the personal target. The installer recipe deliberately uses this
checkout's `fish_plugins` rather than a second hard-coded personal-stage list.

## Verification

On Linux with Fish 4+, Bash, and Python 3:

```bash
python3 -m unittest discover -s tests -v

# Optional full-plugin smoke check against the user's installed plugins.
python3 tests/smoke_plugins.py

# Optional network check: install the pinned plugins into a temporary home.
python3 tests/smoke_plugins.py --install
```

From Windows (or Linux) with the running Podman dev container:

```bash
python3 tests/run_in_container.py --container wes-dev

# Also exercise installed plugins and a real fresh plugin installation.
python3 tests/run_in_container.py --container wes-dev --plugins --install-plugins
```

The runner transfers an LF-normalized checkout matching Linux Git line endings,
then runs checks in an isolated temporary directory. It prints the retained
container-side checkout path for inspection; it does not change `/home/dev` or
the mounted workspace. The suite covers parsing, distro-before-plugin startup
ordering, startup with/without optional files and tools, XDG paths containing
spaces, editor/TTY behavior, real reader
abbreviation expansion, and installer backup/migration/dry-run behavior.
When vendor Fisher is available, two additional offline checks use the real
manager with local fixture plugins to catch worker startup leakage and partial
installation success; no external fetch is needed for those regressions.
The full-plugin smoke also verifies the effective Done version, helper and
event-handler source paths, not just the installed plugin-manifest entries.
