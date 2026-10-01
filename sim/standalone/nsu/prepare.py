#!/usr/bin/env python3
"""Stage existing NSU focused tests and their RTL dependencies."""
import argparse
import hashlib
from pathlib import Path
import shutil

ROOT = Path(__file__).resolve().parents[3]


def prepare(source, out):
    source, out = Path(source).resolve(), Path(out).resolve()
    out.mkdir(parents=True, exist_ok=True)

    def copy(path, relative):
        target = out / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        if not target.exists() or target.read_bytes() != path.read_bytes():
            shutil.copyfile(path, target)

    lines = []
    for line in (source / "files.f").read_text().splitlines():
        if line.startswith("+define+"):
            continue
        if line.startswith("+incdir+"):
            relative = line[len("+incdir+"):]
            for path in (source / relative).rglob("*"):
                if path.is_file():
                    copy(path, str(Path(relative) / path.relative_to(source / relative)))
        else:
            relative = line[3:] if line.startswith("-v ") else line
            if not (relative == "topology_pkg.sv" or relative.startswith(
                    ("deps/", "repo/deps/common_cells", "repo/rtl/common/",
                     "repo/rtl/nsu/", "repo/specgen/generated/sv/"))):
                continue
            copy(source / relative, relative)
        lines.append(line)
    (out / "files.f").write_text("\n".join(lines) + "\n")
    for entry in (ROOT / "deps").glob("*/LICENSE*"):
        for path in ([entry] if entry.is_file() else entry.rglob("*")):
            if path.is_file():
                copy(path, str(path.relative_to(ROOT)))
    for name in ("tb_nsu_context_buffer.sv", "tb_nsu_elaborate.sv"):
        copy(ROOT / "sim/standalone/nsu" / name, "repo/sim/standalone/nsu/" + name)
    for name in ("test_nsu_context.py", "pattern.txt"):
        copy(ROOT / "sim/standalone/nsu" / name, name)
    copy(ROOT / "sim/standalone/nsu/workstation.mk", "Makefile")
    copy(ROOT / "sim/standalone/common/clean.sh", "clean.sh")
    names = sorted(p for p in out.rglob("*") if p.is_file() and
                   p.name != "SHA256SUMS" and "build" not in p.relative_to(out).parts)
    (out / "SHA256SUMS").write_text("".join(
        hashlib.sha256(p.read_bytes()).hexdigest() + "  " + str(p.relative_to(out)) + "\n"
        for p in names))
    print(out)


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--source", required=True)
    parser.add_argument("--out", required=True)
    args = parser.parse_args()
    prepare(args.source, args.out)
