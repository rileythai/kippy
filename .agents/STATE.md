# State

Updated: 2026-10-30

## Target

kippy v0.1.0 is on PyPI. Next: the cursor `v` cell readout (task 30) on local branch `cursor-cell`.

## Open tasks

| ID | Title | Next step |
|----|-------|-----------|
| 30 | Cursor key `v` prints the cell under the cursor | keep: implement on `cursor-cell`, check against a `.kipp` fixture with `key v x y` |

## Waiting on the user

- none

## Live runs

- none

## Next action

Implement task 30 on `cursor-cell`. Rebuild with `mise run install` (editable; Fortran edits then rebuild on import), check with `mise run smoke`.
