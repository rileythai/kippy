# kippy native build
#
# builds the vendored giza plotting library (autotools, via tools/build_giza.py)
# then compiles the kippenhahn viewer executables against it. the executables
# and the giza shared library install side by side under kippy/bin so an
# $ORIGIN rpath resolves libgiza at runtime.

bindir = py.get_install_dir() / 'kippy' / 'bin'

# --- vendored giza (autotools) staged into the meson build dir ---
giza = custom_target(
  'giza',
  output: ['libgiza.so.2.0.0', 'libgiza.so.2', 'libgiza.so', 'giza.mod', 'giza-fortran.o'],
  command: [py, files('../../tools/build_giza.py'), meson.global_source_root() / 'giza', '@OUTDIR@'],
  build_by_default: true,
  console: true,
  install: true,
  # ship only the soname the executables load (libgiza.so.2); the linker-name
  # symlink and the real name are only needed in the build tree at link time,
  # and the wheel would materialise each symlink as a full copy otherwise
  install_dir: [false, bindir, false, false, false],
)

giza_mod = giza[3]
giza_fobj = giza[4]

# giza.mod and the reader mods land here; -I so gfortran finds them
fflags = ['-ffree-line-length-none', '-I' + meson.current_build_dir()]

# openmp parallelizes the per-profile MESA reader loop (mesaload.f90); the
# dependency adds the compile and link flags for the active compiler
omp = dependency('openmp')

# --- vendored keppy .cnv reader ---
reader_lib = static_library(
  'kipp_reader',
  files('fortran/typedef.f90', 'fortran/convdata.f90', 'fortran/convload.f90', 'fortran/mesaload.f90'),
  fortran_args: fflags,
  dependencies: omp,
  install: false,
)

# --- kippenhahn plotting core (needs giza.mod first) ---
kipp_lib = static_library(
  'kipp',
  files('fortran/kipp.f90'),
  sources: [giza_mod],
  fortran_args: fflags,
  link_with: reader_lib,
  install: false,
)

# cairo/x11/freetype2 are giza's runtime backends
giza_backends = [
  dependency('cairo'),
  dependency('x11'),
  dependency('freetype2'),
]

# interactive giza viewer
executable(
  'convview',
  files('fortran/convview.f90'),
  giza_fobj,
  fortran_args: fflags,
  link_with: [kipp_lib, reader_lib],
  link_args: ['-L' + meson.current_build_dir(), '-lgiza', '-lm'],
  link_depends: [giza],
  dependencies: [giza_backends, omp],
  # $ORIGIN so the installed binary finds the sibling libgiza in kippy/bin.
  # build_rpath bakes the same entry into the build-tree binary. meson-python
  # packages the wheel from the build tree and skips meson's install-time rpath
  # rewrite, so without build_rpath the binary ships meson's XXXXXXX placeholder
  # and cannot load libgiza at runtime
  build_rpath: '$ORIGIN',
  install_rpath: '$ORIGIN',
  install: true,
  install_dir: bindir,
)

# headless reader diagnostic (no giza)
executable(
  'convdump',
  files('fortran/convdump.f90'),
  fortran_args: fflags,
  link_with: reader_lib,
  dependencies: omp,
  install: true,
  install_dir: bindir,
)

# --- python package ---
py.install_sources(
  files('__init__.py', '_cli.py'),
  subdir: 'kippy',
)
