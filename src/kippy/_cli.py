"""console entry points that forward to the bundled Fortran executables

installed as the ``convview`` and ``convdump`` commands. each forwards its
argv straight through to the native binary and mirrors the exit code.
"""

from __future__ import annotations

import subprocess
import sys

from . import child_env, executable


def _forward(name: str) -> int:
    proc = subprocess.run([str(executable(name)), *sys.argv[1:]], env=child_env())
    return proc.returncode


def convview() -> int:
    return _forward("convview")


def convdump() -> int:
    return _forward("convdump")
