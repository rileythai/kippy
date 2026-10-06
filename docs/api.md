# kippy API reference

`kippy` provides a small Python API for the bundled native Kippenhahn viewer
and diagnostic reader.

The package version is available as `kippy.__version__`.

## Public API

The names exported by `kippy.__all__` are listed below.

### `view`

```python
def view(
    cnvfile: str | os.PathLike | None = None,
    *,
    commands: list[str] | None = None,
    check: bool = True,
) -> subprocess.CompletedProcess
```

Launches the interactive `convview` viewer. `cnvfile` is the path to any supported
[input](formats.md); when omitted, `convview` uses its default
`convdata.cnv` in the working directory. If `commands` is provided, the
commands are written to the viewer's standard input, one per line. Otherwise,
standard input is inherited for an interactive session. With `check=True`, a
non-zero exit status raises `subprocess.CalledProcessError`.

```python
from kippy import view

view("model.cnv", commands=["save out.png", "quit"])
```

### `dump`

```python
def dump(
    cnvfile: str | os.PathLike | None = None,
    *,
    check: bool = True,
) -> str
```

Runs the headless `convdump` reader diagnostic and returns its standard output
as a string. `cnvfile` is the optional path to any supported [input](formats.md). With
`check=True`, a non-zero exit status raises `subprocess.CalledProcessError`.

```python
from kippy import dump

print(dump("model.cnv"))
```

### `executable`

```python
def executable(name: str) -> Path
```

Resolves the named bundled executable and returns its `pathlib.Path`. Raises
`FileNotFoundError` if the executable is not present.

### `bin_dir`

```python
def bin_dir() -> Path
```

Returns the `pathlib.Path` for the directory containing the bundled
executables and `libgiza`.

### `child_env`

```python
def child_env() -> dict
```

Returns a copy of the current environment for launching the bundled
executables. The bundled binary directory is prepended to `LD_LIBRARY_PATH`.

## Console scripts

The `convview` and `convdump` console scripts forward their command-line
arguments (`argv`) to the corresponding bundled native binary and return its
exit code.
