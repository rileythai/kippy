# State

Updated: 2026-11-26

## Target

Refactor `kipp.f90` into documented modules on branch `refactor` (task 33), behind the golden-image harness (task 32, done). `mesaload.f90` follows (task 34). Fortran unit tests under `tests/fortran` grow alongside (task 35). Every source has FORD docstrings (task 36, done), restyled to the terse doc style (task 37, done); its open doc items are sourced (task 38, done).

## Open tasks

| ID | Title | Next step |
|----|-------|-----------|
| 33 | Split kipp.f90 into modules | keep: moves, kipp docstrings (a0bee2a) and docs linking (4c08644, d273379) done; the user decides close or keep for the explicit-arguments pass |
| 34 | Refactor mesaload.f90 | keep: starts after 33 |
| 35 | Fortran unit tests | keep: `units` (efeb844) and `bands` tests done; next the readers |

## Waiting on the user

- task 33: kept open for the explicit-arguments pass (readability, heavy refactor; user, 2026-11-26).

## Live runs

- none

## Next action

Settle task 33 with the user. The docs CI job has not yet run with the FORD step (runs on the next push). Checks after any Fortran change: `uv run tools/golden.py check .scratch/32/ref6 ~/projects/keppy/convdata.cnv seq.xxx tests/profiles_fixture/profile.cnv tests/profiles_fixture/profile.kipp tests/profiles_fixture` (about 1 min) must print `golden check ok`, `mise run test` must pass, and `mise run doccheck src/kippy/fortran/*.f90` must pass (all 18 files pass). Rebuild with `mise run install`; `mise run smoke` for a quick check. `mise run docs:build` now runs FORD into `docs/fortran` first.
