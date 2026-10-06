# kippy

kippy is an interactive Kippenhahn diagram viewer for KEPLER `.cnv` files,
MESA profile directories, raw `.kipp` streams, and MONASH seq files. Its
plotting core is compiled Fortran linked against the vendored giza library,
with Python driving the executables as subprocesses.

## Quick start

After [installing kippy](install.md), open a model in the interactive viewer:

```bash
convview path/to/model.cnv
```

Or launch it from Python:

```python
import kippy

kippy.view("path/to/model.cnv")
```

Continue with the [usage guide](usage.md), see the supported
[input formats](formats.md), or browse the [Python API](api.md).
