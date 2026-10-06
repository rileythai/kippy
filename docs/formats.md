# Input formats

Kippy chooses a reader from the supplied path. The checks are ordered: a
basename beginning with `seq.` or ending with `.seq` selects MONASH, a path
ending with `.kipp` selects the raw stream reader, and a path for which
`<path>/profiles.index` exists selects MESA. Every other path is passed to the
KEPLER convection reader; the `.cnv` suffix itself is not checked.

| Format | Detected from the path | Convection source | Energy or epsnuc source | Colour fields available |
| --- | --- | --- | --- | --- |
| KEPLER `.cnv` | Fallback after the other checks | Native `yzip` and `iconv` zone records | Native nuclear, neutrino, and related energy layers | No generic source-column fields |
| MESA profiles directory | `<path>/profiles.index` exists | `mixing_type` | `eps_nuc`; `eps_nuc_neu_total` supplies the neutrino layer | `logT`, `logRho`, `logL`, `luminosity`, `logP`, `pressure`, `opacity`, `entropy`, and `velocity`, when present |
| Raw `.kipp` stream | Path ends with `.kipp` | The stream's mixing column | One eps column supplies the net energy layer | Every named non-structural column in the `.hdr` sidecar |
| MONASH `seq` | Basename begins with `seq.` or ends with `.seq` | `kcvtn` | Approximate epsnuc from `dL/dm` | Temperature, density, pressure, luminosity, and seven reaction rates |

## KEPLER `.cnv`

The KEPLER reader consumes the convection zones, mass and radius coordinates,
and energy layers stored directly in the sequential unformatted `.cnv` records.
These native energy records provide the nuclear and neutrino bands used by the
plot. The reader does not register generic source columns as selectable colour
fields.

The Fortran reader supports record versions 10600 through 10699 and record
versions 10700 and later. Versions below 10600 are rejected with an error that
directs the user to the Python `ConvData` reader. In particular, the Fortran
reader does not support record versions 10400 or 10500.

## MESA profiles directory

A MESA input is a directory containing `profiles.index` and the referenced
`profileN.data` files. `profiles.index` maps model numbers to profile numbers;
each selected profile supplies the age and mass-radius grid for one plotted
model. Convection zones come from `mixing_type`, the epsnuc layer comes from
`eps_nuc`, and `eps_nuc_neu_total` supplies a separate neutrino layer.

MESA profiles may be sparse in time rather than present at every model. The band
tracer bridges consecutive loaded profiles into continuous polygons.

Kippy offers a curated set of MESA columns as colour fields: `logT`, `logRho`,
`logL`, `luminosity`, `logP`, `pressure`, `opacity`, `entropy`, and `velocity`.
Only columns present in the run are registered.

## Raw `.kipp` binary stream

A `.kipp` file is a contiguous little-endian float64 cell dump. Cells are
grouped by monotonically increasing model number, with one row per zone. The
sidecar header defines the column count and column names, including the model,
age, mass, radius, mixing, and single eps columns required to build the plot.
The mixing column supplies convection, while the eps column supplies one net
energy layer; no separate neutrino layer is created.

For a data path such as `path/to/file.kipp`, Kippy first looks for
`path/to/file.kipp.hdr` beside it. If that file is absent, it looks for
`file.kipp.hdr` in the working directory.

The reader streams the data twice. The first pass builds coordinates,
convection, and energy while finding the run-wide range of each generic colour
field. The second pass quantizes those fields. This keeps the raw columns for
the full run out of memory. Every named column not used for model metadata,
coordinates, mixing, or eps is available as a colour field.

## MONASH `seq`

The MONASH reader expects a gfortran sequential-unformatted file with one
record per model. Mass coordinates are reconstructed from `omx` as
`mass * (1 - omx)^3`; the cells are already ordered from centre to surface.
Convection zones come from `kcvtn`.

The epsnuc layer is approximated from the luminosity change per mass shell,
`dL/dm`. This is not a pure nuclear energy-generation rate because the
luminosity difference also includes gravothermal terms.

The registered colour fields are `Temperature`, `Density`, `Pressure`,
`Luminosity`, `H_reaction_rate`, `He3_reaction_rate`, `He4_reaction_rate`,
`C_reaction_rate`, `N_reaction_rate`, `O_reaction_rate`, and
`Other_reaction_rate`. These names are case-sensitive. Like the raw stream
reader, the MONASH reader uses one pass to find field ranges and a second pass
to build the quantized field layers.

## Colour fields

Use `color <column>` to select a registered non-structural column. The raw
`.kipp` reader registers every named non-structural source column; the MESA and
MONASH readers register the curated fields listed above. Use `fields` to list
the selectors and ranges available for the loaded input.

Field values are quantized into 24 contour bins over the minimum and maximum
across the loaded run. Scaling switches automatically from linear to logarithmic
when the complete range is positive and spans more than two decades. These
generic fields are separate from the built-in `epsnuc` energy overlay.
