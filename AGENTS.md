# AGENTS.md

## Project

**kippy** — A native Fortran/giza Kippenhahn viewer for KEPLER `.cnv` convection
output (and MESA profile directories), split out of
[keppy](https://github.com/rileythai/keppy) as a standalone, pip-installable
package.

The plotting core is compiled Fortran (`kipp.f90`) linked against the bundled
[giza](https://github.com/danieljprice/giza) plotting library (a git submodule).
Python drives the compiled executables as subprocesses. Key areas:

- **Reader**: `.cnv` binary reader (`convload.f90`/`convdata.f90`/`typedef.f90`) plus a MESA profiles reader (`mesaload.f90`)
- **Viewer core**: `kipp.f90` band tracer + giza rendering; `convview.f90` stdin REPL
- **Build**: meson-python compiles the Fortran and builds the giza submodule on first build (`tools/build_giza.py`)
- **Python API**: `kippy.view`/`kippy.dump` launchers + `convview`/`convdump` console scripts (`src/kippy/_cli.py`)

Current state: @.agents/STATE.md

## Conventions

### Building

The build uses meson / ninja via meson-python and compiles giza on first build,
so a Fortran toolchain and giza's backends are required:

- `gfortran`, `meson`, `ninja`
- `cairo`, `libx11`, `freetype2` development packages (giza backends)

```bash
# clone with submodules (or: git submodule update --init --recursive)
git clone --recurse-submodules <url> kippy

# editable install into a venv
uv pip install -e .        # or: pip install .
```

`libgiza.so.2` installs under `kippy/bin`; the python launchers inject that dir
on `LD_LIBRARY_PATH` because meson-python leaves the giza custom-target rpath
unpatched. Do not remove that injection without an equivalent rpath fix.
On macOS the library is `libgiza.2.dylib`; `tools/build_giza.py` resets its
install name to `@rpath/...` so the `@loader_path` rpath resolves it.

Docs: `mise run docs:serve` previews the zensical site, `mise run docs:build` builds it into `site/`.

## Agent context

`.agents/` belongs to the agent. The rest of the repo belongs to the user.

- `.agents/STATE.md` loads every session. Rewrite it in place, never append. Cap: 80 lines and 8 KB.
- `.agents/tasks/<id>.md`, one file per task. Open only the one you work on. A new id is one more than the highest number, like 30. `K##` ids are inherited from keppy and keep their names.
- `.agents/tasks/backlog.md` holds ideas that are not tasks yet. It never loads.
- `.agents/notes/` holds findings that outlive a task.

### Tasks

- The `status:` line is `open`, `done: <reason>`, `dropped: <reason>` or `superseded-by <id>: <reason>`.
- At most 5 open tasks. Before opening another, close, supersede or move one to the backlog with the user.
- The session-start hook flags tasks with no commit or edit to their file in 14 days. Ask the user to close or keep each one.
- Record a user decision in its task file when it is made, with the date. Do not commit for that alone.

### Wrap-up, at the end of a task or session

1. Append one entry of at most 5 lines to the task's Log: what changed (commit hashes), what was verified (command and result), what is open.
2. Rewrite STATE.md. Mark every open task keep, close or supersede.
3. Leave STATE.md and task files uncommitted until the work they record is complete, then put them in that work's commit. Agent management with no code change (triage, closing tasks, notes) gets a `chore(agents)` commit once it is complete.

### Code comments

Comments must read without `.agents/`. Cite papers, equations or user-facing docs, never task ids, STATE.md or task files. Put the task id in the commit message body. The pre-commit hook rejects task ids (`task 29`, `K33`) and agent paths in added comments: fix the comment and commit again. Never commit with `--no-verify`.

## Errors

- Code, logic or type errors: fix them and continue.
- Environment, access or network errors you cannot fix in one attempt: stop, report the blocker to the user and note it in the task file.

## Standing decisions

- 2026-08-11: Python drives the compiled `convview`/`convdump` executables as subprocesses, no FFI.
- 2026-08-11: meson-python + ninja build; giza is a git submodule compiled on first build.
- 2026-08-12: the reader is picked from the path (`.cnv`, `.kipp`, `seq.`/`.seq`, a MESA profiles dir).
- 2026-10-06: LGPL-3.0-or-later, full FSF notice on every source file, copyright "the kippy authors (see AUTHORS)".
- 2026-10-06: docs are zensical with a hand-written `api.md`, deployed to GH Pages at kippy.rileythai.com.
- 2026-10-14: macOS wheels target 15.0; the interactive window on macOS is XQuartz `/xw`.
- 2026-10-17: the giza submodule tracks the `rileythai/giza` fork over https so CI and anonymous clones work.
