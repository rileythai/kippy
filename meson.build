project(
  'kippy',
  ['c', 'fortran'],
  version: '0.1.0',
  meson_version: '>=1.1.0',
  default_options: [
    'buildtype=release',
    'optimization=2',
    'warning_level=1',
  ],
)

py = import('python').find_installation(pure: false)

subdir('src/kippy')
