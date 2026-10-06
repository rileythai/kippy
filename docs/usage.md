# Usage

## Command line

`convview` loads convection data, renders a Kippenhahn diagram, and provides a
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

### Interactive and headless rendering

When `DISPLAY` is non-empty, `convview` opens an interactive `/xw` window. It
renders once and enters cursor mode before showing the `kipp>` prompt. Press
`q` or Esc in the plot window to leave cursor mode and reach the prompt.

Without `DISPLAY`, `convview` uses the `/png` device. The initial render writes
`convview.png`; each command that renders again replaces that file. Cursor mode
is unavailable in this mode. Use `save` to write a separately named PNG or PDF.

Setting `KIPP_SCRIPT` to any non-empty value skips automatic entry into cursor
mode when an interactive window is available. It also enables the `key` REPL
command.

## REPL commands

Commands and arguments are whitespace-separated and case-sensitive.

| Command | Aliases | Arguments | Effect |
| --- | --- | --- | --- |
| `xlim` | - | `<min> <max>` | Set the x-axis limits, disable automatic x limits, and render. Both arguments must be numbers. |
| `ylim` | - | `<min> <max>` | Set the y-axis limits, disable automatic y limits, and render. Both arguments must be numbers. |
| `xscale` | - | `lin\|log` | Select a linear or logarithmic x axis, autoscale, and render. |
| `yscale` | - | `lin\|log` | Select a linear or logarithmic y axis, autoscale, and render. |
| `xaxis` | - | `time\|model` | Plot time or model number on the x axis, rebuild the axes, autoscale x, and render. |
| `yaxis` | - | `mass\|radius` | Plot enclosed mass or radius on the y axis, rebuild the axes, autoscale y, and render. |
| `units` | - | `solar\|msun\|rsun\|cgs` | Use solar units for `solar`, `msun`, or `rsun`; any other value selects cgs. Autoscale y and render. |
| `color` | `colour` | `<selector>` | Select the color field and render. Fixed selectors are `convtype`, `epsnuc` (`enuc`, `nuc`), `nuk` (`loss`), and `neu` (`neutrino`). A registered source column name or supported friendly alias may also be used. `convtype` shows convection hatching without a color-field overlay. |
| `cmap` | `colormap`, `colourmap` | `teal\|viridis\|blue\|gray\|grey` | Select the colormap used for registered column fields and render. `grey` is an alias for `gray`. |
| `models` | - | `on\|off` | Show or hide the model-density strip and render. The strip is on by default. |
| `fields` | `columns` | - | List the fixed color selectors and the registered source columns, including each column's linear or logarithmic scale and value range. |
| `save` | - | `<file.png\|file.pdf>` | Render once to the named file. A name ending in `.pdf` creates a fixed 3.5-inch-wide, one-column PDF page; `.png` creates a PNG. Other suffixes are treated as part of a PNG prefix and `.png` is appended. |
| `key` | - | `<char> [x y]` | When `KIPP_SCRIPT` is set, run one cursor-mode action. Only the first character is used. Coordinates are in the current plot window coordinate system and default to the view center; on a logarithmic axis they are log10 coordinates. Without `KIPP_SCRIPT`, the command is rejected as unknown. |
| `cursor` | `i`, `interact` | - | Enter cursor mode. This requires an interactive `/xw` device. |
| `reset` | - | - | Restore automatic limits on both axes, autoscale, and render. |
| `redraw` | `r` | - | Render the current view again. |
| `help` | `h`, `?` | - | Print the REPL command summary. |
| `quit` | `q`, `exit` | - | Close the current device and exit. EOF or Ctrl-D also exits the REPL. |

The registered source columns depend on the loaded input. Run `fields` before
using `color <column>`. Friendly column aliases recognized by the renderer are
`temperature`, `temp`, or `T`; `density`, `rho`, or `Rho`; `luminosity`, `lum`,
or `L`; and `pressure` or `P`. Each alias selects the first corresponding
canonical field present in the input.

## Cursor mode

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
| `p` | Copy a PNG snapshot to the system clipboard. |
| `S` | Save a numbered PDF snapshot named `convview_NNNN.pdf`. |
| `?` | Print cursor-mode help. |
| `q` or Esc | Leave cursor mode and return to the REPL. |

PNG and PDF snapshots share one counter, beginning at `0001`. During a range
or rectangle selection, `q` or Esc cancels that selection.

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
