"""Check the real pinned plugins in an isolated home, optionally installing them."""

import argparse
from contextlib import ExitStack
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile


ROOT = Path(__file__).resolve().parents[1]


def stop_test_agent(home):
    """Stop only the agent whose state was written inside this fresh test home."""
    state = home / ".ssh" / "environment"
    if not state.is_file():
        return
    content = state.read_text()
    pid = re.search(r"^setenv SSH_AGENT_PID ([0-9]+);", content, re.MULTILINE)
    socket = re.search(r"^setenv SSH_AUTH_SOCK ([^;\n]+);", content, re.MULTILINE)
    if pid and socket:
        env = dict(os.environ, SSH_AGENT_PID=pid.group(1), SSH_AUTH_SOCK=socket.group(1))
        subprocess.run(["ssh-agent", "-k"], env=env, capture_output=True, check=True, timeout=10)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--install", action="store_true", help="Install the pinned manifest (uses the network)")
    args = parser.parse_args()
    installed_dir = Path(os.environ.get("XDG_CONFIG_HOME", str(Path.home() / ".config"))) / "fish"
    with tempfile.TemporaryDirectory(prefix="fish-plugin-smoke-") as temp, ExitStack() as cleanup:
        home = Path(temp) / "home with spaces"
        config_home = home / "xdg config"
        fish_dir = config_home / "fish"
        fish_dir.mkdir(parents=True)
        env = os.environ.copy()
        for name in ("EDITOR", "VISUAL", "GPG_TTY", "XDG_CONFIG_DIRS", "SSH_AGENT_PID", "SSH_AUTH_SOCK", "SSH_ENV"):
            env.pop(name, None)
        env.update(
            HOME=str(home),
            XDG_CONFIG_HOME=str(config_home),
            XDG_DATA_HOME=str(home / "data"),
            XDG_CACHE_HOME=str(home / "cache"),
            TERM="xterm-256color",
            __done_allow_nongraphical="1",
            __done_notification_command="true",
        )
        cleanup.callback(stop_test_agent, home)
        if args.install:
            subprocess.run(
                ["bash", str(ROOT / "setup_fish.sh"), "--force", "--no-change-shell"],
                env=env,
                check=True,
                timeout=240,
            )
        else:
            # Mirror the running dev user's prerequisite; the installer creates it.
            (home / ".ssh").mkdir(mode=0o700)
            for dirname in ("functions", "completions", "conf.d"):
                source = installed_dir / dirname
                if not source.is_dir():
                    raise RuntimeError(f"Missing installed plugins: {source}. Use --install instead.")
                shutil.copytree(source, fish_dir / dirname)
            shutil.copyfile(installed_dir / "fish_plugins", fish_dir / "fish_plugins")
            for filename in ("config.fish", "aliases.fish", "conf.d/00-cachyos.fish"):
                shutil.copyfile(ROOT / filename, fish_dir / filename)
        desired = set((ROOT / "fish_plugins").read_text().splitlines())
        actual = set((fish_dir / "fish_plugins").read_text().splitlines())
        missing = desired - actual
        if missing:
            raise RuntimeError(f"Plugin pins missing from installation: {sorted(missing)}")
        done_source = fish_dir / "conf.d" / "done.fish"
        done_version = re.search(r"^set -g __done_version (\S+)$", done_source.read_text(), re.MULTILINE)
        if not done_version:
            raise RuntimeError(f"Cannot identify pinned Done version: {done_source}")
        env["FISH_EXPECT_DONE_VERSION"] = done_version.group(1)
        env["FISH_EXPECT_DONE_SOURCE"] = str(done_source)
        done_check = (
            'test "$__done_version" = "$FISH_EXPECT_DONE_VERSION"; '
            'and test (functions --details __done_humanize_duration) = "$FISH_EXPECT_DONE_SOURCE"; '
            'or begin; printf "Done pin overridden: %s from %s\\n" "$__done_version" '
            '(functions --details __done_humanize_duration) >&2; exit 1; end; '
            'for handler in __done_started __done_ended; '
            'test (functions --details $handler) = "$FISH_EXPECT_DONE_SOURCE"; or exit 1; end; '
        )
        checks = (
            ("non-interactive", ["-c"], 'not set -q GPG_TTY; and echo ready'),
            (
                "interactive",
                ["-ic"],
                done_check + 'functions -q fzf_configure_bindings nvm _tide_item_git; '
                'and abbr --query git_add git_cp uv_in uv_ve; '
                'and command -sq "$EDITOR"; '
                'and bind ctrl-f | string match --quiet "*_fzf_search_directory*"; '
                'and not set -q GPG_TTY; and echo ready',
            ),
            (
                "login interactive",
                ["-lic"],
                done_check + 'abbr --query uv_ve; and command -sq "$EDITOR"; and echo ready',
            ),
        )
        for label, flags, command in checks:
            result = subprocess.run(
                ["fish", *flags, command],
                env=env,
                stdin=subprocess.DEVNULL,
                capture_output=True,
                text=True,
                timeout=20,
            )
            if result.returncode or result.stdout != "ready\n" or result.stderr:
                raise RuntimeError(f"{label} failed ({result.returncode}): {result.stdout!r} {result.stderr!r}")
            print(f"PASS: {label} startup with {len(desired)} pinned plugins")
    print("PASS: no persistent user configuration or login shell was changed; test SSH agent stopped")


if __name__ == "__main__":
    main()
