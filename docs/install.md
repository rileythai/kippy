# Installation

## From PyPI

kippy runs on Linux and macOS. Pre-built wheels for Linux (x86_64, aarch64) and
macOS 15 or newer (Apple Silicon, Intel) bundle all relevant libraries,
including giza and cairo and gfortran runtime libs.

```bash
pip install kippy
```

The Linux wheels do expect the system X11 libraries (`libX11`, `libXext`,
`libXrender`) and `libexpat`, which desktop Linux installs already provide.
Without a matching wheel, pip will build from the `sdist`, which needs the
requirements below.

On macOS the interactive window needs an X server such as
[XQuartz](https://www.xquartz.org/). Without one (no `DISPLAY` set), kippy
renders to PNG and PDF only.

## Building from source

### Requirements

kippy builds with Meson and Ninja through meson-python. Building the compiled
Fortran core and bundled giza library requires:

- `gfortran`
- `meson`
- `ninja`
- development packages for cairo, libx11, and freetype2

On macOS, Homebrew provides these (`gcc` supplies `gfortran`, and `cairo` pulls
in libx11 and freetype2), along with the Xcode command line tools:

```bash
brew install gcc pkgconf cairo
```

### Clone the repository

Clone kippy with its submodules:

```bash
git clone --recurse-submodules https://github.com/rileythai/kippy
cd kippy
```

If the repository was cloned without submodules, initialize them separately:

```bash
git submodule update --init --recursive
```

### Install kippy

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
directory to `LD_LIBRARY_PATH` when starting the compiled executables. On macOS
the library is `libgiza.2.dylib`, found through the executables'
`@loader_path` rpath.

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
