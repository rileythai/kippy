# State

Updated: 2026-10-30

## Target

kippy v0.1.0 is on PyPI. Cursor `v` cell readout (task 30) is done on local branch `cursor-cell`, waiting for the user to try it and merge.

## Open tasks

| ID | Title | Next step |
|----|-------|-----------|
| - | none | - |

## Waiting on the user

- try `v` in a live /xw window, then merge `cursor-cell` into main
- range separator for negative bins (`-7.335E-01 - -6.954E-01`): keep ` - ` or switch to ` .. ` like `fields`

## Live runs

- none

## Next action

Rebuild with `mise run install` (editable; Fortran edits then rebuild on import), check with `mise run smoke`. No open tasks: pick the next from `.agents/tasks/backlog.md` with the user.
