"""Run the Fish checks from Windows or Linux without touching the container's home."""

import argparse
import io
import os
from pathlib import Path
import re
import subprocess
import tempfile
import tarfile


ROOT = Path(__file__).resolve().parents[1]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--container", default="wes-dev")
    parser.add_argument("--plugins", action="store_true", help="Smoke-test the container's installed plugins")
    parser.add_argument("--install-plugins", action="store_true", help="Install pinned plugins in a temporary home (network)")
    args = parser.parse_args()
    target = subprocess.check_output(
        ["podman", "exec", args.container, "mktemp", "-d", "/tmp/fish-config-review.XXXXXX"],
        text=True,
    ).strip()
    if not re.fullmatch(r"/tmp/fish-config-review\.[A-Za-z0-9]+", target):
        raise RuntimeError(f"Unexpected temporary directory: {target!r}")
    print(f"Test checkout retained for inspection: {args.container}:{target}", flush=True)
    names = subprocess.check_output(
        ["git", "ls-files", "--cached", "--others", "--exclude-standard", "-z"],
        cwd=ROOT,
    ).decode().split("\0")
    # Match Linux Git checkouts even when this working tree uses Windows line endings.
    with tempfile.TemporaryDirectory(prefix="fish-test-archive-", dir=os.environ.get("TMPDIR")) as temp:
        archive_path = Path(temp) / "source.tar"
        with tarfile.open(archive_path, "w") as archive:
            for name in sorted(set(names)):
                source = ROOT / name
                if not name or not source.is_file() or "__pycache__" in source.parts:
                    continue
                data = source.read_bytes()
                if source.suffix in {".fish", ".sh", ".py", ".md"} or source.name in {"fish_plugins", ".gitattributes", ".gitignore"}:
                    data = data.replace(b"\r\n", b"\n")
                info = tarfile.TarInfo(name)
                info.size = len(data)
                info.mode = 0o644
                archive.addfile(info, io.BytesIO(data))
        subprocess.run(
            ["podman", "cp", str(archive_path), f"{args.container}:{target}/source.tar"], check=True
        )
    prefix = ["podman", "exec", "--workdir", target, args.container]
    subprocess.run([*prefix, "tar", "-xf", "source.tar"], check=True)
    subprocess.run([*prefix, "fish", "--version"], check=True)
    result = subprocess.run(
        [*prefix, "env", "PYTHONDONTWRITEBYTECODE=1", "python", "-m", "unittest", "discover", "-s", "tests", "-v"]
    )
    if result.returncode:
        return result.returncode
    for enabled, options in ((args.plugins, []), (args.install_plugins, ["--install"])):
        if enabled:
            result = subprocess.run([*prefix, "python", "tests/smoke_plugins.py", *options])
            if result.returncode:
                return result.returncode
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
