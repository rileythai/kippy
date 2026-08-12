# kippy

A native Fortran/giza Kippenhahn viewer for KEPLER `.cnv` convection output,
split out of [keppy](https://github.com/rileythai/keppy) as a standalone,
pip-installable package.

The plotting core is compiled Fortran (`kipp.f90`) linked against the vendored
[giza](https://github.com/danieljprice/giza) plotting library (a git
submodule). Python drives the compiled executables as subprocesses.

## Executables

- `convview` -- interactive Kippenhahn viewer (giza REPL, `/xw` window or PNG
  snapshots when headless)
- `convdump` -- headless reader diagnostic that prints first/last model stats

## Install

The build uses [meson](https://mesonbuild.com/) / ninja via
[meson-python](https://meson-python.readthedocs.io/) and compiles giza on first
build, so a Fortran toolchain and giza's backends are required:

- `gfortran`, `meson`, `ninja`
- `cairo`, `libx11`, `freetype2` development packages (giza backends)

Clone with submodules, then install:

```bash
git clone --recurse-submodules <url> kippy
cd kippy
pip install .          # or: uv pip install -e .
```

If you already cloned without `--recurse-submodules`:

```bash
git submodule update --init --recursive
```

## Usage

Command line:

```bash
convview path/to/model.cnv      # interactive viewer
convdump path/to/model.cnv      # print reader summary
```

From Python:

```python
import kippy

# print first/last model summary stats
print(kippy.dump("model.cnv"))

# render a PNG non-interactively
kippy.view("model.cnv", commands=["save kipp.png", "quit"])

# or launch the interactive REPL
kippy.view("model.cnv")
```

## MESA profiles

Besides KEPLER `.cnv` files, every entry point also accepts a MESA profiles
directory -- any directory containing a `profiles.index` alongside its
`profileN.data` files. The reader is chosen automatically from the path, so a
directory works anywhere a `.cnv` file did:

```bash
convview path/to/LOGS      # interactive viewer over the MESA run
convdump path/to/LOGS      # print reader summary
```

```python
kippy.view("path/to/LOGS", commands=["save kipp.png", "quit"])
```

MESA saves profiles sparsely in time (not every step); the band tracer bridges
them into continuous polygons. Convection zones come from the `mixing_type`
column and the `color epsnuc` overlay from `eps_nuc`.
