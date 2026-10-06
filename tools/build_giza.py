#!/usr/bin/env python3
# kippy - Kippenhahn diagram viewer
# Copyright (C) 2026 the kippy authors (see AUTHORS)
#
# This file is part of kippy.
#
# kippy is free software: you can redistribute it and/or modify
# it under the terms of the GNU Lesser General Public License as
# published by the Free Software Foundation, either version 3 of the
# License, or (at your option) any later version.
#
# kippy is distributed in the hope that it will be useful, but WITHOUT
# ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
# FITNESS FOR A PARTICULAR PURPOSE. See the GNU Lesser General Public
# License for more details.
#
# You should have received a copy of the GNU Lesser General Public
# License along with kippy. If not, see <https://www.gnu.org/licenses/>.

"""build the giza submodule and stage its artifacts for meson

giza uses an autotools build, so meson drives it through this helper as a
custom target. we run an out-of-source (VPATH) build inside the meson output
dir and copy the shared library, the fortran module, and the fortran interface
object out for the kippy executables to compile and link against.

the build is kept out-of-source on purpose: an in-source build writes
config.status, Makefiles, and object files into the giza submodule, dirtying
the source tree on every install. building under out_dir keeps the checkout
pristine and confines all artifacts to the meson build directory.

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

    # out-of-source build tree; giza's autotools drops libtool artifacts under
    # src/ and src/.libs relative to this dir
    builddir = out / "giza-build"
    builddir.mkdir(parents=True, exist_ok=True)
    src = builddir / "src"
    libs = src / ".libs"

    if not (giza / "configure").exists():
        # a bare checkout without generated configure needs autoreconf first.
        # this writes into the source tree, but giza ships configure so it is
        # only hit on a stripped checkout
        run(["autoreconf", "--install"], giza)

    # configure once, keyed on config.status so incremental rebuilds are cheap
    if not (builddir / "config.status").exists():
        run([str(giza / "configure")], builddir)

    run(["make", f"-j{os.cpu_count() or 1}"], builddir)

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
