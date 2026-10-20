# Usage

## Command line

`convview` loads a convection data file, renders a Kippenhahn diagram, and provides a
command prompt:

```text
convview [path]
```

`convdump` loads the same data and prints the number of models followed by
summary values for the first and last models:

```text
convdump [path]
```

Both commands use `convdata.cnv` in the current directory when `path` is
omitted. Only the first command-line argument is used as the path.

When `DISPLAY` is non-empty, `convview` will open an interactive `/xw` window. It
renders once and enters Cursor mode (see below) before showing the `kipp>` prompt.
On macOS the window needs XQuartz (see [macOS](install.md#macos)).

Press `q`, `Esc` or `Ctrl-C` in the plot window to leave cursor mode and reach the prompt for REPL commands (see below).
Click the plot window (left, middle or right button) at the prompt to enter cursor mode again; the click itself does nothing else.
Closing the plot window quits `convview`, from cursor mode or the prompt.
Clicks and closing are only watched when standard input is a terminal and `KIPP_SCRIPT` is not set.

## Cursor mode

<video src="kippy_demo_v2.webm" autoplay loop muted playsinline title="Demonstration of kippy on an AGB model from MESA"></video>

Cursor actions use the mouse position in the plot window. Zoom and pan operate
in the current linear or logarithmic window coordinates.

| Key or mouse action | Effect |
| --- | --- |
| Left-click and drag | Select a rectangular x/y region and zoom to it. |
| `x` | Select an x range between the current position and a second cursor event. |
| `y` | Select a y range between the current position and a second cursor event. |
| Scroll up, `z`, or `+` | Zoom in by a factor of two about the cursor. |
| Scroll down, right-click, `Z`, or `-` | Zoom out by a factor of two about the cursor. |
| Scroll left or `h` | Pan left by one quarter of the current x span. |
| Scroll right or `l` | Pan right by one quarter of the current x span. |
| `j` | Pan down by one quarter of the current y span. |
| `k` | Pan up by one quarter of the current y span. |
| Middle-click or `c` | Center the current view on the cursor without changing its span. |
| `r`, `a`, or `0` | Restore automatic limits on both axes and render the full view. |
| `s` | Save a numbered PNG snapshot named `convview_NNNN.png`. |
| `p` | Copy a PNG snapshot to the system clipboard, with `wl-copy` or `xclip` on Linux and `osascript` on macOS. |
| `S` | Save a numbered PDF snapshot named `convview_NNNN.pdf`. |
| `g` | Toggle the cell and time boundary grid (see `grid` below). |
| `m` | Toggle the model-number strip (see `models` below). |
| `?` | Print cursor-mode help. |
| `q`, Esc, or `Ctrl-C` | Leave cursor mode and return to the REPL. |

PNG and PDF snapshots share one counter, beginning at `0001`. During a range
or rectangle selection, `q`, `Esc` or `Ctrl-C` cancels that selection.

## REPL commands

<video src="repl_demo.webm" controls muted playsinline title="Switching between the kipp> prompt and cursor mode"></video>

Commands and arguments are whitespace-separated and case-sensitive.

| Command | Aliases | Arguments | Effect |
| --- | --- | --- | --- |
| `xlim` | - | `<min> <max>` | Set the x-axis limits, disable automatic x limits, and render. Both arguments must be numbers. |
| `ylim` | - | `<min> <max>` | Set the y-axis limits, disable automatic y limits, and render. Both arguments must be numbers. |
| `xscale` | - | `lin\|log` | Select a linear or logarithmic x axis, autoscale, and render. |
| `yscale` | - | `lin\|log` | Select a linear or logarithmic y axis, autoscale, and render. |
| `xaxis` | - | `time\|model` | Plot time or model number on the x axis, rebuild the axes, autoscale x, and render. |
| `yaxis` | - | `mass\|radius` | Plot enclosed mass or radius on the y axis, rebuild the axes, autoscale y, and render. |
| `units` | - | `<unit>\|auto\|solar\|cgs` | Set the display unit of the axis matching the unit's dimension, keep the current view, and render. Time units are `s`, `min`, `hr`, `d`, `yr`, `kyr`, `Myr`, and `Gyr`; mass units are `g`, `kg`, and `Msun`; radius units are `cm`, `m`, `km`, and `Rsun`. Unit names are case-insensitive. By default (`auto`) the time unit follows the view: each render uses the largest time unit in which the visible span is at least 1, so zooming in moves from `Myr` to `kyr` to `yr` and back. A time unit pins the axis until `units auto`. A logarithmic x axis keeps its current unit. `solar` selects `Msun` and `Rsun`, and `cgs` selects `g` and `cm`; these default to `Msun` and `Rsun` unless a `.kipp` header states the unit of its mass or radius column. `xlim` takes numbers in the unit the axis label currently shows. A year is 31556952 s (Gregorian) and a day 86400 s. |
| `offset` | - | `on\|off` | Show the linear time axis relative to an offset, as matplotlib does, and render. The offset is the leading digits shared by both ends of the view, used only when it saves at least four digits, so the tick labels start near 0. It is printed at the right end of the axis, for example `+3.81233 Gyr` with ticks in kyr, in the largest of `yr`, `kyr`, `Myr`, and `Gyr` in which it is at least 1, or in the tick unit when that is `s`, `min`, `hr`, or `d`. A logarithmic or model-number x axis has no offset. `xlim` still takes full times. On by default; with the automatic time unit it appears once the view is much narrower than the time itself, such as 1 kyr at 3.8 Gyr. |
| `color` | `colour` | `<selector\|number>` | Select the color field and render. Fixed selectors are `convtype`, `epsnuc` (`enuc`, `nuc`), `nuk` (`loss`), and `neu` (`neutrino`). A registered source column name or supported friendly alias may also be used, or the entry's number from the `fields` list. `convtype` shows convection hatching without a color-field overlay. With no argument, prints the numbered list like `fields`. |
| `cmap` | `colormap`, `colourmap` | `<name\|number>[_r]` | Select the colormap used for registered column fields and render. Names are `teal` (default), `blue`, `gray`, and the matplotlib maps `viridis`, `plasma`, `inferno`, `magma`, `cividis`, `Greys`, `Blues`, `Greens`, `Reds`, `Purples`, `Oranges`, `coolwarm`, `RdBu`, and `turbo`. A `_r` suffix reverses the map, and `grey` is an alias for `gray`. With no argument, prints the numbered list. |
| `models` | - | `on\|off` | Show or hide the model-density strip and render. The strip is on by default. |
| `grid` | - | `on\|off` | Show or hide grey resolution grid lines and render. The grid is off by default. Each model's strip shows that model's stored cell faces, and vertical lines mark the strip edges halfway between neighbouring models. Lines closer than a device pixel are merged, so a densely resolved region fills in solid. Only models written to the file appear, and a KEPLER `.cnv` stores a reduced set of grid points rather than every zone. |
| `fields` | `columns` | - | List the fixed color selectors and the registered source columns, numbered for `color <number>`, including each column's linear or logarithmic scale and value range. |
| `save` | - | `<file.png\|file.pdf>` | Render once to the named file. A name ending in `.pdf` creates a fixed 3.5-inch-wide, one-column PDF page; `.png` creates a PNG. Other suffixes are treated as part of a PNG prefix and `.png` is appended. |
| `key` | - | `<char> [x y]` | When `KIPP_SCRIPT` is set, run one cursor-mode action. Only the first character is used. Coordinates are in the current plot window coordinate system and default to the view center; on a logarithmic axis they are log10 coordinates. Without `KIPP_SCRIPT`, the command is rejected as unknown. |
| `cursor` | `i`, `interact` | - | Enter cursor mode. This requires an interactive `/xw` device. Clicking the plot window at the prompt does the same. |
| `reset` | - | - | Restore automatic limits on both axes, autoscale, and render. |
| `redraw` | `r` | - | Render the current view again. |
| `help` | `h`, `?` | - | Print the REPL command summary. |
| `quit` | `q`, `exit` | - | Close the current device and exit. EOF or Ctrl-D also exits the REPL. |

## Resolution grid

`grid on`, or `g` in cursor mode, draws the stored cell faces of every model
and the boundaries between models, so you can check whether a feature is
resolved in mass and in time. Lines closer than a device pixel merge, so zoom in
until the cells separate. The example below zooms into hot third dredge-up in a
6 solar-mass AGB star run with MESA; each grey box is one cell of one stored
model.

![Resolution grid during hot third dredge-up in a 6 solar-mass MESA AGB model](grid_demo.png)

## Color fields

`color` with no argument lists the fields that can be shown: the fixed
selectors, then the registered columns of the input with their scale and range
across the run. For a typical MESA-written `.kipp`:

```text
kipp> color
color selectors (color <name|number>):
   1  convtype   (no colour field, convection hatch only)
   2  epsnuc     nuclear energy layer (log erg/g/s)
   3  neu        neutrino energy layer (log erg/g/s)
  column fields (min .. max across the run):
   4  zone              log  1.000E+00 ..   2.483E+03
   5  dm_g              log  6.449E+21 ..   1.029E+32
   6  T_K               log  3.151E+03 ..   4.483E+08
   7  rho_gcc           log  1.671E-09 ..   2.332E+07
   8  L_erg_s           lin -1.407E+39 ..   1.448E+40
```

Select a field by name or number, for example `color rho_gcc` or `color 7`.
`cmap` with no argument lists the colormaps, selected the same way:

```text
kipp> cmap
colormaps (cmap <name|number>, append _r to reverse):
   1  teal     (current)
   2  blue
   3  gray
   4  viridis
   5  plasma
   6  inferno
   7  magma
   8  cividis
   9  Greys
  10  Blues
  11  Greens
  12  Reds
  13  Purples
  14  Oranges
  15  coolwarm
  16  RdBu
  17  turbo
```

`color rho_gcc` with `cmap inferno` on the same run:

![Density field with the inferno colormap](custom_field_demo.png)

Friendly column aliases recognized by the renderer are `temperature`, `temp`,
or `T`; `density`, `rho`, or `Rho`; `luminosity`, `lum`, or `L`; and `pressure`
or `P`. Each alias selects the first corresponding canonical field present in
the input. See [colour fields](formats.md#colour-fields) for how values are
binned.

## Axes

`yaxis radius` plots radius instead of enclosed mass, and `yscale log` spreads
out the compact core. `xaxis model` plots model number instead of time. Each
of these autoscales the axis it changes, while `units` changes an axis unit and
keeps the current view, for example `units km`. The example shows the same run
between about 0.01 and 0.07 solar radii with `yaxis radius` and `yscale log`:

![Log radius axis zoomed into the core](radius_demo.png)


# Headless rendering and scripting

To enable scripting, `kippy`'s core interface supports a headless rendering mode and scripted rendering.

## Headless rendering
When `DISPLAY` is unset or empty, as on macOS without XQuartz, `convview` uses
the `/png` device. The initial render writes
`convview.png`; each command that renders again replaces that file. Cursor mode
is unavailable in this mode. Use `save` to write a separately named PNG or PDF.

Setting `KIPP_SCRIPT` to any non-empty value skips automatic entry into cursor
mode when an interactive window is available. It also enables the `key` REPL
command.


## Scripted rendering

Set `KIPP_SCRIPT` when piping commands so an available X window does not enter
cursor mode before reading standard input:

```sh
printf '%s\n' \
  'xaxis model' \
  'color epsnuc' \
  'cmap viridis' \
  'save diagram.png' \
  'quit' | KIPP_SCRIPT=1 convview path/to/model.cnv
```

To force the regular render device to be headless as well, remove `DISPLAY`
from the command environment, for example with `env -u DISPLAY`.

The Python API feeds `commands` to the same REPL. Set `KIPP_SCRIPT` in the
process environment to skip automatic cursor mode when `DISPLAY` is present:

```python
import os

import kippy

os.environ["KIPP_SCRIPT"] = "1"
kippy.view(
    "path/to/model.cnv",
    commands=[
        "xaxis model",
        "color epsnuc",
        "cmap viridis",
        "save diagram.pdf",
        "quit",
    ],
)
```
