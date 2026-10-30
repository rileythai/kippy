# Input formats

`kippy` chooses a reader from the supplied path. The checks are ordered: a
basename beginning with `seq.` or ending with `.seq` selects MONASH, a path
ending with `.kipp` selects the raw stream reader, and a path for which
`<path>/profiles.index` exists selects MESA. Every other path is passed to the
KEPLER convection reader; the `.cnv` suffix itself is not checked.

!!! tip
    `kippy` works best when you output _every single model_ for plotting. This 
    allows you to check for insufficient resolution in both space and time.

## List of formats

| Format | Detected from the path | Convection source | Energy or epsnuc source | Colour fields available |
| --- | --- | --- | --- | --- |
| KEPLER-style `.cnv` | Fallback after the other checks | Native `yzip` and `iconv` zone records | Native nuclear, neutrino, and related energy layers | No generic source-column fields |
| Raw `.kipp` stream | Path ends with `.kipp` | The stream's mixing column | One eps column supplies the net energy layer | Every named non-structural column in the `.hdr` sidecar |
| MESA profiles directory | `<path>/profiles.index` exists | `mixing_type` | `eps_nuc`; `eps_nuc_neu_total` supplies the neutrino layer | `logT`, `logRho`, `logL`, `luminosity`, `logP`, `pressure`, `opacity`, `entropy`, and `velocity`, when present |
| MONASH `seq` | Basename begins with `seq.` or ends with `.seq` | `kcvtn` | Approximate epsnuc from `dL/dm` | Temperature, density, pressure, luminosity, and seven reaction rates |

!!! note
    The MONASH stellar evolution code and KEPLER are both closed-source codes.

### KEPLER-style `.cnv`

The `.cnv` reader uses the convection zones, mass and radius coordinates,
and energy layers stored directly in the sequential unformatted [`.cnv` file format](cnvfiles.md).
These records provide compact representations for nuclear and neutrino loss bands used by the
plotting routines. The reader does not register generic source columns as selectable colour
fields.

The Fortran reader supports record versions 10600 through 10699 and record
versions 10700 and later. Versions below 10600, including 10400 and 10500, are
rejected with an error (dinosaur era). The full record layout is described in
[`.cnv` files](cnvfiles.md).

### MESA profiles directory

A MESA profiles directory containing `profiles.index` and the referenced
`profileN.data` files can be (slowly) loaded directly. 
`profiles.index` will map model numbers to profile numbers;
and each profile supplies our age and mass-radius grid for the plotted
model. 

`profile` directories can only load if the profiles themselves contain data 
for convection (`mixing_type` or `mlt_mixing_type`), the energy generation layer 
(`eps_nuc`, or `eps_nuc_neu_total` for a separate neutrino layer).


!!! warning
    MESA profiles are generally sparse in time than at every model. However, the band
    tracer will still bridge consecutive loaded profiles into continuous polygons. This is 
    a decision made for honesty at the cost of inaccuracy.

    For this reason (and your disk usage), I would recommend using [`.kipp` files](kippfiles.md).

`kippy` offers a curated set of the MESA columns as colour fields: `logT`, `logRho`,
`logL`, `luminosity`, `logP`, `pressure`, `opacity`, `entropy`, and `velocity`.
Only columns present in the run are registered.

### Raw `.kipp` binary stream

A [`.kipp` file](kippfiles.md) is a custom file designed as a binary profile-like record. The
file is described by a seperate header file (`.kipp.hdr`) to define column 
count and column names. The record by default should include the 
model, age, mass, radius, mixing, and single `eps` columns required to build the plot.
No separate neutrino layer is created.

__Every__ named column not used for model metadata,
coordinates, mixing types, or the energy generation band 
is available as a colour field. See [notes on colour fields below.](#colour-fields)

For a data path such as `path/to/file.kipp`, kippy first looks for
`path/to/file.kipp.hdr` beside it. If that file is absent, it looks for
`file.kipp.hdr` in the working directory. The full data and header format is
described in [`.kipp` files](kippfiles.md#file-format).

!!! note
    For `kipp` files, the reader will stream the data twice. 
    At the first pass builds coordinates, convection, and energy bands 
    while finding the run-wide range of each generic colour
    field. The second pass then quantizes color fields. This is done to keep
    the full run out of memory. 


### MONASH `seq`

The MONASH `seq` reader expects a gfortran sequential-unformatted file with one
record per model. Mass coordinates are reconstructed from the mass coordinate `omx` as
`mass * (1 - omx)^3`; cells are ordered from centre to surface.
Convection zones come from the `kcvtn` flag.

The epsnuc layer is approximated from the luminosity change per mass shell,
`dL/dm`. Note that this is not a pure nuclear energy-generation rate because the
luminosity difference also includes the gravothermal terms.

The registered colour fields are `Temperature`, `Density`, `Pressure`,
`Luminosity`, `H_reaction_rate`, `He3_reaction_rate`, `He4_reaction_rate`,
`C_reaction_rate`, `N_reaction_rate`, `O_reaction_rate`, and
`Other_reaction_rate`. These names are case-sensitive.

!!! note
    Like the `.kipp` reader, the MONASH  `.seq` reader uses one pass 
    to find field ranges and a second pass
    to build the quantized field layers.

## Colour fields

Use `color <column>` to select a registered non-structural column. See [the usage documentation](usage.md) for more details. 
Note that with each file format, color fields are loaded differently:

- The `.kipp` reader registers every named non-structural source column.
- the MESA profiles and MONASH readers only register the curated fields listed above.
- KEPLER-style `.cnv` files do not load any non-structural sources.

Use `fields` to list the selectors and ranges available for the loaded input.


Some other notes:

* On load, field values are always quantized into 24 contour bins over the minimum and maximum across the loaded run. 
* Scaling switches automatically from linear to logarithmic when the complete range is positive and 
  spans more than two decades. `color -<number>` shows a column in the other scale. 
* A logarithmic scale starts at the smallest positive value in the run, and values at 
  or below zero fall in the lowest bin. A column with no positive values has no 
  logarithmic scale. Both scales are binned at load to provide immediate switching.
* Generic fields are separate from the built-in `epsnuc` energy overlay.

### Unit recognition

The colorbar title is fetched from the column name with its unit in brackets. The unit is
either the one a `.kipp` header states for the column, or else a unit suffix on the
name, e.g., `_K`, `_g`, `_cm`, `_s`, `_yr`, `_gcc` (g/cm^3), `_erg_s` (erg/s) or
`_erg_g_s` (erg/g/s).

Units are written with negative exponents, so `g/cm^3`, `g/cm3` and `gcc` all show as
$g cm^{-3}$. Underscores in a name show as spaces, and a name that is a Greek
letter, such as `rho` or `kappa`, shows as the letter: e.g., `rho_gcc` is titled
$\log \rho\quad {\rm g cm^{-3}}$

A unit that is not of the form `a/b^n/c` is shown as written.
