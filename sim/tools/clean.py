#!/usr/bin/env python3
"""Remove repository-generated outputs without following directory symlinks."""
import os
from pathlib import Path
import shutil
import subprocess

ROOT = Path(__file__).resolve().parents[2]


def clean(root):
    root = Path(root).resolve()
    if not (root / "sim/standalone/common/clean.sh").is_file():
        raise ValueError("Not a NoC source checkout")
    outputs = [root / "build"]
    outputs += list((root / "sim/standalone").glob("*/output"))
    outputs += list((root / "sim/test_patterns").glob("*/generated"))

    def remove(path):
        # Check the parent, then unlink a symlink itself rather than its target.
        if not path.parent.resolve().is_relative_to(root):
            raise ValueError("Cleanup path escapes repository: " + str(path))
        if path.is_symlink() or path.is_file():
            path.unlink()
        elif path.is_dir():
            shutil.rmtree(path)

    def clear_output(path):
        if path.is_symlink():
            remove(path)
        elif path.is_dir():
            for child in path.iterdir():
                if child == root / "build/backlog.md" or child.name == "tools.mk":
                    continue
                clear_output(child)
            if not any(path.iterdir()):
                path.rmdir()
        elif path.exists():
            remove(path)

    # Standalone VCS may use a stage-specific /tmp cache. Let its existing
    # cleanup perform the cache ownership checks before removing the stage.
    for output in outputs:
        if not output.is_dir() or output.is_symlink():
            continue
        for directory, dirs, names in os.walk(output, followlinks=False):
            dirs[:] = [d for d in dirs if not (Path(directory) / d).is_symlink()]
            stage = Path(directory)
            if "files.f" not in names:
                continue
            script = stage / "script/clean.sh"
            if not script.exists():
                script = stage / "clean.sh"
            if script.is_file():
                subprocess.run(["bash", str(script)], check=True)
                dirs[:] = []
    for output in outputs:
        clear_output(output)
    for directory, dirs, _ in os.walk(root, followlinks=False):
        dirs[:] = [d for d in dirs if d != ".git" and not (Path(directory) / d).is_symlink()]
        for name in list(dirs):
            if name in ("__pycache__", ".pytest_cache"):
                remove(Path(directory) / name)
                dirs.remove(name)
    print("Cleaned generated stages, builds, reports, waves and Python caches.")


if __name__ == "__main__":
    clean(ROOT)
