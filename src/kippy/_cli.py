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
