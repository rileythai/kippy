# Backlog

- K33: merge consecutive models within one device pixel column in `emit_band` before `giza_polygon`; ~10-40x fewer vertices at full view, no visual change. Never started.
- `.kipp` float32 streams do not load: the sidecar `dtype` line is skipped (`mesaload.f90` header parsers), so the reader always assumes float64. The blueloops runs write float32.
- `.cnv` level floors: keppy's Python reader groups the 12 floors as (2, nlayer), `kipp.f90` reads them as per-layer (gain, loss) pairs; the docs describe kippy's reading. `toffset` (v10700+) is read but unused.
- macOS and X11 checks: giza's native `/osxcocoa` driver is not wired (needs convview's main renamed to `giza_main` and linked with `libgiza-osxcocoa-main`); the `osascript` clipboard fallback and click-to-enter are untested on a Mac; the `xclip` fallback is untested on a real X11 session.
