# `kippy`

![Demonstration of Kippy on a Solar metallicity AGB model from KEPLER](kippy_demo.gif)

`kippy` is an interactive Kippenhahn diagram diagnostic tool for various stellar evolution codes, including
[MESA](https://mesastar.org) profiles or [customized raw binary (`.kipp`) streams](kippfiles.md), [KEPLER](https://2sn.erc.monash.edu/kepler/doc) `.cnv` files, and MONASH `.seq` files.

`kippy` is built in Fortran for high performance, out-of-memory access for even the longest stellar evolution runs, and supports `pip`-installation. The plotting makes use of ['cairo'](https://www.cairographics.org/) graphics library via [`giza`](https://danieljprice.github.io/giza).

`kippy` is based on the interactive Kippenhahn diagram viewer originally written by [Alexander Heger](https://2sn.erc.monash.edu/) for `KEPLER`, and is maintained by [Riley Thai](https://rileythai.com).


## Quick start

After [installing kippy](install.md), you can open a model in the interactive viewer:

```bash
convview path/to/model.cnv
```

Or launch it from Python:

```python
import kippy

kippy.view("path/to/model.cnv")
```

Continue with the [usage guide](usage.md), see the supported
[input formats](formats.md), [how to adjust MESA to make `.kipp` files](kippfiles.md),
or browse the [Python API](api.md).
