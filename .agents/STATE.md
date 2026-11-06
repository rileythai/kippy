# State

Updated: 2026-11-06

## Target

Refactor `kipp.f90` into documented modules on branch `refactor` (task 33), behind the golden-image harness (task 32, done). `mesaload.f90` follows (task 34).

## Open tasks

| ID | Title | Next step |
|----|-------|-----------|
| 33 | Split kipp.f90 into modules | keep: settle the open doc-tooling choices in the task file, then move `bands` first |
| 34 | Refactor mesaload.f90 | keep: starts after 33 |

## Waiting on the user

- task 33 open choices: ticks/colorbars module, findent vs indented `!!` lines, FORD/findent install route

## Live runs

- none

## Next action

After each move: `uv run tools/golden.py check .scratch/32/ref ~/projects/keppy/convdata.cnv seq.xxx` must print `golden check ok`. Rebuild with `mise run install`; `mise run smoke` for a quick check.
