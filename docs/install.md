# Installation

## Requirements

kippy builds with Meson and Ninja through meson-python. Building the compiled
Fortran core and bundled giza library requires:

- `gfortran`
- `meson`
- `ninja`
- development packages for cairo, libx11, and freetype2

## Clone the repository

Clone kippy with its submodules:

```bash
git clone --recurse-submodules <url> kippy
cd kippy
```

If the repository was cloned without submodules, initialize them separately:

```bash
git submodule update --init --recursive
```

## Install kippy

Install from the repository root:

```bash
pip install .
```

For an editable install with uv:

```bash
uv pip install -e .
```

If uv needs to rebuild the editable install using the toolchain in the active
environment, disable build isolation and force a reinstall:

```bash
uv pip install --no-build-isolation --force-reinstall -e .
```

The build ships `libgiza.so.2` under `kippy/bin`. The Python launchers add that
directory to `LD_LIBRARY_PATH` when starting the compiled executables.

## Build the documentation

Preview the documentation locally from the repository root:

```bash
uvx --from 'zensical>=0.0.68' zensical serve
```

Build the static site into `site/`:

```bash
uvx --from 'zensical>=0.0.68' zensical build
```

With [mise](https://mise.jdx.dev/), the same commands are `mise run docs:serve`
and `mise run docs:build`.
