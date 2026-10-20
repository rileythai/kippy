# Command reference

## Cursor mode

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
