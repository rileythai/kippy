# kippy

[![PyPI](https://img.shields.io/pypi/v/kippy)](https://pypi.org/project/kippy/)
[![Python versions](https://img.shields.io/pypi/pyversions/kippy)](https://pypi.org/project/kippy/)
[![License: LGPL-3.0-or-later](https://img.shields.io/badge/license-LGPL--3.0--or--later-blue)](https://github.com/rileythai/kippy/blob/main/COPYING.LESSER)
[![Wheels](https://github.com/rileythai/kippy/actions/workflows/wheels.yml/badge.svg)](https://github.com/rileythai/kippy/actions/workflows/wheels.yml)
[![Docs](https://github.com/rileythai/kippy/actions/workflows/docs.yml/badge.svg)](https://kippy.rileythai.com)

![Demonstration of kippy on a solar metallicity AGB model from KEPLER](https://raw.githubusercontent.com/rileythai/kippy/main/docs/kippy_demo.gif)

`kippy` is an interactive Kippenhahn diagram diagnostic tool for various stellar
evolution codes, including [MESA](https://mesastar.org) profiles or
[customized raw binary (`.kipp`) streams](https://kippy.rileythai.com/kippfiles/),
[KEPLER](https://2sn.erc.monash.edu/kepler/doc) `.cnv` files, and MONASH `.seq`
files.

`kippy` is built in Fortran for high performance and out-of-memory access for
even the longest stellar evolution runs. The plotting uses the
[cairo](https://www.cairographics.org/) graphics library via
[giza](https://danieljprice.github.io/giza).

`kippy` is based on the interactive Kippenhahn diagram viewer originally written
by [Alexander Heger](https://2sn.erc.monash.edu/) for KEPLER, and is maintained
by [Riley Thai](https://rileythai.com).

Full documentation: <https://kippy.rileythai.com>

## Install

kippy runs on Linux.

```bash
pip install kippy
```

Building from source (the sdist, or a clone) compiles the Fortran core and the
bundled giza library, so it needs `gfortran`, `meson`, `ninja`, and the cairo,
libx11, and freetype2 development packages:

```bash
git clone --recurse-submodules https://github.com/rileythai/kippy
cd kippy
pip install .
```

See the [installation guide](https://kippy.rileythai.com/install/) for editable
installs with uv.

## Quick start

```bash
convview path/to/model.cnv      # interactive viewer
convdump path/to/model.cnv      # print reader summary
```

```python
import kippy

# print first/last model summary stats
print(kippy.dump("model.cnv"))

# render a PNG non-interactively
kippy.view("model.cnv", commands=["save kipp.png", "quit"])

# or launch the interactive REPL
kippy.view("model.cnv")
```

The reader is chosen from the path, so a MESA `LOGS` directory, a `.kipp`
stream, or a MONASH `seq` file works anywhere a `.cnv` file does. See
[input formats](https://kippy.rileythai.com/formats/) and the
[usage guide](https://kippy.rileythai.com/usage/) for cursor-mode keys and REPL
commands.

## License

kippy is licensed under the
[GNU Lesser General Public License v3.0 or later](https://github.com/rileythai/kippy/blob/main/COPYING.LESSER).
The bundled [giza](https://github.com/danieljprice/giza) library is LGPLv3.
