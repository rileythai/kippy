# Installation

## From PyPI

kippy runs on Linux and macOS. Pre-built wheels for Linux (x86_64, aarch64) and
macOS 15 or newer (Apple Silicon, Intel) bundle all relevant libraries,
including `giza`, `cairo`, and `gfortran` runtime libs.

```bash
pip install kippy
```

The wheels do expect system X11 libraries: Linux needs `libX11`, `libXext`,
`libXrender` and `libexpat`, which most desktop Linux distributions already provide. 

macOS installs needs the [XQuartz](https://www.xquartz.org/) X server to draw X11 interactive windows
```bash
brew install --cask xquartz
```
!!! note
    XQuartz sets `DISPLAY` through launchd when you log in. If `echo $DISPLAY`
    prints nothing in a new terminal after installing, log out and back in. With
    `DISPLAY` set, `convview` opens the interactive window as on Linux. kippy has no
    native macOS window.

    Without XQuartz, `DISPLAY` is unset and `convview` renders headless to PNG and
    PDF files, with no cursor mode (see
    [headless rendering](usage.md#headless-rendering)).

    The `p` key copies the PNG to the macOS clipboard through `osascript`, which
    I have been told ships with macOS.


Without a matching wheel, pip will build from the `sdist`, which needs the
[requirements](#requirements) below. Note the macOS wheels are built for macOS 15 
or newer, so older versions will also build from the `sdist`.



## Building from source

### Requirements

kippy builds with Meson and Ninja through meson-python. Building the compiled
Fortran core and bundled giza library requires:

- `gfortran`
- `meson`
- `ninja`
- development packages for cairo, libx11, and freetype2

On macOS, install the Xcode command line tools and these Homebrew packages:

```bash
# macOS
xcode-select --install
brew install gcc meson ninja pkgconf cairo libx11 freetype
brew install --cask xquartz # so you can actually display stuff
```

For Linux:
```bash
# ubuntu/debian
sudo apt update
sudo apt install -y build-essential gfortran meson ninja-build pkg-config libcairo2-dev libx11-dev libfreetype-dev
```
```bash
# fedora/rhel/rocky/alma
sudo dnf install -y gcc gcc-c++ gcc-gfortran meson ninja-build pkgconf-pkg-config cairo-devel libX11-devel freetype-devel
```


### Clone and install

We recommend using the [`uv`](https://docs.astral.sh/uv/) package manager for building from source directly:

```bash
git clone --recurse-submodules https://github.com/rileythai/kippy # will clone giza submodule too
cd kippy && uv sync # will install all dependencies and install kippy
```

For an editable install with uv:

```bash
uv pip install -e .
```

Note that you will have to manually rebuild because editable installs are not aware of Fortran changes.
If `uv` needs to rebuild the editable install using the toolchain in the active
environment, disable build isolation and force a reinstall:

```bash
uv pip install --no-build-isolation --force-reinstall -e .
```

The build will ship `libgiza.so.2` under `kippy/bin`. The Python launchers add that
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
