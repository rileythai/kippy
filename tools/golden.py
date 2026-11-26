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

"""render fixed views of kippy inputs and compare them byte for byte

pins convview's output while code moves between modules:

    uv run tools/golden.py write REFDIR INPUT...   # record references
    uv run tools/golden.py check REFDIR INPUT...   # exit 1 on any change

each input (plus a synthetic .kipp from smoke_test.py) is driven through one
fixed REPL script in its own convview process. compared per input: every png,
every pdf rasterised by pdftoppm (cairo's font subset tags differ between runs,
so the pdf bytes do not repeat), and the stdout transcript with paths replaced.
cursor-mode keys run headless through the `key` command under KIPP_SCRIPT.
"""

import argparse
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

import kippy
from smoke_test import write_fixture

# selectors that do not exist for an input print an error and render the
# previous view, which is still deterministic
SCRIPT = [
    "save default.png",
    "save default.pdf",
    "xaxis model", "save xmodel.png", "xaxis time",
    "yaxis radius", "save radius.png", "yaxis mass",
    "xscale log", "yscale log", "save loglog.png", "xscale lin", "yscale lin",
    "units Myr", "save myr.png", "units auto",
    "offset off", "save nooffset.png", "offset on",
    "grid on", "models off", "save grid.png", "grid off", "models on",
    "key z", "key z", "key z", "save zoom.png",
    "key h", "key k", "save pan.png",
    "key u", "key u", "save undo.png",
    "key v",
    *["key z"] * 12, "save deepzoom.png", "key v",
    "key r", "save keyreset.png",
    "color epsnuc", "save epsnuc.png",
    "color neu", "save neu.png",
    "color 4", "save field4.png", "save field4.pdf",
    "color -4", "save field4flip.png",
    "color 7", "cmap viridis_r", "save field7.png", "cmap teal",
    "yaxis radius", "yscale log", "color 4", "save field4radius.png",
    "quit",
]


def render(src, out):
    """run SCRIPT on src with outputs in out; pdfs are replaced by their rasters"""
    out.mkdir(parents=True)
    env = kippy.child_env()
    env.pop("DISPLAY", None)
    env["KIPP_SCRIPT"] = "1"
    run = subprocess.run([str(kippy.executable("convview")), str(src)], cwd=out, env=env,
                         input="".join(c + "\n" for c in SCRIPT), stdout=subprocess.PIPE,
                         stderr=subprocess.STDOUT, text=True)
    log = run.stdout.replace(str(src), "<input>").replace(str(out), "<out>")
    (out / "transcript.txt").write_text(f"exit {run.returncode}\n{log}")
    for pdf in out.glob("*.pdf"):
        subprocess.run(["pdftoppm", "-r", "100", "-png", str(pdf), str(pdf.with_suffix(""))], check=True)
        pdf.unlink()


def compare(ref, new):
    """list the files that are missing, extra or different between two trees"""
    rfiles = {p.relative_to(ref) for p in ref.rglob("*") if p.is_file()}
    nfiles = {p.relative_to(new) for p in new.rglob("*") if p.is_file()}
    bad = [f"missing {f}" for f in sorted(rfiles - nfiles)]
    bad += [f"extra {f}" for f in sorted(nfiles - rfiles)]
    bad += [f"differs {f}" for f in sorted(rfiles & nfiles)
            if (ref / f).read_bytes() != (new / f).read_bytes()]
    return bad


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("mode", choices=["write", "check"])
    ap.add_argument("refdir", type=Path)
    ap.add_argument("inputs", type=Path, nargs="+")
    args = ap.parse_args()

    with tempfile.TemporaryDirectory() as tmp:
        tmp = Path(tmp)
        synthetic = tmp / "in" / "synthetic.kipp"
        synthetic.parent.mkdir()
        write_fixture(synthetic)
        inputs = [p.resolve() for p in args.inputs] + [synthetic]
        if len({p.name for p in inputs}) != len(inputs):
            sys.exit("input file names must be distinct")

        if args.mode == "write":
            if args.refdir.exists():
                sys.exit(f"{args.refdir} exists; references are never overwritten")
            for src in inputs:
                render(src, args.refdir / src.name)
            print(f"wrote references for {len(inputs)} inputs to {args.refdir}")
            return

        for src in inputs:
            render(src, tmp / "out" / src.name)
        bad = compare(args.refdir, tmp / "out")
        if bad:
            keep = Path(tempfile.mkdtemp(prefix="golden-"))
            shutil.copytree(tmp / "out", keep, dirs_exist_ok=True)
            print("\n".join(bad))
            sys.exit(f"golden check failed: {len(bad)} files; renders kept in {keep}")
        print(f"golden check ok: {len(inputs)} inputs identical")


if __name__ == "__main__":
    main()
