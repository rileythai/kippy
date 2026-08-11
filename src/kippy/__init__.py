"""kippy -- a native Fortran/giza Kippenhahn viewer for KEPLER .cnv output

the plotting core is compiled Fortran linked against giza. python drives the
bundled executables (``convview``, ``convdump``) as subprocesses; see
:func:`view` and :func:`dump`.
"""

from __future__ import annotations

import os
import subprocess
from pathlib import Path

__all__ = ["view", "dump", "executable", "bin_dir"]

__version__ = "0.1.0"


def bin_dir() -> Path:
    """directory holding the bundled executables and libgiza"""
    return Path(__file__).resolve().parent / "bin"


def executable(name: str) -> Path:
    """resolve a bundled executable by name, raising if it is not present"""
    exe = bin_dir() / name
    if not exe.exists():
        raise FileNotFoundError(
            f"kippy executable {name!r} not found at {exe}; "
            "the native build may have failed or not run"
        )
    return exe


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
        return subprocess.run(argv, check=check)

    stdin = "".join(line + "\n" for line in commands)
    return subprocess.run(argv, input=stdin, text=True, check=check)


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
    proc = subprocess.run(argv, capture_output=True, text=True, check=check)
    return proc.stdout
