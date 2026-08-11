#!/usr/bin/env python3
"""build the vendored giza submodule and stage its artifacts for meson

giza uses an autotools build, so meson drives it through this helper as a
custom target. we configure (once) and make giza in-source, then copy the
shared library, the fortran module, and the fortran interface object into
the meson output dir so the kippy executables can compile and link.

usage: build_giza.py <giza_source_dir> <out_dir>
"""

import os
import shutil
import subprocess
import sys
from pathlib import Path

# shared lib real name and its versioned/linker symlinks (soname libgiza.so.2)
LIB_REAL = "libgiza.so.2.0.0"
LIB_LINKS = ("libgiza.so.2", "libgiza.so")
MODFILE = "giza.mod"
FOBJ = "giza-fortran.o"


def run(cmd, cwd):
    print(f"[build_giza] {' '.join(str(c) for c in cmd)}  (cwd={cwd})", flush=True)
    subprocess.run(cmd, cwd=cwd, check=True)


def main():
    giza = Path(sys.argv[1]).resolve()
    out = Path(sys.argv[2]).resolve()
    out.mkdir(parents=True, exist_ok=True)

    src = giza / "src"
    libs = src / ".libs"

    if not (giza / "configure").exists():
        # a bare checkout without generated configure needs autoreconf first
        run(["autoreconf", "--install"], giza)

    # configure once, keyed on config.status so rebuilds are cheap
    if not (giza / "config.status").exists():
        run(["./configure"], giza)

    run(["make", f"-j{os.cpu_count() or 1}"], giza)

    # stage the real shared object, recreate its symlink chain locally
    shutil.copy2(libs / LIB_REAL, out / LIB_REAL)
    for link in LIB_LINKS:
        target = out / link
        if target.exists() or target.is_symlink():
            target.unlink()
        target.symlink_to(LIB_REAL)

    shutil.copy2(src / MODFILE, out / MODFILE)
    shutil.copy2(libs / FOBJ, out / FOBJ)

    print("[build_giza] staged artifacts in", out, flush=True)


if __name__ == "__main__":
    main()
