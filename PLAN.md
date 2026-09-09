# PLAN.md

## Goal

kippy — A native Fortran/giza Kippenhahn viewer for KEPLER `.cnv` convection
output (and MESA profile directories), split out of keppy as a standalone,
pip-installable package. The plotting core is compiled Fortran linked against
a vendored giza submodule; Python drives the executables as subprocesses.

## Milestones

- Ship a self-contained meson-python build that compiles giza on first build.
- Read both KEPLER `.cnv` binaries and MESA profile directories.
- Publish to PyPI as an installable wheel.

## Tasks

| ID | Task | Status | Assigned | Notes |
|----|------|--------|----------|-------|
| 1 | Initial package split from keppy kippenhahn | done | Claude | `46313c3`; own git repo, vendors the `.cnv` reader fortran + giza submodule |
| 2 | meson-python build, giza compiled on first build | done | Claude | `tools/build_giza.py` custom target (autotools configure+make); `libgiza.so.2` staged under `kippy/bin` |
| 3 | Runtime libgiza resolution (LD_LIBRARY_PATH from launchers) | done | Claude | `874f1a5`; meson-python leaves the giza custom-target rpath unpatched, python launchers inject `kippy/bin` |
| 4 | Bake `$ORIGIN` rpath into build tree | done | Claude | `3dadcaf` |
| 5 | Build giza out-of-source | done | Claude | `ed61246` + `7971707` (path resolution fix) |
| 6 | MESA profiles reader (`mesaload.f90`) | done | Claude | `eb3a664` (merged `c0b904a`); auto-detect via `profiles.index`, convection from `mixing_type`, epsnuc from `eps_nuc` |
| 7 | Publish to PyPI | pending | — | Package name `kippy` v0.1.0; needs a release build + trusted-publish/CI |
| 8 | Raw `.kipp` binary stream reader (`loadkipp` in `mesaload.f90`) | done | Claude | dispatch on `.kipp` suffix; layout from a sidecar `<file>.hdr` (found next to the file, else basename in cwd); streams the float64 cell dump in chunks (2.7 GB class, ~940 MB RSS, ~5.6 s), groups cells by monotonic `model_number`, reverses surface->center to center->surface, reuses `build_zones`/`build_energy`; single net `eps` column drives the nuc layer, neu layer empty |
| 9 | Arbitrary column colour fields (`color <column>`) | done | Claude | any non-structural source column is registered as a generic colour field (`convdata` `fieldlayer` + shared `field_names/vmin/vmax/log` registry); values quantized into `FIELD_NBINS=24` contour bins over the min/max across the run (auto log when positive and >2 decades), traced with the existing band tracer, drawn as nested viridis contours with a value-labelled colorbar. `.kipp` reader does two streaming passes (range then quantize) so only compact step functions stay resident; MESA-dir reader registers a curated column set. REPL: `color <column>` + `fields` list. Verified on real `profile.kipp` (T_K log 3.5e3-2.7e8 K, ~27 entries/model) and a synthetic fixture render |
| 10 | MONASH `seq` file reader (`monload.f90`) + shared `convbuild` module | done | Claude+codex-swarm | seq is a gfortran sequential-unformatted file, one record per model, layout per `seqdump.f90`; mass shells from `omx` (`m=mass*(1-omx)^3`, already center->surface, no reversal), convection from `kcvtn`, approximate `epsnuc` from `dL/dm`, curated colour fields (Temperature/Density/Pressure/Luminosity + 7 reaction rates) reconstructed with seqdump formulas via two-pass range-then-quantize; reader-agnostic builders extracted from `mesaload` into a new `convbuild` module so `mesaload`+`monload` share them without a module cycle; dispatched in `load_convection` on a `seq.` prefix or `.seq` suffix. Verified on a 40-record fixture (models 1-40, T range 8e3-2.3e7 K) + `.cnv`/`convdump` no regression |
| 11 | Model-density strip (port keppy `ModelsLegend`) | in progress | Claude+codex-swarm | top-margin tick strip in `kipp.f90`, one tick per model at its time, tick height/width/colour scaled by the model-number decade magnitude (`lev=2*mag+half`); `models on\|off` REPL toggle in `convview.f90`; on by default |

### Inherited from keppy

These tasks were completed in the keppy repo before the split (keppy PLAN.md
IDs preserved as `K##`). They built the viewer and reader now vendored here, so
they are carried for provenance. All `done` in keppy.

| ID | Task | Status | Assigned | Notes |
|----|------|--------|----------|-------|
| K27 | Sync Fortran ConvData reader to record versions 10400–10700+ | done | Claude | Version dispatch in `convload.f90`/`convdata.f90` (was hardcoded v10600); adds `toffset` (≥10700), moves `ladv` read; mirrors Python `ConvData._load_10400`. Prereq for the viewer reading v10700 fixtures |
| K28 | Prototype Fortran/giza Kippenhahn viewer (additive) | done | Claude | `kipp.f90` (convection bands + epsnuc field + surface line via giza Fortran API), `convview.f90` (stdin REPL: xlim/ylim, xscale/yscale, xaxis, yaxis, color, save/quit), auto `/xw` vs `/png` |
| K29 | Always-on convection + fill-between polygons (conv + energy) | done | Claude | Convection drawn every render; greedy band tracing → one `giza_polygon` per region with per-type hatch; energy bands traced into solid polygons; shared `tracer_t` |
| K30 | Interactive mouse/keyboard zoom-pan (cursor mode) | done | Claude | `kipp_interact` blocking key-press loop; scroll/`z`/`Z` zoom about cursor, rubber-band rectangle zoom, `x`/`y` band-select, `h/j/k/l` pan, autoscale, PNG snapshots; world-space math with log-axis inverse transforms |
| K31 | Cache traced bands across renders (perf) | done | Claude | `c05dd81`; bands cached in `bandset_t` (data coords), redraw = transform + `giza_polygon`; epsnuc redraw ~0.23→~0.09 s |
| K32 | Clip extraction/emission to visible model range (perf) | done | Claude | `2555721`; `set_visible_range` bisects `xedge`, `draw_band` truncates; ~0.089→~0.034 s; fixes fill bleed via double `giza_set_viewport` |
| K33 | Pixel-check polygon vertices (decimation/LOD) | pending | — | Merge consecutive models within one device pixel column in `emit_band` before `giza_polygon`; ~10–40x fewer vertices at full view, no visual change. Never migrated/executed |
| K34 | Outline convection zones in type colour | done | Claude | `draw_convection` redraws each bandset with hollow fill after hatch, stroking region boundary in type colour |
| K35 | Flicker-free interactive redraws (frame buffering) | done | Claude | `kipp_render` wraps erase + `draw_scene` in `giza_begin_buffer`/`giza_end_buffer`; one `XCopyArea` per render |
| K36 | Exact region outlines + hatch aligned across bands | done | Claude | `151cf2e`; stroke cached boundary chains, emit all visible bands of a type as ONE keyholed polygon so hatch is continuous |
| K37 | Clamp emitted coords (deep-zoom hatch flood/vanish) | done | Claude | `8e5388a`; clamp every coord to ~1e3 window spans (`CLAMP_SPANS`) to avoid cairo 24.8 fixed-point overflow |
| K38 | Ghost frames on /xw (undefined pixmap after mid-frame resize) | done | Claude | `1b207e6` + giza `390cb7b`; giza `_xw_recreate_surface` repaints background, keppy erases page after viewport set. giza debug pin never on origin |
| K39 | Ghost convective hatching on /xw (hatch escaping polygon) | done | Claude | `23a4884` + `2055c66`; `band_y_visible` extends visible-range clipping to y so keyholed fill never bridges the window; giza hatch clip+stroke cannot leak on xlib backend |
| K40 | Extract Kippenhahn viewer into standalone `kippy` package | done | Claude | The split itself → this repo (task 1). giza carried as own submodule pinned to canonical upstream `3542293`; keppy depends on kippy via `[tool.uv.sources]` path |

## Decisions

Record key decisions here as they are made. Append only — do not delete previous entries.

| Date | Decision | Options Considered | Choice | Reasoning |
|------|----------|--------------------|--------|-----------|
| 2026-08-11 | Package split from keppy | keep in keppy vs standalone | Standalone `kippy` repo | Pip-installable viewer independent of keppy; vendors its own `.cnv` reader + giza submodule |
| 2026-08-11 | giza linkage | system `libgiza` vs vendored submodule | Vendored submodule pinned to canonical upstream `3542293` | Reproducible, self-contained build; giza compiled on first build |
| 2026-08-11 | Build system | make vs meson-python | meson-python/ninja | pip-installable, compiles Fortran + giza on install |
| 2026-08-11 | Python <-> Fortran boundary | FFI/f2py vs subprocess | subprocess launchers | Python drives compiled `convview`/`convdump` executables; no marshalling of allocatable derived types |
| 2026-08-12 | MESA support | .cnv only vs also MESA | Read MESA profile dirs too | Reader chosen automatically from the path; a profiles directory works anywhere a `.cnv` file did |
| 2026-08-21 | `.kipp` binary input | parse MESA text vs a packed binary stream | Read the raw `.kipp` float64 cell dump | One contiguous binary stream (cells grouped by model, one row per zone) loads far faster than re-parsing ascii profiles; column layout carried in a sidecar `.hdr` so the stream stays self-describing |
| 2026-08-21 | `.kipp` header lookup | fixed path vs search | `<file>.hdr` next to the data, else `<basename>.hdr` in cwd | Sidecar normally ships beside the data; cwd fallback covers a moved/streamed data file, and cwd is not re-checked when the file already lives there |
| 2026-08-27 | arbitrary colour columns | reuse signed-log energy levels vs a generic quantized field | Generic field quantized into fixed contour bins over the run min/max | Energy levels are signed log10 decades tuned to eps; a temperature/density column wants a continuous colorbar over its real range. Quantizing to `FIELD_NBINS` bins reuses the fast band tracer and, for the near-monotonic profile fields, compresses to ~bins-per-model entries |
| 2026-08-27 | `.kipp` field memory | store raw columns then quantize vs two streaming passes | Two streaming passes (range, then quantize) | Storing raw extra columns for a 12 GB file would add several GB of transient RSS; a second disk pass keeps only the compact step functions resident. Grouping is deterministic, so the second pass maps models back to records by stream order (pre-sort) |
| 2026-09-09 | MONASH `seq` reader scope | minimal geometry only vs curated fields + derived epsnuc | Curated colour fields + derived epsnuc | seq exposes T/rho/P/L and the 7 reaction rates cheaply via seqdump's exact formulas; the default `color epsnuc` is derived from `dL/dm` (approximate: dL carries gravothermal terms, not pure nuclear) so the seq reader behaves like the .cnv/.kipp/MESA ones out of the box |
| 2026-09-09 | shared record builders | duplicate in `monload` vs keep in `mesaload` (module cycle) vs new module | New `convbuild` module | `mesaload` dispatch must call `loadmon`, and `monload` must reuse the energy/field/zone builders; a shared `convbuild` (depends only on convdata/typedef) lets both use it without a `mesaload`<->`monload` cycle, and avoids duplicating the quantizers |

## Session State

_Updated at the end of each session or major phase._

**Last updated**: 2026-09-09
**Status (2026-09-09)**: Added the MONASH `seq` reader (task 10) and extracted
the shared record builders into a new `convbuild` module. `monload.f90` reads
the gfortran sequential-unformatted seq stream (layout per `seqdump.f90`) into
convtype records: mass shells from `omx`, convection zones from `kcvtn`, an
approximate `epsnuc` layer from `dL/dm`, and curated colour fields
(Temperature/Density/Pressure/Luminosity + 7 reaction rates) via two-pass
range-then-quantize. `convbuild` now owns `build_zones`/`build_energy`/
`build_field_layer`, the colour-field registry helpers, `alloc_empty_layers`
and the shared constants, so `mesaload` and `monload` share them without a
module cycle; `load_convection` dispatches seq paths (`seq.` prefix or `.seq`
suffix) to `loadmon`. Verified on a 40-record fixture (models 1-40, Temperature
8e3-2.3e7 K) with `color temperature`/`color epsnuc` rendering, and `.cnv`
(loadconv, 10363 models) + `convdump` show no regression. Task 11 (model-density
strip, ported from keppy `ModelsLegend`) is next, delegated to a codex-swarm.
HEAD will advance past `2fe08d3`.

**Status (2026-08-27)**: Added arbitrary column colour fields (task 9). Any
non-structural source column is registered as a generic colour field in a shared
`convdata` registry (`field_names/vmin/vmax/log` + a per-record `fld()` of
`fieldlayer` step functions). The renderer resolves `color <column>` (with a few
aliases: `temperature`/`density`/`luminosity`/`pressure`) against it, traces the
quantized bins with the existing band tracer, and draws nested viridis contours
plus a value-labelled colorbar reflecting the min/max across the run (auto log
when positive and spanning >2 decades). The `.kipp` reader streams twice (range
then quantize) so only compact step functions stay resident; the MESA-dir reader
registers a curated column set (`logT`/`logRho`/`logL`/`luminosity`/`logP`/
`pressure`/`opacity`/`entropy`/`velocity`) read alongside the structural columns.
New REPL commands: `color <column>` and `fields` (lists selectors + ranges).

Verified: real `~/projects/blueloops/.../LOGS_TPAGB/profile.kipp` (12 GB, first
27 models 7084-7110 via early-stop range) registers `zone/dm_g/T_K/rho_gcc/
L_erg_s`, `T_K` log 3.5e3-2.7e8 K compressing to ~27 step entries per 3251-zone
model, `L_erg_s` correctly linear (negative values); synthetic 6-model fixture
renders temperature/density/aliases, energy path (`epsnuc`) unregressed, axis
rebuild (radius / model) retraces field bands. Not yet run: full 12 GB render
(two passes ~2x the ~5.6 s load). Pre-existing WIP (`monload.f90` MONASH stub,
untracked; OpenMP per-profile loop) still in tree. HEAD at `044e2cb`.
Next candidate work: PyPI release (task 7); no open blockers.
