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
   !! Viewer state shared by more than one kipp module.
   !!
   !! `st` written by REPL and cursor keys, read by every render. Per-model axes (`nmodels`, `xval`,
   !! `xedge`, `ystar`) rebuilt on load and on axis-quantity or time-unit change.

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
         !! Time-axis display unit, a `units%UNAME` entry.
      character(len=4)  :: munit = 'Msun'
         !! Mass-axis display unit, a `units%UNAME` entry.
      character(len=4)  :: runit = 'Rsun'
         !! Radius-axis display unit, a `units%UNAME` entry.
      logical           :: tauto = .true.
         !! Time unit follows visible span on each render (`units auto`).
      logical           :: xoffset = .true.
         !! Label linear time axis relative to matplotlib-style offset.
      logical           :: xlog = .false.
         !! Logarithmic x axis.
      logical           :: ylog = .false.
         !! Logarithmic y axis.
      real(real64)      :: xmin = 0, xmax = 0, ymin = 0, ymax = 0
         !! View limits. x in `xval` units, y in `munit` or `runit`; linear values even on log axes.
      logical           :: xauto = .true., yauto = .true.
         !! Limits follow data: `kipp_autoscale` resets only these axes.
      character(len=32) :: cfield = 'epsnuc'
         !! Colour field: `convtype`, `epsnuc`, `neu` or a column field name.
      logical           :: cflip = .false.
         !! Show column field in its non-default linear/log scale.
      character(len=16) :: cmap = 'teal'
         !! Colormap of column fields, a `CMAP_NAMES` entry; `_r` reverses it.
      character(len=64) :: device = '/xw'
         !! giza device: `/xw` when `$DISPLAY` is set, else `/png`.
      character(len=64) :: prefix = 'convview'
         !! `/png` file name prefix: each render writes `<prefix>.png`.
      logical           :: interactive = .true.
         !! Renders reuse one open `/xw` window; otherwise each opens, writes and closes a PNG.
      logical           :: showmodels = .true.
         !! Draw the model-density strip (`models on|off`).
      logical           :: showgrid = .false.
         !! Draw the cell and strip-edge grid (`grid on|off`).
      integer           :: devid = -1
         !! giza id of the open interactive device, -1 when none is open.
   end type kstate_t

   type(kstate_t) :: st
      !! Viewer settings.

   real(real64) :: chs = 1.d0
      !! giza character height of current render: 1, or `PDF_CHS` during PDF save.

   integer(int32) :: nmodels = 0
      !! Loaded model count, `size(convdata%data)`.
   real(real64), allocatable :: xval(:)
      !! x coordinate of each model: time in `st%tunit`, or model number.
   real(real64), allocatable :: xedge(:)
      !! Model strip edges (`nmodels + 1`): midpoints of successive `xval`, ends half a step
      !! outside.
   real(real64), allocatable :: ystar(:)
      !! Outer mass or radius of each model (cgs), per `st%yaxis`.

end module kipp_state
