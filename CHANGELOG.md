# Changelog

All notable changes to kippy are documented in this file. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and kippy uses
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- macOS support, with arm64 and x86_64 wheels for macOS 15.0 and later. The
  interactive window runs on XQuartz (`/xw`).
- `units <unit>|auto|solar|cgs` sets the time, mass and radius axis units. By
  default the time unit follows the view span while zooming. `.kipp` headers
  can state a unit for each column.
- `offset on|off` shows a matplotlib-style offset on a linear time axis, on by
  default.
- `grid on|off`, and `g` in cursor mode, draw a cell and time resolution grid.
- `v` in cursor mode prints the cell under the cursor: model, time, zone,
  convection type and colour value.
- `m` in cursor mode toggles the model-number strip.
- `color -N` shows column field N in its other scale, linear or logarithmic.
- Matplotlib colormaps `viridis`, `plasma`, `inferno`, `magma`, `cividis`,
  `Greys`, `Blues`, `Greens`, `Reds`, `Purples`, `Oranges`, `coolwarm`, `RdBu`
  and `turbo`, reversed with `_r`. Bare `cmap` and `color` print numbered
  lists, and both accept a number.
- Clicking the plot window at the `kipp>` prompt enters cursor mode, and
  `Ctrl-C` leaves it.
- Closing the plot window quits `convview`.
- `p` copies the PNG to the macOS clipboard through `osascript`.
- An example MESA `run_star_extras.f90` that writes `.kipp` files, in
  `example/`.
- Docs: a command reference page, a `.cnv` format page, the full `.kipp`
  format spec and video demos.

### Changed

- Colorbars are framed strips with labels outside the strip, and their titles
  carry units and render Greek letters. Axis labels use the solar symbols.
- The bundled giza is now 2.0.2, from the `rileythai/giza` fork.

### Fixed

- Output paths over 64 characters were truncated and saved under the wrong
  name. Paths up to 256 characters now work.
- Tick labels no longer overlap each other or the colorbar, or hang below the
  x axis on deep zooms.
- The MESA reader recognises the `mlt_mixing_type` column.

## [0.1.0] - 2026-10-06

First release on PyPI, as an sdist and manylinux wheels (x86_64, aarch64) for
CPython 3.10 to 3.15.
