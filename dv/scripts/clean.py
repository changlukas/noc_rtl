#!/usr/bin/env python3
"""Clean only the current DV output roots; retained historical builds are untouched."""
from pathlib import Path
import shutil
ROOT=Path(__file__).resolve().parents[2]


def clean(root):
    root=Path(root).resolve()
    if not (root/'sim/Makefile').is_file() or not (root/'dv/scripts').is_dir():
        raise ValueError('Not a NoC source checkout')
    for name in ('build/compile', 'build/regression'):
        target=root/name
        if target.is_symlink():
            target.unlink()
            continue
        resolved=target.resolve()
        if resolved != root/name or root not in resolved.parents:
            raise ValueError('Cleanup path escapes expected output root: '+str(target))
        if target.is_dir():
            shutil.rmtree(str(target))
    print('Cleaned build/compile and build/regression; historical outputs retained.')


if __name__=='__main__':
    clean(ROOT)
