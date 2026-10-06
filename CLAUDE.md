# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

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

## Code Style

- Always place import statements at the top of files.
- Before writing a new function or utility, search the existing codebase first. Do not reimplement something that already exists.

## Building

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

## Git

Commit frequently to checkpoint progress — after completing any meaningful step,
not just at the end of a task. Use small, incremental commits.

Commits must be authored as Riley Thai, not as Claude:
```
git commit --author="Riley Thai <rileythai@proton.me>"
```

Do not include `Co-Authored-By: Claude` in commit messages.

### Commit message style

Use [Conventional Commits](https://www.conventionalcommits.org/) format:

```
<type>(<optional scope>): <description>
```

**Types:** `feat`, `fix`, `refactor`, `perf`, `style`, `test`, `docs`, `build`,
`ops`, `chore`.

**Rules:**
- Description: imperative present tense, no capital first letter, no trailing period
- Breaking changes: add `!` before `:` and include `BREAKING CHANGE:` in the footer
- Scope is optional; do not use issue identifiers as scopes
- Do not use unicode characters

Never chain `git add` and `git commit` with `&&`. Run them as separate sequential
tool calls.

## Project Management

### PLAN.md is the master document

**CRITICAL — you MUST use PLAN.md for every task.** Before starting any task, read
PLAN.md. After completing any task, update PLAN.md (Tasks table, Decisions,
Session State) and commit. A task is not done until PLAN.md reflects it.

`PLAN.md` (top-level) is the single source of truth for planning, tracking, and
execution. Task IDs prefixed `K##` are inherited from keppy (pre-split provenance)
and should not be renumbered.

### Keeping things in sync

- Read PLAN.md at the start of every new conversation to pick up where we left off.
- Update PLAN.md immediately when a task starts, completes, is blocked, or the plan changes.
- Before the conversation ends, update the "Session State" section of PLAN.md.
