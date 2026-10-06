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

"""kippy -- a native Fortran/giza Kippenhahn viewer for KEPLER .cnv output

the plotting core is compiled Fortran linked against giza. python drives the
bundled executables (``convview``, ``convdump``) as subprocesses; see
:func:`view` and :func:`dump`.
"""

from __future__ import annotations

import importlib.resources
import os
import subprocess
from pathlib import Path

__all__ = ["view", "dump", "executable", "bin_dir", "child_env"]

__version__ = "0.1.0"


def _bundled(name: str) -> Path:
    """real filesystem path of a file shipped under kippy/bin

    resolved via importlib.resources rather than __file__ so it works both
    for a regular wheel install (kippy/bin sits beside __init__.py) and for
    an editable meson-python install (the binaries are served from the meson
    build tree, not the source dir that holds __init__.py)
    """
    return Path(str(importlib.resources.files("kippy") / "bin" / name))


def bin_dir() -> Path:
    """directory holding the bundled executables and libgiza"""
    return _bundled("convview").parent


def executable(name: str) -> Path:
    """resolve a bundled executable by name, raising if it is not present"""
    exe = _bundled(name)
    if not exe.exists():
        raise FileNotFoundError(
            f"kippy executable {name!r} not found at {exe}; "
            "the native build may have failed or not run"
        )
    return exe


def child_env() -> dict:
    """environment for launching the executables

    the bundled libgiza sits in bin_dir; prepend it to LD_LIBRARY_PATH so the
    loader finds it regardless of how the binary's rpath was packaged.
    """
    env = os.environ.copy()
    libdir = str(bin_dir())
    prev = env.get("LD_LIBRARY_PATH")
    env["LD_LIBRARY_PATH"] = libdir if not prev else libdir + os.pathsep + prev
    return env


def view(
    cnvfile: str | os.PathLike | None = None,
    *,
    commands: list[str] | None = None,
    check: bool = True,
) -> subprocess.CompletedProcess:
    """launch the interactive Kippenhahn viewer (``convview``)

    cnvfile:  path to a KEPLER .cnv file (defaults to convview's own default,
              ``convdata.cnv`` in the working directory)
    commands: optional REPL commands fed on stdin instead of an interactive
              session (e.g. ``["save out.png", "quit"]``); when omitted stdin
              is inherited so the user drives the REPL directly
    check:    raise CalledProcessError on non-zero exit
    """
    argv = [str(executable("convview"))]
    if cnvfile is not None:
        argv.append(str(cnvfile))

    if commands is None:
        return subprocess.run(argv, env=child_env(), check=check)

    stdin = "".join(line + "\n" for line in commands)
    return subprocess.run(argv, input=stdin, text=True, env=child_env(), check=check)


def dump(
    cnvfile: str | os.PathLike | None = None,
    *,
    check: bool = True,
) -> str:
    """run the headless reader diagnostic (``convdump``) and return its output

    prints first/last model summary stats for a .cnv file. useful for
    cross-checking the Fortran reader.
    """
    argv = [str(executable("convdump"))]
    if cnvfile is not None:
        argv.append(str(cnvfile))
    proc = subprocess.run(argv, capture_output=True, text=True, env=child_env(), check=check)
    return proc.stdout
