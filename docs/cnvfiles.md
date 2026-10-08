# `.cnv` files

## Introduction

`KEPLER` writes a convection history file, `.cnv`, as part of a normal run, so
no changes to the code are needed to use it with `kippy`. Each record holds the
convection zones, mass and radius grid, and quantized energy generation of one
model, which makes the file compact compared to full profile dumps.

This page describes the binary layout `kippy` expects, for anyone writing a
converter to `.cnv` or debugging a file that will not load. `kippy` treats any
path that does not match another [input format](formats.md) as a `.cnv` file;
the suffix itself is not checked.

## File structure

A `.cnv` file is a Fortran sequential unformatted file in **big-endian** byte
order, with one record per model. Each record is framed by 4-byte big-endian
record-length markers before and after the payload (the gfortran default).
Reading stops at the end of the file.

Every record carries its own version number, `nvers`, and `kippy` decodes each
record by its own version:

| `nvers` | Layout |
| --- | --- |
| below 10600 | Rejected with an error |
| 10600 to 10699 | `ladv` follows `rncoord`; no `toffset` |
| 10700 and later | `toffset` follows `dt`; `ladv` follows `ncoord` |

The header fields `idx_kind_len` and `nuc_kind_len` must be 4 and 2. These
select 16-bit integers for coordinate indices and 8-bit integers for energy
levels; any other value stops the load with an error. A model is therefore
limited to 32767 grid points.

## Record layout

Fields appear in the order below, with no padding between them. Types are
big-endian: `i1`, `i2`, `i4` are 1, 2 and 4-byte signed integers, `f8` is a
64-bit IEEE float and `c1` is a single byte character.

| Field | Type | Count | Description |
| --- | --- | --- | --- |
| `nvers` | `i4` | 1 | Record version |
| `ncyc` | `i4` | 1 | Model number |
| `timesec` | `f8` | 1 | Age (s) |
| `dt` | `f8` | 1 | Time step (s) |
| `toffset` | `f8` | 1 | Version 10700 and later only |
| `nconv` | `i4` | 1 | Number of convection zones |
| `nnuc`, `nnuk`, `nneu`, `nnucd`, `nnukd`, `nneud` | `i4` | 6 | Number of entries in each energy layer |
| `ncoord` | `i4` | 1 | Number of grid points |
| `ladv` | `i4` | 1 | Advection flags, version 10700 and later position |
| `idx_kind_len` | `i4` | 1 | Must be 4 |
| `nuc_kind_len` | `i4` | 1 | Must be 2 |
| `nuc`, `nuk`, `neu`, `nucd`, `nukd`, `neud` | `i1` | `nnuc`, ..., `nneud` | Energy levels of each layer, one array after another |
| `yzip` | `c1` | `nconv` | Type of each convection zone |
| `xmcoord` | `f8` | `ncoord` | Mass coordinate (g) |
| `rncoord` | `f8` | `ncoord` | Radius coordinate (cm) |
| `ladv` | `i4` | 1 | Advection flags, versions 10600 to 10699 position |
| `iadv` | `i2` | `nadv` | `nadv` is the number of bits set in `ladv` |
| `dmadv` | `f8` | `nadv` | |
| `dvadv` | `f8` | `nadv` | |
| `inuc`, `inuk`, `ineu`, `inucd`, `inukd`, `ineud` | `i2` | `nnuc`, ..., `nneud` | Grid index of each energy level entry |
| `iconv` | `i2` | `nconv` | Grid index of the outer edge of each convection zone |
| `levcnv` | `i4` | 1 | |
| level floors | `i4` | 12 | `minloss`, `mingain`, `minnucl`, `minnucg`, `minneul`, `minneug`, `minlossd`, `mingaind`, `minnucld`, `minnucgd`, `minneuld`, `minneugd` |
| `tc`, `dc`, `pc`, `ec`, `sc`, `ye`, `ab`, `et`, `sn`, `su`, `g1`, `g2`, `s1`, `s2` | `f8` | 14 | Central quantities |
| `aw` | `f8` | 3 | Central angular velocity vector (rad/s) |
| `summ0`, `radius0`, `an` | `f8` | 3 | |
| `abun` | `f8` | 20 | Central composition (mass fractions) |
| `eni`, `enk`, `enp`, `ent`, `epro`, `enn`, `enr`, `ensc`, `enes`, `enc`, `enpist`, `enid`, `enkd`, `enpd`, `entd`, `eprod`, `xlumn`, `enrd`, `enscd`, `enesd`, `encd`, `enpistd`, `xlum`, `xlum0`, `entloss`, `eniloss`, `enkloss`, `enploss`, `enrloss`, `angit` | `f8` | 30 | Global energy totals and rates, luminosities, and the moment of inertia `angit` |
| `angltv` | `f8` | 3 | Total angular momentum vector |
| `xmacc` | `f8` | 1 | |

`kippy` reads every field but only uses `ncyc`, `timesec`, the convection
zones, the coordinates, the `nuc`, `nuk` and `neu` layers, and the first six
level floors. Of the rest, only `tc`, `dc` and `summ0` are used, as diagnostics
printed by `convdump`.

## How `kippy` reads a record

### Models and time

`ncyc` gives the model axis and `timesec` the time axis, converted to years of
31556952 s. `KEPLER` appends to the file when a run restarts from an earlier
dump, so model numbers can jump backwards part way through. `kippy` keeps the
last record of each model number and sorts the records by model number.

### Coordinates

`xmcoord` and `rncoord` run from the centre to the surface. The first point is
the inner boundary and the last point, index `ncoord`, sets the mass or radius
of the star at the top of the plot. `summ0` is not added to the mass
coordinate.

### Convection zones

The zones tile the star from the centre outward. Zone `k` has type `yzip(k)`
and ends at grid index `iconv(k)`; the next zone starts there. The boundary is
placed between grid points `iconv(k)` and `iconv(k) + 1`, at the arithmetic
mean in mass or the volume mean, `((r1^3 + r2^3) / 2)^(1/3)`, in radius. The
first zone starts at grid point 1, and the last zone should end at `ncoord`.

| `yzip` | Zone type | Hatching |
| --- | --- | --- |
| `' '` | Radiative | Not drawn |
| `'N'` | Neutral | `X` |
| `'O'` | Overshoot | `+` |
| `'S'` | Semiconvective | Dense `X` |
| `'C'` | Convective | `/` |
| `'T'` | Thermohaline | `\` |

Any other character is drawn as radiative.

### Energy layers

Each layer is a step function over the grid stored as pairs: entry `j` sets the
level `nuc(j)` from grid index `inuc(j)` up to the next entry, and the last
entry extends to the surface. Positive levels are energy gain, negative levels
are loss, and 0 is neither.

The layers `nuc`, `nuk` and `neu` are drawn by `color epsnuc`, `color nuk` and
`color neu`. The derivative layers `nucd`, `nukd` and `neud` are read but not
drawn.

The colour bar labels each level with its `log10` value in erg/g/s. A gain
level `L` is labelled `gmin + L - 1` and a loss level `-L` is labelled
`lmin + L - 1`, where `(gmin, lmin)` is a consecutive pair of the level floors:
values 1 and 2 for `nuc`, 3 and 4 for `nuk`, and 5 and 6 for `neu`. The loss
floor is raised to the gain floor when it is lower. Only the floors of the
first record are used.

!!! note
    `kippy` reads the floors as (gain, loss) pairs per layer, so the
    historical field names do not match their meaning: `minloss` is the `nuc`
    gain floor.
