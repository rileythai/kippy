# `kipp` files

## Introduction

When using `kippy` with `MESA`, it is generally optimal for both disk space and file count to instead dump the relevant quantities into Fortran binary over the native ASCII formats of `profile` files. The routines to make the `.kipp` files that `kippy` expects, and an example/tutorial for their implementation, are on the [writing from MESA](mesa.md) page.

The [file format](#file-format) itself is specified below,
for writing `.kipp` files from other codes.

## File format

A `.kipp` input is two files: the binary data file, whose path must end in
`.kipp`, and a plain text sidecar header describing its columns.

### Data file

The data file is a headerless stream of **little-endian 64-bit IEEE floats**
with no record markers. It is read as rows of `ncols` values, where `ncols`
comes from the header, and each row is one cell of one model. Integer
quantities such as the model number and mixing type are stored as floats and
rounded to the nearest integer.

- The rows of one model must be contiguous. A row whose model number differs
  from the previous row starts a new model.
- Within a model, rows run from the **surface to the centre**, as MESA numbers
  its zones. `kippy` reverses them on load.
- Model numbers should increase through the file. A restart may append rows
  with model numbers that jump backwards; when a model number appears more than
  once, the last copy in the file is kept.
- The age and time step of a model are taken from its last row, so every row of
  a model should carry the same values.
- The file must contain at least two models. A partial row at the end of the
  file, such as one left by a run that was killed mid-write, is ignored.

The file can be read in Python with:

```python
import numpy as np

data = np.fromfile("profile.kipp", dtype="<f8").reshape(-1, ncols)
```

### Header file

For a data file `path/to/file.kipp`, the header is `path/to/file.kipp.hdr`. If
that is absent, `kippy` looks for `file.kipp.hdr` in the working directory.

The header is read line by line, and the first word of each line decides how it
is used:

| Line | Meaning |
| --- | --- |
| `ncols <n>` | Number of values per row. Required |
| `<index> <name> [unit]` | Names column `<index>`, counted from 1, with an optional unit |
| `dtype ...`, `columns`, `columns:` | Ignored |
| Blank lines and any other line | Ignored |

!!! warning
    The `dtype` line is informational only. `kippy` always reads the data as
    little-endian float64, so a file written with any other type will load as
    garbage.

Column names are case-sensitive single words; use letters, digits and
underscores only, since a space, comma or slash ends the name. Every index must
lie between 1 and `ncols`, and `ncols` can be at most 512. Columns without a
name line are skipped.

The optional third word is the column's unit, for example `2 star_age Myr` or
`8 rho g/cm^3`. The age, time step, mass and radius columns are converted from
it on load, so it must be one of the units below for that column's role (any
case), and any other unit stops the load with an error. Without a unit these
columns are read in the units their names imply. A stated mass or radius unit
also becomes that axis's starting display unit; the time axis picks its unit
from the view.

| Role | Units |
| --- | --- |
| Age, time step | `s`, `min`, `hr`, `d`, `yr`, `kyr`, `Myr`, `Gyr` |
| Mass | `g`, `kg`, `Msun` |
| Radius | `cm`, `m`, `km`, `Rsun` |

The mixing and energy columns ignore a unit. For a colour field, the unit only
labels the colorbar.

### Required columns

Each role below must be named by one of its accepted names, except the time
step, which is optional. The units are those used when the header line gives
none.

| Role | Accepted names | Units |
| --- | --- | --- |
| Model number | `model_number`, `model` | |
| Age | `star_age_yr`, `star_age`, `age_yr` | yr |
| Time step (optional) | `dt_s`, `dt` | s |
| Mass coordinate | `m_g`, `mass_g`, `mass` | g |
| Radius coordinate | `r_cm`, `radius_cm`, `r` | cm |
| Mixing type | `mixing_type`, `mix_type`, `mixing` | MESA mixing code |
| Energy generation | `eps_net_erg_g_s`, `eps_nuc`, `eps_net`, `eps` | erg/g/s |

The mixing column uses MESA's mixing codes, mapped to the `kippy` zone types:

| Code | Zone type |
| --- | --- |
| 0 | Radiative |
| 1 | Convective |
| 2 | Overshoot |
| 3 | Semiconvective |
| 4 | Thermohaline |
| 5 | Neutral (MESA rotational mixing) |
| 9 | Convective (MESA leftover convection) |
| Any other | Neutral |

The energy column drives the single `epsnuc` layer; there is no separate
neutrino layer, so a net rate such as `eps_nuc - non_nuc_neu` is the natural
choice. Each cell is binned to the nearest integer of `log10|eps|`, positive
values as gain and negative values as loss. Cells with `|eps|` below
`10^0.5`, about 3.16 erg/g/s, are not drawn.

### Colour fields

Every other named column, such as `zone`, `dm_g` or `T_K` in the example above,
is offered as a colour field under its header name, so it can be shown with
`color <name>`. Names longer than 32 characters are truncated. See
[colour fields](formats.md#colour-fields) for how the values are binned and
how the colorbar title shows the unit.
