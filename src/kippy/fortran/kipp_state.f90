! kippy - Kippenhahn diagram viewer
! Copyright (C) 2026 the kippy authors (see AUTHORS)
!
! This file is part of kippy.
!
! kippy is free software: you can redistribute it and/or modify
! it under the terms of the GNU Lesser General Public License as
! published by the Free Software Foundation, either version 3 of the
! License, or (at your option) any later version.
!
! kippy is distributed in the hope that it will be useful, but WITHOUT
! ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
! FITNESS FOR A PARTICULAR PURPOSE. See the GNU Lesser General Public
! License for more details.
!
! You should have received a copy of the GNU Lesser General Public
! License along with kippy. If not, see <https://www.gnu.org/licenses/>.

! kipp_state.f90 -- viewer state shared by the kipp modules
module kipp_state
   !! Viewer state that more than one kipp module reads or writes.
   !!
   !! - `st`: the viewer settings. The REPL (`convview`) and the cursor keys
   !!   write them; every render reads them.
   !! - `nmodels`, `xval`, `xedge`, `ystar`: one entry per loaded model,
   !!   rebuilt from `convdata%data` on load and when the axis quantity or
   !!   time unit changes.
   !! - `chs`: the giza character height of the render in progress.
   !!
   !! State used by only one module lives in that module.

   use typedef, only: int32, real64

   implicit none
   private

   public :: kstate_t, st, nmodels, xval, xedge, ystar, chs

   type :: kstate_t
      !! Viewer settings: axes, units, view limits, colour field and device.
      character(len=8)  :: xaxis = 'time'
         !! x-axis quantity, `'time'` or `'model'` (model number).
      character(len=8)  :: yaxis = 'mass'
         !! y-axis quantity, `'mass'` or `'radius'`.
      character(len=4)  :: tunit = 'yr'
         !! Display unit of the time axis, a `units%UNAME` entry.
      character(len=4)  :: munit = 'Msun'
         !! Display unit of the mass axis, a `units%UNAME` entry.
      character(len=4)  :: runit = 'Rsun'
         !! Display unit of the radius axis, a `units%UNAME` entry.
      logical           :: tauto = .true.
         !! The time unit follows the visible span on each render (`units auto`).
      logical           :: xoffset = .true.
         !! Label a linear time axis relative to a matplotlib-style offset.
      logical           :: xlog = .false.
         !! Logarithmic x axis.
      logical           :: ylog = .false.
         !! Logarithmic y axis.
      real(real64)      :: xmin = 0, xmax = 0, ymin = 0, ymax = 0
         !! View limits. x is in the units of `xval`, y in `munit` or
         !! `runit`. Both stay linear values on a logarithmic axis.
      logical           :: xauto = .true., yauto = .true.
         !! Limits follow the data: `kipp_autoscale` resets only these axes.
      character(len=32) :: cfield = 'epsnuc'
         !! Colour field: `convtype`, `epsnuc`, `neu` or a column field name.
      logical           :: cflip = .false.
         !! Show the column field in its non-default linear or log scale.
      character(len=16) :: cmap = 'teal'
         !! Colormap of column fields, a `CMAP_NAMES` entry; `_r` reverses it.
      character(len=64) :: device = '/xw'
         !! giza device: `/xw` when `$DISPLAY` is set, else `/png`.
      character(len=64) :: prefix = 'convview'
         !! File name prefix of the `/png` device: each render writes `<prefix>.png`.
      logical           :: interactive = .true.
         !! Renders reuse one open `/xw` window; otherwise each opens,
         !! writes and closes a PNG.
      logical           :: showmodels = .true.
         !! Draw the model-density strip (`models on|off`).
      logical           :: showgrid = .false.
         !! Draw the cell and strip-edge grid (`grid on|off`).
      integer           :: devid = -1
         !! giza id of the open interactive device, -1 when none is open.
   end type kstate_t

   type(kstate_t) :: st
      !! The viewer settings.

   real(real64) :: chs = 1.d0
      !! giza character height of the render in progress: 1, or `PDF_CHS`
      !! during a PDF save.

   integer(int32) :: nmodels = 0
      !! Number of loaded models, `size(convdata%data)`.
   real(real64), allocatable :: xval(:)
      !! x coordinate of each model: time in `st%tunit`, or model number.
   real(real64), allocatable :: xedge(:)
      !! Model strip edges (`nmodels + 1`): midpoints between successive
      !! `xval`, the two ends half a step outside.
   real(real64), allocatable :: ystar(:)
      !! Outer mass or radius of each model (cgs), following `st%yaxis`.

end module kipp_state
