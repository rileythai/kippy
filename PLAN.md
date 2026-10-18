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
| 7 | Publish to PyPI | in progress | Claude | Package name `kippy` v0.1.0 (name free on PyPI 2026-10-06); sdist verified to include the giza submodule + its `configure`. Licence done (task 16), relicence confirmed by Alexander Heger. Remote `git@github.com:rileythai/kippy`. Done: `project.urls`/classifiers/keywords (`30cc8b7`); `.gitattributes` export-ignore drops CLAUDE.md/PLAN.md/.claude from the sdist (`f8e9174`); `wheels.yml` builds sdist + cibuildwheel v4.3.0 manylinux_2_28 x86_64/aarch64 wheels (cp310-cp315, wheel is cp-tagged because meson-python counts platlib files as extension modules) and publishes on GitHub release via trusted publishing (`fc941d2`); `docs.yml` deploys zensical to GH Pages (`1994693`). Verified locally: x86_64 wheel built in docker, auditwheel grafts cairo/xcb/freetype/fontconfig/gfortran/gomp into `kippy.libs`, installs in clean `python:3.12-slim` and renders seq fixture PNG+PDF with only libx11-6/libxext6/libxrender1/libexpat1 present; all six x86_64 wheels (cp310-cp315) install into separate fresh uv venvs and render the seq fixture headless; `twine check --strict` passes. Remaining (user): PyPI pending publisher (workflow `wheels.yml`, env `pypi`), Pages source = GitHub Actions + custom domain + DNS CNAME, first CI run (aarch64 unverified), cut release. Linux only: `.so.2` + `LD_LIBRARY_PATH` assumptions block macOS |
| 8 | Raw `.kipp` binary stream reader (`loadkipp` in `mesaload.f90`) | done | Claude | dispatch on `.kipp` suffix; layout from a sidecar `<file>.hdr` (found next to the file, else basename in cwd); streams the float64 cell dump in chunks (2.7 GB class, ~940 MB RSS, ~5.6 s), groups cells by monotonic `model_number`, reverses surface->center to center->surface, reuses `build_zones`/`build_energy`; single net `eps` column drives the nuc layer, neu layer empty |
| 9 | Arbitrary column colour fields (`color <column>`) | done | Claude | any non-structural source column is registered as a generic colour field (`convdata` `fieldlayer` + shared `field_names/vmin/vmax/log` registry); values quantized into `FIELD_NBINS=24` contour bins over the min/max across the run (auto log when positive and >2 decades), traced with the existing band tracer, drawn as nested viridis contours with a value-labelled colorbar. `.kipp` reader does two streaming passes (range then quantize) so only compact step functions stay resident; MESA-dir reader registers a curated column set. REPL: `color <column>` + `fields` list. Verified on real `profile.kipp` (T_K log 3.5e3-2.7e8 K, ~27 entries/model) and a synthetic fixture render |
| 10 | MONASH `seq` file reader (`monload.f90`) + shared `convbuild` module | done | Claude+codex-swarm | seq is a gfortran sequential-unformatted file, one record per model, layout per `seqdump.f90`; mass shells from `omx` (`m=mass*(1-omx)^3`, already center->surface, no reversal), convection from `kcvtn`, approximate `epsnuc` from `dL/dm`, curated colour fields (Temperature/Density/Pressure/Luminosity + 7 reaction rates) reconstructed with seqdump formulas via two-pass range-then-quantize; reader-agnostic builders extracted from `mesaload` into a new `convbuild` module so `mesaload`+`monload` share them without a module cycle; dispatched in `load_convection` on a `seq.` prefix or `.seq` suffix. Verified on a 40-record fixture (models 1-40, T range 8e3-2.3e7 K) + `.cnv`/`convdump` no regression |
| 12 | Selectable colour-field colormap (`cmap`) | done | Claude | `colormap` in `kipp.f90` dispatches on `st%cmap` for both the field fill (`draw_field`) and its colorbar (`draw_field_colorbar`); default `teal` fades white -> teal-blue (0.09,0.42,0.67) like the epsnuc gain ramp, with `viridis` (perceptual approx, now split into `cmap_viridis`), `blue` (exact epsnuc gain ramp), and `gray`; colorbar tick text now picks black/white by strip luminance so it stays legible on the light-at-low teal ramp; REPL `cmap teal\|viridis\|blue\|gray` validated in `convview.f90`. Verified rendering all four on the 40-record seq fixture (log Temperature 3.91-7.37) |
| 14 | Zensical documentation site | done | Claude+codex-swarm | `cfce4f0`; `zensical.toml` + `docs/` (index, install, usage, formats, api), every REPL command / cursor key / reader claim checked against the Fortran; `docs` dependency group gated `python_version >= '3.11'` (zensical floor); local build only, no deploy until a remote exists. Found K27 overclaims: the Fortran `.cnv` reader handles record versions >= 10600 only |
| 11 | Model-density strip (port keppy `ModelsLegend`) | done | Claude+codex-swarm | `draw_models` in `kipp.f90` draws one tick per visible model in the top margin at its x, tick height/width/colour scaled by the model-number decade magnitude (`mag`=trailing zeroes, `half`=intervening multiple of five, `lev=2*mag+half`, colour cycles black/red/green/blue by `mag`); its own top-margin viewport is restored to the plot viewport/window afterward so the cursor keeps mapping pixels to data; `models on\|off` REPL toggle in `convview.f90`; on by default. Verified by rendering the seq fixture (red taller ticks at models 10/20/30/40) |
| 13 | PDF export (`S` key, `save <file>.pdf`) | done | Claude | `kipp_save` dispatches on the `.pdf` suffix to giza `/pdf` at a fixed one-column page (`PDF_WIDTH`=3.5 in, height = width/phi, 252x156 pt); giza sizes text as a fraction of page height, so a module `chs` (`PDF_CHS`=2, ~8.4 pt labels) scales every character height during the PDF render and the field-colorbar end-tick inset; `S` in cursor mode writes a numbered `<prefix>_NNNN.pdf` sharing the `s` counter. Verified on the seq fixture (Temperature + epsnuc) via REPL `save` and scripted `key S`; PNG path unchanged (chs=1). Hatch spacing/width (8 / 1.5 device units) are hard-coded in giza so they render as 8 pt / 1.5 pt in the PDF |
| 15 | Copy PNG to clipboard (`p` key) | done | Claude+codex-swarm | `p` in cursor mode renders via `kipp_save` to `/tmp/kippy-<pid>-clip.png`, pipes it to `wl-copy --type image/png`, falls back to `osascript` (JXA writing the PNG to `NSPasteboard`, since `pbcopy` only takes text; added 2026-10-15, checked on Linux with fake tools by `.scratch/verify_clip_osascript.sh`, unverified on a Mac) and then `xclip -selection clipboard`, then deletes the temp file; does not bump the `s`/`S` counter. The copy's stdout/stderr go to /dev/null because the forked clipboard owner dies with a captured pipe and the clipboard reverts. Verified with `.scratch/verify_clip.sh` (`wl-paste` returns an 800x600 PNG) and the no-display failure message |
| 16 | LGPLv3 licensing + per-file headers + strip foreign-project references | done | Claude | `3b10ba9` + `abcfc4c`; LGPL-3.0-or-later, root `COPYING`/`COPYING.LESSER` (canonical FSF texts from giza), PEP 639 `license`/`license-files` incl. giza's (meson-python floor 0.18.0, first with pyproject-metadata 0.9); FSF notice headers ("the kippy authors (see AUTHORS)") on all 9 `.f90`, 3 `.py`, 2 `meson.build`; keppy / Python `ConvData` / `convdata.py` / "vendored reader" references removed from comments, docs and the pre-10600 error message. Verified: wheel builds, METADATA `License-Expression: LGPL-3.0-or-later` + 4 license files, `convdump` runs on the seq fixture |
| 17 | Format reference pages for `.cnv` and `.kipp` | done | Claude | New `docs/cnvfiles.md` (big-endian sequential records, full 10600/10700 field layout, how kippy reads models/coords/zones/energy levels and floors) and a `File format` section in `docs/kippfiles.md` (little-endian float64 rows, surface->centre order, header grammar, required column aliases, MESA mixing codes, eps binning, colour fields); nested in the nav under `Input formats` (Overview / kipp Files / cnv Files) + links from `formats.md`. Layouts validated by `.scratch/check_cnv_layout.py` (all 10363 v10700 records of keppy `convdata.cnv` match their record markers byte for byte) and `.scratch/check_kipp_layout.py` (a real float64 `profile.kipp`). The 10600 layout is documented from the reader only (no fixture) |
| 18 | macOS build + wheels (Apple Silicon and Intel) | in progress | Claude | Branch `macos` (`137b861`, `fc7519e`, `e0c1d4a`). `build_giza.py` stages `libgiza.2.dylib` + `libgiza.dylib` on darwin (libtool names) and resets the install name to `@rpath/libgiza.2.dylib` (libtool bakes `<libdir>/...`); `meson.build` picks lib names and `@loader_path`/`$ORIGIN` per platform, probes OpenMP with gfortran (Apple clang has none). cibuildwheel macOS wheels on `macos-15` + `macos-15-intel`, `MACOSX_DEPLOYMENT_TARGET=15.0`, `tools/smoke_test.py` renders a synthetic `.kipp` headless, workflow step fails if `otool -L` shows a Homebrew path after delocate. Verified on Linux only: fresh meson build, install plan and wheel contents unchanged, smoke test passes. First macOS CI run (arm64) failed linking giza's `libgiza-osxcocoa-main` (`giza_main` undefined): giza's libtool 2.4.6 only adds `-undefined suppress` on darwin when `MACOSX_DEPLOYMENT_TARGET` is unset or 10.x, and cibuildwheel always sets it; fixed in `3c02598` by making only `libgiza.la giza-fortran.lo` in `giza-build/src` (also skips libpgplot/libcpgplot/tests). Second run: arm64 wheel built, delocated, installed and `convview` ran (so `@rpath` load and arm64 signing work), but `save` truncated the macOS temp path at 64 chars (convview `a1` and `kipp_save` `pfx` were len=64); widened both to 256 (giza's `GIZA_MAX_DEVSTRING`), verified on Linux with a 108-char TMPDIR. Third run: arm64 wheel built and passed the smoke test, but the `otool -L` check step failed before checking anything because `unzip -d unpacked/<whl>` only creates the last path component; added `mkdir unpacked` (reproduced with Info-ZIP on Linux). The failed step also skipped the artifact upload. macOS user docs: `install.md` `macOS` section (15.0 wheel floor, XQuartz via `brew install --cask xquartz`, log out and in if `DISPLAY` is empty, headless fallback, no `p` clipboard), `xcode-select --install` in the source requirements, macOS notes in usage/api/README, and the broken headless-mode sentence in `usage.md` fixed; zensical build clean. Remaining: rerun CI on macOS (no local Mac); interactive `/xw` via XQuartz confirmed working by the user on a Mac (2026-10-15); giza's native `/osxcocoa` driver not wired (needs convview main restructured) |
| 19 | Click the plot window to enter cursor mode, Ctrl+C to leave | in progress | Claude | `a4027ab`; giza `89417cf` on branch `wait-fd-or-click` of the `rileythai/giza` fork (based on the pinned `3542293`, not the fork main) adds `giza_wait_fd_or_click(fd)`: polls fd and the X connection, redraws on expose, returns 1 on a left/middle/right click (keys and scroll ignored). `kipp_wait_click` calls it at the `kipp>` prompt only when stdin is a tty and `KIPP_SCRIPT` is unset (gfortran buffers piped stdin, so poll could miss lines). Ctrl+C in the window is byte 3 from `XLookupString` (checked), now leaves cursor mode and cancels bands like `q`/Esc. Verified: `.scratch/wait_fd_test.c` (returns 0 with data on the fd, blocks without), `.scratch/ctrlc_action.f90`, REPL under a pty headless and scripted. User confirmed click-to-enter on Linux (2026-10-17), Mac untested. The user merged the fork main (giza 2.0.2) into `wait-fd-or-click` (`6559d51`); `f42efa3` leaves ConfigureNotify queued for its resize handling; kippy `4aae704`. giza 2.0.2 bumps libtool version-info to 3:0:1 (real file `libgiza.so.2.1.0`), so `71e2487` stages libgiza under its soname `libgiza.so.2`. Existing editable build dirs need their old `giza-build` moved out and `meson setup --reconfigure` (meson records the resolved `-lgiza` file as a dependency); done for `build/cp312` and `build/cp314`, renders unchanged. Left: push the giza branch to the fork before CI; Closing the window quits convview (user choice): giza `b93c191` records WM_DELETE_WINDOW per device (the cursor loop still returns `q` for it) and `giza_wait_fd_or_click` returns -1 from then on, matching expose, click and close with one `XCheckIfEvent` predicate; kippy `6948b6f` `kipp_wait_input` exits the REPL on -1. Verified with `.scratch/close_test.c` (WM_DELETE_WINDOW sent to its own uniquely named window: prompt path -1, cursor path `q` then -1); not run end to end on convview because its window name is fixed and could match an open one; user to check by hand. Found: the window could not be closed because giza 1.5 waits with `XWindowEvent`, which never returns the WM_DELETE_WINDOW ClientMessage (`.scratch/clientmsg_test.c`); giza 2.0.2 uses `XIfEvent` |
| 20 | Resolution grid overlay (`grid on\|off`, `g` key) | done | Claude | Branch `grid`. `draw_grid` in `kipp.f90` (after the convection hatch, under the surface line): per visible model one zig-zag `giza_line` through its stored cell faces (`xmcoord`/`rncoord`, bisected to the visible y range) plus a vertical line at each strip edge (`xedge`, the midpoints the bands already use), spanning the inner boundary to the taller neighbour's surface. Strips under a device pixel (`giza_get_viewport` in pixels) merge into the next drawn one and faces within a pixel of the last kept are skipped. `mesaload` exports `cnv_loaded`; with it set, `grid on` prints once that a KEPLER `.cnv` stores a reduced grid. Full grid (`ncoord = nz`): `.kipp`, MESA dirs, seq, atse-written `.cnv`; keppy `convdata.cnv` holds 85-332 points per model with median neighbouring dm ratio ~2.3 (max 1e9), so not every KEPLER zone (inferred from the file, `.scratch/cnv_coord_usage.py`). Verified: `.scratch/verify_grid.sh` renders a 6-model uneven fixture headless and every face and strip edge lands within 0.5 px of the expected pixel in a full and a zoomed view (a sub-pixel face pair draws once), `key g` passes the same check; atse agb_d075 (8475 models, ~1000-1200 zones) full-view render ~0.06 s off vs ~0.23 s on (`.scratch/time_grid.sh`, median of 3), zoomed view reads as a grid |
| 21 | Solar-unit labels, matplotlib-style colorbars, matplotlib colormaps, numbered `color`/`cmap` | done | Claude | Branch `grid`. Axis labels use giza's TeX escapes: `M_\odot`/`R_\odot` (`\odot` is a giza vector marker, so no font glyph is needed; Nimbus Roman, giza's default `Times`, has no U+2609), energy bar title `log \ge_{nuc} (erg g^{-1} s^{-1})` (`\ge_{\gn}` for neu). Colorbars: framed strip at page x 0.86-0.88 (plot right edge 0.89 -> 0.84 when coloured), horizontal tick labels outside the strip at `CB_TICK`=0.8 chs (was 0.65, rotated inside the strip), title up the outer side at `CB_TITLE`=3.5 tick heights via `giza_annotate`. Field bar: giza's round ticks (`giza_box` 'CMTIV' on the bar's value window) replace 6 labels at even fractions; linear fields with max |v| >= 1e4 or < 1e-2 (the old `fmt_field_value` thresholds) move 10^p into the title so labels stay short; '_' in column names shown as spaces (giza parses '_' as a subscript and has no escape); a constant field gets a framed strip with no ticks. Energy bar: level beside each cell centre (a level is nint(log10|eps|)), half-cell gap replaces '...', GAIN/LOSS at the ends; gain/loss shading unchanged (user choice). Colormaps: new `cmaps.f90` holds teal/blue/gray (analytic) plus viridis plasma inferno magma cividis Greys Blues Greens Reds Purples Oranges coolwarm RdBu turbo sampled from matplotlib 3.10.8 at 33 points, linear between (max 6.04/255 vs matplotlib over 1001 points, turbo worst; generator `.scratch/cbar/gen_cmaps.py`), `_r` reverses; viridis was an 8-point approx (~17/255). REPL: bare `cmap`/`color` print numbered lists, `cmap <n>[_r]` and `color <n>` select by number (`fields` numbered too). Verified: headless PNG+PDF renders of keppy `convdata.cnv` (epsnuc, mass and radius) and the seq fixture (log T in teal/viridis/coolwarm_r, log L turbo, linear C rate with 10^-15 title, constant field, epsnuc), list output and bad-entry messages |

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
| 2026-09-09 | colour-field colormap default | keep viridis vs a white->teal-blue ramp | Default `teal` (white->teal-blue 0.09,0.42,0.67), selectable via `cmap` | The single `colormap` choke point already drives both the field fill and its colorbar, so one dispatch on `st%cmap` switches both; default matches the epsnuc gain-ramp look expected for arbitrary columns. Alternatives (viridis/blue/gray) kept cheap and analytic; colorbar tick text switched to luminance-based black/white so labels stay legible when the ramp is light at the low end (teal), not just dark (viridis) |
| 2026-09-09 | shared record builders | duplicate in `monload` vs keep in `mesaload` (module cycle) vs new module | New `convbuild` module | `mesaload` dispatch must call `loadmon`, and `monload` must reuse the energy/field/zone builders; a shared `convbuild` (depends only on convdata/typedef) lets both use it without a `mesaload`<->`monload` cycle, and avoids duplicating the quantizers |
| 2026-10-06 | PDF page size | match the /xw window vs fixed publication size | Fixed one-column 3.5 in x 3.5/phi in, text scaled by 2 | A fixed size drops straight into a journal column; giza ties text to page height so the scale keeps ~8 pt labels, and the existing normalized margins still fit at that size |
| 2026-10-06 | docs toolchain | mkdocs-material vs zensical; mkdocstrings vs hand-written api | Zensical, hand-written `api.md`, local build only | User choice for PyPI prep; five public functions do not need autodoc; no git remote yet so CI/Pages deploy deferred |
| 2026-10-06 | licence | LGPL-3.0-only vs -or-later; SPDX vs full FSF headers | LGPL-3.0-or-later, full FSF notice, copyright "the kippy authors" | User choice; matches giza (LGPLv3), which the wheel bundles |
| 2026-10-06 | reader code relicence | keep unlicensed vs relicence under LGPL | Relicence under LGPL-3.0-or-later | Alexander Heger (original author of the keppy-era reader/viewer code) confirmed the code may be LGPLv3 licensed |
| 2026-10-06 | docs hosting | readthedocs vs GH Pages | GH Pages via Actions, custom domain `kippy.rileythai.com` | User choice; zensical builds a static site, Pages deploy needs no extra service |
| 2026-10-14 | macOS support scope | source build only vs also wheels | Source build + cibuildwheel macOS wheels (arm64, x86_64) | User choice |
| 2026-10-14 | macOS wheel minimum OS | 15.0 on macos-15 runners vs 14.0 on deprecated macos-14 vs deps from source | 15.0 | User choice; delocate bundles Homebrew bottles, which target the runner OS, so the wheel cannot claim older. Older macOS builds from the sdist |
| 2026-10-14 | macOS interactive window | XQuartz `/xw` vs giza native `/osxcocoa` | XQuartz for now | User choice; `/osxcocoa` needs convview's main renamed to `giza_main` and linked with `libgiza-osxcocoa-main` |
| 2026-10-17 | resolution grid overlay | time lines at strip edges vs model times; draw all vs skip sub-pixel lines vs only when zoomed; KEPLER .cnv draw with note vs refuse; REPL only vs also `g` key | strip edges, skip lines under 1 device pixel, draw KEPLER .cnv with a one-time note, REPL + `g` | User choice; strip edges match where the existing bands change, pixel skipping keeps full-view cost bounded by the window size |
| 2026-10-17 | click to enter cursor mode | patch giza vs splash-style plain read vs interposing XOpenDisplay | patch giza on the `rileythai/giza` fork, `.gitmodules` url https so CI and anonymous clones work | User choice; splash does not do this (its menu is a plain `read(*)`), giza keeps its X display private |
| 2026-10-18 | colorbar and colormap overhaul | colormap set; anchors 9/17/33/256; log field ticks plain vs 10^x; shared gain/loss scale vs per side | all of perceptual, single-hue, diverging, turbo + `_r`; 33 anchors; log title with plain ticks; gain/loss shading unchanged; numbered `cmap`/`color` lists | User choice; 33 anchors keep every map within 6/255 of matplotlib at 33x3 numbers per map; solar symbol via giza's `\odot` marker so it renders without a font glyph |

## Session State

_Updated at the end of each session or major phase._

**Last updated**: 2026-10-18
**Status (2026-10-18)**: Task 21 done on branch `grid`: solar-unit labels, matplotlib-style colorbars, 14 matplotlib colormaps, numbered `cmap`/`color`. Verified headless only (PNG and PDF); not yet looked at in an interactive `/xw` window. Colorbar layout numbers (plot edge 0.84, strip 0.86-0.88, `CB_TICK`, `CB_TITLE`) are open to tuning.
**Status (2026-10-17b)**: Task 20 (resolution grid overlay) done on branch `grid` off `main`, verified headless on a synthetic fixture and a real atse `.kipp`; not yet tried in an interactive window. Left: user to try `g` on `/xw` and merge.

**Status (2026-10-17)**: Task 19 on branch `cursor-click` (off `main`): click the plot window at the prompt to enter cursor mode (user confirmed on Linux), Ctrl+C in the window to leave, closing the window quits (scratch-tested, user to check by hand). giza on the fork at 2.0.2; staging keys on the soname. Left: push giza `wait-fd-or-click` (`b93c191`) to the fork, check on a Mac. Colorbar question: every local `.cnv` (KEPLER `convdata.cnv`, atse runs) has equal gain and loss floors, so the floor pairing does not change their labels; the GAIN and LOSS halves look different because `draw_energy` and `draw_colorbar` shade each side by its own deepest level (e.g. atse agb_d075: gain 6, loss 2); awaiting the user on whether to shade both sides on one scale.

**Status (2026-10-15)**: macOS build + wheels (task 18) on branch `macos`,
verified on Linux only. Next: push the branch and run `wheels.yml` (workflow
dispatch on `macos` or a PR) to build and smoke-test on `macos-15` and
`macos-15-intel`; the first arm64 run failed in giza's Cocoa helper lib (fixed in
`3c02598`, see task 18); the second hit a 64-char save path limit (fixed, see
task 18); the third built the wheel but the Homebrew-path check failed on a
missing `unpacked/` dir (fixed, see task 18), so that check has not run yet;
rerun and fix whatever else turns up, then merge.
Added macOS usage docs (XQuartz setup, headless fallback, clipboard
limit); the user confirmed the XQuartz window works on a Mac. Added an `osascript`
clipboard fallback for the `p` key on macOS, still to be checked on a Mac.

**Status (2026-10-08)**: Added `.cnv` and `.kipp` format reference docs (task 17),
validated against real files. Open questions found while writing: keppy's Python
reader groups the 12 `.cnv` level floors as (2, nlayer) while `kipp.f90` reads
them as per-layer (gain, loss) pairs; the docs describe kippy's reading. The
`.kipp` `dtype` header line is ignored, so float32 streams (as in the blueloops
runs) do not load. Task 7 PyPI/Pages setup still needs the user. Docs nav now nests the two format pages under
`Input formats`; `navigation.indexes` was not used because it needs a section
`index.md`.

**Status (2026-10-06e)**: Release prep for task 7 done locally: metadata/urls,
sdist exclusions, wheel + docs CI, README synced with the docs index (badges,
demo gif via raw.githubusercontent). Local cibuildwheel x86_64 wheel verified
end to end in a clean container. Demo gif shrunk 32 MB -> 7.8 MB (`a9ea452`:
full 807x614 resolution, 12 fps, duplicate frames dropped, global 128-colour
palette, no dither; 32 colours shifted hatch/tick hues so was rejected); the
old 32 MB blob stays in git history. The gif is also export-ignored from the
sdist (now 1.3 MB). Docs CI pins `astral-sh/setup-uv@v10.2.0`: upstream
publishes no floating major tags after v7, so `@v10` failed to resolve.
Docs callouts use `!!! tip` admonitions; zensical does not render GitHub
`> [!TIP]` alerts.
Open: the PyPI/Pages setup steps in task 7 need the user.

**Status (2026-10-06d)**: Licensed kippy LGPL-3.0-or-later (task 16): licence
texts, PEP 639 metadata, per-file FSF headers, and removed leftover keppy /
Python-reader references. giza is LGPLv3 per its docs (GPLv3 file headers plus
`COPYING.LESSER`, giza `e8db6d3`). Alexander Heger has since confirmed the
relicence of the reader code carried over from keppy (keppy has no licence).
Next: task 7 metadata (`project.urls`, classifiers), git remote, cibuildwheel.

**Status (2026-10-06c)**: Added clipboard PNG copy (task 15) via a one-worker
codex-swarm, then simplified its temp-dir handling and fixed the clipboard
owner dying on a captured stdout pipe. Verified on Wayland (wl-copy); the xclip
fallback is untested on a real X11 session.

**Status (2026-10-06b)**: Added the Zensical docs site (task 14) via codex-swarm, with `mise run docs:serve` / `docs:build` tasks in `mise.toml`,
then fact-checked every page against the sources. Build with
`uvx --from 'zensical>=0.0.68' zensical build` (output `site/`, ignored).
Remaining PyPI (task 7) gaps: no LICENSE file or `license` field, no
`project.urls`/classifiers, no git remote, no release CI.

**Status (2026-10-06)**: Added PDF export (task 13). Shift+S in cursor mode and
`save <file>.pdf` in the REPL write a fixed one-column golden-ratio PDF
(3.5 in wide) with character heights scaled by `PDF_CHS` so labels stay ~8 pt.
Verified on the seq fixture; PNG output unchanged. Known limit: giza hard-codes
hatch spacing/line width in device units, so PDF hatching is bolder than on
screen (would need a giza patch).

**Status (2026-09-09c)**: Added a selectable colour-field colormap (task 12).
`colormap` in `kipp.f90` now dispatches on `st%cmap` (the viridis table moved to
a `cmap_viridis` helper), so both the field fill and its colorbar switch
together. The default `teal` fades white -> teal-blue (0.09,0.42,0.67) like the
epsnuc gain ramp; `viridis`, `blue` (the exact epsnuc gain ramp) and `gray` are
the alternatives. `draw_field_colorbar` now chooses tick-text colour from the
strip luminance under each tick so labels stay legible when the ramp is light at
the low end. New REPL command `cmap teal|viridis|blue|gray` (validated in
`convview.f90`). Verified by rendering all four maps on the 40-record seq fixture
(`.scratch/seq.small`, log Temperature 3.91-7.37). Note: `color <name>` still
resolves aliases (`temperature`) only against the KEPLER/MESA/.kipp column names,
not the seq reader's capitalized `Temperature`; that selector-alias gap is
pre-existing and unrelated to colormaps.

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
(loadconv, 10363 models) + `convdump` show no regression.

Also added the model-density strip (task 11): `draw_models` in `kipp.f90` draws
one tick per visible model in the top margin, tick height/width/colour scaled by
the model-number decade magnitude (round numbers stand out, clustering reads as
density); `models on|off` REPL toggle, on by default. Verified visually on the
seq fixture (taller red ticks at models 10/20/30/40 over the Kippenhahn diagram).
Both tasks committed on top of `2fe08d3`.

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
