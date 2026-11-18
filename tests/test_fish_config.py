"""Isolated Fish 4+ regression checks; run with python3 -m unittest discover -s tests -v."""

import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
import time
import unittest

if sys.platform != "linux":
    raise unittest.SkipTest("Run the Fish tests on Linux, or use tests/run_in_container.py")

import fcntl
import pty
import select
import struct
import termios


ROOT = Path(__file__).resolve().parents[1]
CONFIG_FILES = ("config.fish", "aliases.fish", "conf.d/00-cachyos.fish")
FISH = shutil.which("fish") or "fish"
BASH = shutil.which("bash") or "bash"


@unittest.skipUnless(shutil.which(FISH) and shutil.which(BASH), "Fish 4+ and Bash are required")
class FishConfigTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="fish-config-tests-")
        self.addCleanup(self.temp.cleanup)
        self.home = Path(self.temp.name) / "home with spaces"
        self.config_home = self.home / "xdg config"
        self.fish_dir = self.config_home / "fish"
        self.fish_dir.mkdir(parents=True)
        for filename in CONFIG_FILES:
            (self.fish_dir / filename).parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(ROOT / filename, self.fish_dir / filename)
        self.env = os.environ.copy()
        for name in ("EDITOR", "VISUAL", "GPG_TTY", "XDG_CONFIG_DIRS"):
            self.env.pop(name, None)
        self.env.update(
            HOME=str(self.home),
            XDG_CONFIG_HOME=str(self.config_home),
            XDG_DATA_HOME=str(self.home / "data"),
            XDG_CACHE_HOME=str(self.home / "cache"),
            TERM="xterm-256color",
            FISH_TEST_CONFIG=str(self.fish_dir / "config.fish"),
            FISH_TEST_EARLY_CONFIG=str(self.fish_dir / "conf.d" / "00-cachyos.fish"),
        )

    def fish(self, command, *, interactive=False, no_config=False, stdin=None, env=None):
        args = [FISH]
        if no_config:
            args.append("--no-config")
        args.extend(["-ic" if interactive else "-c", command])
        return subprocess.run(
            args,
            env=self.env if env is None else env,
            stdin=stdin if stdin is not None else subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            timeout=15,
        )

    def assert_ready(self, result):
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(result.stderr, "")
        self.assertEqual(result.stdout, "ready\n")

    def installer(self, *args, script_dir=ROOT):
        return subprocess.run(
            [BASH, str(script_dir / "setup_fish.sh"), *args],
            cwd=self.home,
            env=self.env,
            stdin=subprocess.DEVNULL,
            capture_output=True,
            text=True,
            timeout=20,
        )

    def test_syntax(self):
        for filename in CONFIG_FILES:
            result = subprocess.run(
                [FISH, "--no-config", "--no-execute", str(ROOT / filename)],
                capture_output=True,
                text=True,
                timeout=10,
            )
            self.assertEqual(result.returncode, 0, result.stderr)
        result = subprocess.run(
            [BASH, "-n", str(ROOT / "setup_fish.sh")],
            capture_output=True,
            text=True,
            timeout=10,
        )
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_noninteractive_startup_has_no_ui_side_effects(self):
        self.assert_ready(self.fish('not set -q GPG_TTY; and not functions -q ..; and echo ready'))

    def test_interactive_startup_without_plugins(self):
        self.assert_ready(
            self.fish("abbr --query git_add git_cp uv_in uv_ve; and echo ready", interactive=True)
        )

    def test_missing_aliases_is_optional(self):
        (self.fish_dir / "aliases.fish").unlink()
        self.assert_ready(self.fish("echo ready", interactive=True))

    def test_distro_defaults_load_before_pinned_done(self):
        distro = self.home / "distro defaults.fish"
        distro.write_text("set -g FISH_TEST_DISTRO_LOADED 1\nset -g __done_version bundled\n")
        for filename in self.fish_dir.rglob("*.fish"):
            filename.write_text(filename.read_text().replace(
                "/usr/share/cachyos-fish-config/cachyos-config.fish", f'"{distro}"'
            ))
        conf = self.fish_dir / "conf.d"
        conf.mkdir(exist_ok=True)
        (conf / "done.fish").write_text("set -g __done_version pinned\n")
        self.assert_ready(self.fish(
            'test "$FISH_TEST_DISTRO_LOADED" = 1; '
            'and test "$__done_version" = pinned; and echo ready',
            interactive=True,
        ))

    def test_editor_uses_an_available_exported_command(self):
        expected = next((name for name in ("zeditor", "nvim", "vim", "vi") if shutil.which(name)), None)
        if expected:
            self.assert_ready(
                self.fish(
                    f'test "$EDITOR" = {expected}; and set -q -x EDITOR; and echo ready',
                    interactive=True,
                )
            )
        else:
            self.assert_ready(self.fish("not set -q EDITOR; and echo ready", interactive=True))

    def test_existing_editor_and_gpg_tty_are_preserved_without_a_tty(self):
        self.env.update(EDITOR="custom-editor --wait", GPG_TTY="/dev/existing-tty")
        self.assert_ready(
            self.fish(
                'test "$EDITOR" = "custom-editor --wait"; and test "$GPG_TTY" = /dev/existing-tty; and echo ready',
                interactive=True,
            )
        )

    def test_gpg_tty_is_set_from_a_real_terminal(self):
        master, slave = pty.openpty()
        try:
            result = self.fish('printf "%s\\n" "$GPG_TTY"', interactive=True, stdin=slave)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(result.stderr, "")
            self.assertEqual(result.stdout, os.ttyname(slave) + "\n")
        finally:
            os.close(master)
            os.close(slave)

    def test_standard_utilities_are_not_replaced_by_functions(self):
        self.assert_ready(
            self.fish("not functions -q cat; and not functions -q find; and echo ready", interactive=True)
        )

    def test_missing_distro_defaults_and_optional_commands(self):
        empty_bin = self.home / "empty bin"
        empty_bin.mkdir()
        env = dict(self.env, PATH=str(empty_bin))
        # Simulate a plain Arch host even when the test host has CachyOS defaults.
        early_config = self.fish_dir / "conf.d" / "00-cachyos.fish"
        config = early_config.read_text()
        config = config.replace(
            "/usr/share/cachyos-fish-config/cachyos-config.fish",
            str(Path(self.temp.name) / "absent-distro-config.fish"),
        )
        early_config.write_text(config)
        command = 'source "$FISH_TEST_EARLY_CONFIG"; source "$FISH_TEST_CONFIG"; not set -q EDITOR; and not functions -q cat; and not functions -q find; and echo ready'
        self.assert_ready(self.fish(command, interactive=True, no_config=True, env=env))

    def test_fzf_integration_is_configured_when_plugin_is_present(self):
        functions = self.fish_dir / "functions"
        functions.mkdir()
        (functions / "fzf_configure_bindings.fish").write_text(
            "function fzf_configure_bindings\n    set -g FISH_TEST_FZF_ARGS $argv\nend\n"
        )
        self.assert_ready(
            self.fish(
                'test "$FISH_TEST_FZF_ARGS[1]" = --directory=ctrl-f; and set -q fzf_directory_opts; and echo ready',
                interactive=True,
            )
        )

    def test_abbreviations_expand_in_command_context(self):
        master, slave = pty.openpty()
        fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", 24, 240, 0, 0))
        init = r"""
function fish_prompt; printf '__FISH_PROMPT__'; end
function fish_right_prompt; end
function fish_greeting; end
bind ctrl-x 'printf "\n__FISH_BUFFER__%s\n" (commandline); commandline --replace ""; commandline --function repaint'
"""

        def connect_terminal():
            os.setsid()
            fcntl.ioctl(0, termios.TIOCSCTTY, 0)

        process = subprocess.Popen(
            [FISH, "--interactive", "--init-command", init],
            stdin=slave,
            stdout=slave,
            stderr=slave,
            env=self.env,
            preexec_fn=connect_terminal,
        )
        os.close(slave)
        pending = b""

        def read_until(pattern):
            nonlocal pending
            deadline = time.monotonic() + 10
            while time.monotonic() < deadline:
                match = re.search(pattern, pending)
                if match:
                    pending = pending[match.end():]
                    return match
                if select.select([master], [], [], 0.2)[0]:
                    try:
                        chunk = os.read(master, 65536)
                        pending += chunk
                        # Fish 4 negotiates terminal features before showing its first prompt.
                        if b"\x1b[0c" in chunk:
                            os.write(master, b"\x1b[?1;2c")
                        if b"\x1b[6n" in chunk:
                            os.write(master, b"\x1b[1;1R")
                    except OSError:
                        break
                if process.poll() is not None:
                    break
            self.fail(f"Fish reader did not produce {pattern!r}: {pending!r}")

        try:
            read_until(rb"__FISH_PROMPT__")
            for typed, expanded in (
                ("g co", "git checkout "),
                ("git add", "git add . "),
                ("git cp", "git cherry-pick "),
                ("uv in", "uv init "),
                ("u pi", "uv python install "),
                ("cp", "cp -v "),
                ("echo co", "echo co "),
                ("echo in", "echo in "),
            ):
                with self.subTest(typed=typed):
                    os.write(master, typed.encode() + b" \x18")
                    match = read_until(rb"\r?\n__FISH_BUFFER__([^\r\n]*)\r?\n")
                    self.assertEqual(match.group(1).decode(), expanded)
            os.write(master, b"exit\n")
            process.wait(timeout=5)
        finally:
            if process.poll() is None:
                process.terminate()
                try:
                    process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait(timeout=5)
            os.close(master)

    def test_installer_dry_run_does_not_write(self):
        shutil.rmtree(self.config_home)
        result = self.installer("--dry-run", "--skip-plugins", "--no-change-shell")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertFalse(self.config_home.exists())

    def test_installer_uses_script_directory_and_migrates_legacy_aliases(self):
        (self.fish_dir / "config.fish").write_text("# existing config\n")
        (self.fish_dir / "conf.d" / "00-cachyos.fish").unlink()
        legacy = self.fish_dir / "conf.d" / "aliases.fish"
        legacy.parent.mkdir(exist_ok=True)
        legacy.write_text("# old installer aliases\n")
        result = self.installer("--force", "--skip-plugins", "--no-change-shell")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual((self.fish_dir / "config.fish").read_bytes(), (ROOT / "config.fish").read_bytes())
        self.assertEqual((self.fish_dir / "aliases.fish").read_bytes(), (ROOT / "aliases.fish").read_bytes())
        self.assertEqual(
            (self.fish_dir / "conf.d" / "00-cachyos.fish").read_bytes(),
            (ROOT / "conf.d" / "00-cachyos.fish").read_bytes(),
        )
        self.assertFalse(legacy.exists())
        backups = list(self.config_home.glob("fish.backup.*"))
        self.assertEqual(len(backups), 1)
        self.assertEqual((backups[0] / "config.fish").read_text(), "# existing config\n")
        self.assertEqual((backups[0] / "conf.d" / "aliases.fish").read_text(), "# old installer aliases\n")
        self.assert_ready(self.fish("abbr --query uv_ve; and echo ready", interactive=True))

    def test_installer_no_backup_is_honored(self):
        result = self.installer("--force", "--skip-plugins", "--no-change-shell", "--no-backup")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(list(self.config_home.glob("fish.backup.*")), [])

    def prepare_fisher_stub(self, *, fail=False):
        functions = self.fish_dir / "functions"
        functions.mkdir()
        body = "return 42" if fail else (
            'printf "%s\\n" $argv[2..] > "$FISH_TEST_PLUGIN_LOG"\n'
            '    command cp "$FISH_TEST_PLUGIN_LOG" "$__fish_config_dir/fish_plugins"'
        )
        (functions / "fisher.fish").write_text(f"function fisher\n    {body}\nend\n")
        self.env["FISH_TEST_PLUGIN_LOG"] = str(self.home / "plugin arguments")
        fake_bin = self.home / "fake bin"
        fake_bin.mkdir()
        # A broken autoload-path check must fail locally, never call the network.
        curl = fake_bin / "curl"
        curl.write_text("#!/bin/sh\nexit 99\n")
        curl.chmod(0o755)
        self.env["PATH"] = str(fake_bin) + os.pathsep + self.env["PATH"]

    def test_installer_loads_fisher_without_running_existing_config(self):
        self.prepare_fisher_stub()
        (self.fish_dir / "config.fish").write_text("echo OLD_CONFIG_WAS_EXECUTED >&2\n")
        result = self.installer("--force", "--no-change-shell")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertNotIn("OLD_CONFIG_WAS_EXECUTED", result.stdout + result.stderr)
        self.assertEqual(
            Path(self.env["FISH_TEST_PLUGIN_LOG"]).read_text().splitlines(),
            (ROOT / "fish_plugins").read_text().splitlines(),
        )
        self.assertEqual((self.home / ".ssh").stat().st_mode & 0o777, 0o700)

    def test_installer_bootstraps_fisher_without_loading_startup_files(self):
        functions = self.fish_dir / "functions"
        functions.mkdir()
        # A first-match empty autoload file hides the vendor manager in this fixture.
        (functions / "fisher.fish").write_text("# Fisher is not installed in this fixture\n")
        bootstrap = self.home / "bootstrap.fish"
        bootstrap.write_text(
            "function fisher\n"
            "    if string match --quiet 'jorgebucaran/fisher@*' -- \"$argv[2]\"\n"
            "        functions fisher > \"$fisher_path/functions/fisher.fish\"\n"
            "    else\n"
            "        printf '%s\\n' $argv[2..] > \"$FISH_TEST_PLUGIN_LOG\"\n"
            "        command cp \"$FISH_TEST_PLUGIN_LOG\" \"$__fish_config_dir/fish_plugins\"\n"
            "    end\nend\n"
        )
        self.env.update(
            FISH_TEST_BOOTSTRAP=str(bootstrap),
            FISH_TEST_PLUGIN_LOG=str(self.home / "plugin arguments"),
            FISH_TEST_CURL_ARGS=str(self.home / "curl arguments"),
        )
        fake_bin = self.home / "fake bin"
        fake_bin.mkdir()
        curl = fake_bin / "curl"
        curl.write_text(
            '#!/bin/sh\nprintf "%s\\n" "$@" > "$FISH_TEST_CURL_ARGS"\n'
            'for output; do :; done\ncp "$FISH_TEST_BOOTSTRAP" "$output"\n'
        )
        curl.chmod(0o755)
        self.env["PATH"] = str(fake_bin) + os.pathsep + self.env["PATH"]
        result = self.installer("--force", "--no-change-shell")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn(
            "a04308be92daa6cfecdbb0ca58b1e8508664cff2/functions/fisher.fish",
            Path(self.env["FISH_TEST_CURL_ARGS"]).read_text(),
        )
        self.assertEqual(
            Path(self.env["FISH_TEST_PLUGIN_LOG"]).read_text().splitlines(),
            (ROOT / "fish_plugins").read_text().splitlines(),
        )

    def test_installer_propagates_plugin_failure_and_retains_original_config(self):
        self.prepare_fisher_stub(fail=True)
        (self.fish_dir / "config.fish").write_text("# original config\n")
        result = self.installer("--force", "--no-change-shell")
        self.assertEqual(result.returncode, 42, result.stdout + result.stderr)
        self.assertEqual((self.fish_dir / "config.fish").read_text(), "# original config\n")
        self.assertIn("Original configuration is retained at:", result.stderr)
        self.assertEqual(len(list(self.config_home.glob("fish.backup.*"))), 1)

    def prepare_real_fisher_fixture(self, *, conflict=False):
        result = self.fish(
            'set -g fish_function_path "$__fish_data_dir/vendor_functions.d" "$__fish_data_dir/functions"; '
            'functions --query fisher; or exit 77; functions --details fisher',
            no_config=True,
        )
        if result.returncode:
            self.skipTest("Optional real-Fisher regressions require vendor Fisher")
        functions = self.fish_dir / "functions"
        functions.mkdir()
        shutil.copyfile(Path(result.stdout.strip()), functions / "fisher.fish")
        fixture = self.home / "installer checkout"
        fixture.mkdir()
        for filename in ("setup_fish.sh", *CONFIG_FILES):
            (fixture / filename).parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(ROOT / filename, fixture / filename)
        plugins = []
        for name in (("good", "conflict") if conflict else ("good",)):
            plugin = Path(self.temp.name) / f"local-plugin-{name}"
            (plugin / "functions").mkdir(parents=True)
            (plugin / "functions" / f"fixture_{name}.fish").write_text(f"function fixture_{name}; end\n")
            plugins.append(str(plugin))
        if conflict:
            (functions / "fixture_conflict.fish").write_text("# User-owned conflicting file\n")
        (fixture / "fish_plugins").write_text("\n".join(plugins) + "\n")
        return fixture, plugins

    def test_real_fisher_persists_registry_and_can_reinstall(self):
        fixture, plugins = self.prepare_real_fisher_fixture()
        self.env["FISH_TEST_EXISTING_PLUGIN"] = plugins[0]
        for _ in range(2):
            result = self.installer("--force", "--no-change-shell", script_dir=fixture)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assert_ready(self.fish(
                'contains -- "$FISH_TEST_EXISTING_PLUGIN" $_fisher_plugins; '
                'and functions -q fixture_good; and echo ready'
            ))

    def test_real_fisher_preserves_preinstalled_and_unrelated_plugins(self):
        fixture, plugins = self.prepare_real_fisher_fixture()
        unrelated = Path(self.temp.name) / "local-plugin-unrelated"
        (unrelated / "functions").mkdir(parents=True)
        (unrelated / "functions/fixture_unrelated.fish").write_text("function fixture_unrelated; end\n")
        self.env.update(FISH_TEST_EXISTING_PLUGIN=plugins[0], FISH_TEST_UNRELATED_PLUGIN=str(unrelated))
        seeded = self.fish('fisher install "$FISH_TEST_EXISTING_PLUGIN" "$FISH_TEST_UNRELATED_PLUGIN"')
        self.assertEqual(seeded.returncode, 0, seeded.stdout + seeded.stderr)
        result = self.installer("--force", "--no-change-shell", script_dir=fixture)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assert_ready(self.fish(
            'contains -- "$FISH_TEST_EXISTING_PLUGIN" $_fisher_plugins; '
            'and contains -- "$FISH_TEST_UNRELATED_PLUGIN" $_fisher_plugins; '
            'and functions -q fixture_good fixture_unrelated; and echo ready'
        ))
        installed = set((self.fish_dir / "fish_plugins").read_text().splitlines())
        self.assertEqual(installed, {plugins[0], str(unrelated)})

    def test_real_fisher_workers_do_not_run_existing_startup(self):
        fixture, _ = self.prepare_real_fisher_fixture()
        marker = self.home / "startup marker"
        self.env["FISH_TEST_STARTUP_MARKER"] = str(marker)
        (self.fish_dir / "config.fish").write_text('printf config >> "$FISH_TEST_STARTUP_MARKER"\n')
        conf = self.fish_dir / "conf.d"
        conf.mkdir(exist_ok=True)
        (conf / "custom.fish").write_text('printf confd >> "$FISH_TEST_STARTUP_MARKER"\n')
        result = self.installer("--force", "--no-change-shell", script_dir=fixture)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertFalse(marker.exists(), "Fisher download worker executed the old startup files")

    def test_real_fisher_partial_plugin_install_is_rejected(self):
        fixture, plugins = self.prepare_real_fisher_fixture(conflict=True)
        (self.fish_dir / "config.fish").write_text("# original config\n")
        result = self.installer("--force", "--no-change-shell", script_dir=fixture)
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("requested plugin was not installed", result.stderr)
        self.assertEqual((self.fish_dir / "config.fish").read_text(), "# original config\n")
        actual = (self.fish_dir / "fish_plugins").read_text().splitlines()
        self.assertIn(plugins[0], actual)
        self.assertNotIn(plugins[1], actual)

    def test_plugin_manifest_is_pinned_without_a_bundled_package_manager(self):
        plugins = [line for line in (ROOT / "fish_plugins").read_text().splitlines() if line and not line.startswith("#")]
        self.assertGreater(len(plugins), 0)
        self.assertFalse(any(plugin.startswith("jorgebucaran/fisher") for plugin in plugins))
        for plugin in plugins:
            self.assertRegex(plugin, r"^[\w-]+/[\w.-]+@(?:[0-9a-f]{40}|v\d+\.\d+\.\d+)$")
        self.assertTrue(any(plugin.startswith("patrickf1/fzf.fish@") for plugin in plugins))
        self.assertTrue(any(plugin.startswith("ilancosman/tide@") for plugin in plugins))


if __name__ == "__main__":
    unittest.main()
