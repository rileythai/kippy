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

## Session State

_Updated at the end of each session or major phase._

**Last updated**: 2026-08-21
**Status (2026-08-21)**: Added a raw `.kipp` binary-stream reader (`loadkipp` in
`mesaload.f90`, task 8). `load_convection` now dispatches on a `.kipp` suffix
before the MESA-dir / `.cnv` checks; the column layout is read from a sidecar
`<file>.hdr` (next to the file, else `<basename>.hdr` in cwd). Verified on a
2.7 GB real file (9565 models, 7084-16648, ~5.6 s, ~940 MB RSS; renders) and on a
synthetic 3-model fixture (zone compression, coordinate reversal, cwd fallback,
missing-header error all correct). Working tree still carries pre-existing WIP
(mesaload reformat + OpenMP per-profile loop in `meson.build`/`convview.f90`/
`kipp.f90`) intermixed with the new reader; not yet committed. HEAD at `7971707`.
Next candidate work: commit tasks (WIP + `.kipp` reader), then PyPI release
(task 7); no open blockers.
