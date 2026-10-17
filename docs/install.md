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

## macOS

The macOS wheels need macOS 15 or newer. On older versions pip builds from the
sdist, which needs the Homebrew packages listed under
[Requirements](#requirements).

kippy draws its interactive window with X11, so macOS needs the
[XQuartz](https://www.xquartz.org/) X server:

```bash
brew install --cask xquartz
```

XQuartz sets `DISPLAY` through launchd when you log in. If `echo $DISPLAY`
prints nothing in a new terminal after installing, log out and back in. With
`DISPLAY` set, `convview` opens the interactive window as on Linux. kippy has no
native macOS window.

Without XQuartz, `DISPLAY` is unset and `convview` renders headless to PNG and
PDF files, with no cursor mode (see
[headless rendering](usage.md#headless-rendering)).

The `p` key copies the PNG to the macOS clipboard through `osascript`, which
ships with macOS.

## Building from source

### Requirements

kippy builds with Meson and Ninja through meson-python. Building the compiled
Fortran core and bundled giza library requires:

- `gfortran`
- `meson`
- `ninja`
- development packages for cairo, libx11, and freetype2

On macOS, install the Xcode command line tools and these Homebrew packages
(`gcc` supplies `gfortran`, and `cairo` pulls in libx11 and freetype2):

```bash
xcode-select --install
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
