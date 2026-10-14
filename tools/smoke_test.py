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

"""render a tiny synthetic .kipp run headless and check a png comes out

the cibuildwheel test command, so each built wheel runs its bundled
executables and libraries rather than only installing. stdlib only, since the
test env holds just the wheel.
"""

import os
import struct
import tempfile
from pathlib import Path

import kippy

COLS = ["model_number", "star_age_yr", "m_g", "r_cm", "mixing_type", "eps_nuc"]
NZONE = 8


def write_fixture(path):
    rows = []
    for model in (1, 2, 3):
        # .kipp rows run surface to centre; the inner two zones are convective
        for k in range(NZONE, 0, -1):
            rows.append((model, 1e3 * model, 2e33 * k / NZONE, 7e10 * k / NZONE, int(k <= 2), 10.0 ** (NZONE - k)))
    path.write_bytes(b"".join(struct.pack(f"<{len(COLS)}d", *row) for row in rows))
    header = f"ncols {len(COLS)}\n" + "".join(f"{i} {name}\n" for i, name in enumerate(COLS, 1))
    Path(f"{path}.hdr").write_text(header)


def main():
    with tempfile.TemporaryDirectory() as tmp:
        os.chdir(tmp)
        kipp = Path(tmp) / "smoke.kipp"
        png = Path(tmp) / "smoke.png"
        write_fixture(kipp)
        kippy.view(kipp, commands=[f"save {png}", "quit"])
        assert png.read_bytes()[:8] == b"\x89PNG\r\n\x1a\n", f"no png written to {png}"
        print(kippy.dump(kipp))
    print("smoke test ok")


if __name__ == "__main__":
    main()
