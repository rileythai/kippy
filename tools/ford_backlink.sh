#!/bin/sh
# kippy - Kippenhahn diagram viewer
# Copyright (C) 2026 the kippy authors (see AUTHORS)
#
# This file is part of kippy.
#
# kippy is free software: you can redistribute it and/or modify
# it under the terms of the GNU Lesser General Public License as
# published by the Free Software Foundation, either version 3 of the
# License, or (at your option) any later version.
#
# kippy is distributed in the hope that it will be useful, but WITHOUT
# ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
# FITNESS FOR A PARTICULAR PURPOSE. See the GNU Lesser General Public
# License for more details.
#
# You should have received a copy of the GNU Lesser General Public
# License along with kippy. If not, see <https://www.gnu.org/licenses/>.

# add a link back to the docs site root to the navbar of every FORD page.
# FORD 7 base.html has no navbar hook, so the link goes in after the build.
# the pattern is anchored at line end, so a second run adds nothing.
set -eu
dir=${1:-docs/fortran}
find "$dir" -name '*.html' -exec sed -i \
  's|<ul class="navbar-nav">$|&<li class="nav-item"><a class="nav-link" href="/">kippy docs</a></li>|' {} +
missing=$(grep -rL --include='*.html' 'href="/">kippy docs<' "$dir" || true)
if [ -n "$missing" ]; then
  echo "ford_backlink: no navbar link added in:" >&2
  echo "$missing" >&2
  exit 1
fi
