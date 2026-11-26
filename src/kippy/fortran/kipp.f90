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

! kipp.f90 -- Kippenhahn rendering library on top of giza
module kipp
   !! Public interface of kipp renderer.
   !!
   !! Renders a Kippenhahn diagram from any `load_convection` input (KEPLER `.cnv`, MESA profiles,
   !! `.kipp`, MONASH seq). Only module convview.f90 uses: re-exports draw.f90 device and render
   !! routines, `kipp_autoscale`, cursor.f90 routines, and `st`, `nmodels`; holds no state.

   use typedef, only: int32, real64
   use convdata, only: data, nfields, field_names, &
                       field_vmin, field_vmax, field_vpos, field_log
   use mesaload, only: load_convection, kipp_axis_units
   use units, only: unit_id, UNAME, UDIM, DIM_TIME, DIM_MASS, DIM_LENGTH
   use cmaps, only: CMAP_NAMES, NCMAPS
   use kipp_state, only: kstate_t, st, nmodels
   use coords, only: build_axes, kipp_autoscale, set_time_unit, yscale
   use layers, only: cache_invalidate
   use axes, only: is_reversed
   use draw, only: kipp_choose_device, kipp_render, kipp_save, kipp_close
   use cursor, only: kipp_interact, kipp_wait_input, kipp_action, kipp_window_center, clear_views

   implicit none
   private

   public :: kipp_load, kipp_choose_device, kipp_render, kipp_save, &
             kipp_close, kipp_autoscale, kipp_rebuild, kipp_interact, kipp_wait_input, &
             kipp_action, kipp_window_center, kipp_list_fields, kipp_set_cfield, &
             kipp_list_cmaps, kipp_set_cmap, kipp_set_unit, kstate_t, st, nmodels

contains

   subroutine kipp_load(filename)
      !! Load every model of an input and build its axes.
      !!
      !! Reader picked from path by `load_convection`; `.kipp` header mass and radius units replace
      !! those of `st`; view fitted by `kipp_autoscale`. Fewer than 2 models stops program w/ error.
      ! Arguments
      character(len=*), intent(in) :: filename
         !! Path of `.cnv`, `.kipp` or seq file, or MESA profiles dir.
      call load_convection(filename, 1_int32, huge(1_int32))
      nmodels = int(size(data), int32)
      if (nmodels < 2) error stop '[kipp] need at least 2 models'
      if (len_trim(kipp_axis_units(DIM_MASS)) > 0) st%munit = kipp_axis_units(DIM_MASS)
      if (len_trim(kipp_axis_units(DIM_LENGTH)) > 0) st%runit = kipp_axis_units(DIM_LENGTH)
      call cache_invalidate()
      call build_axes()
      call kipp_autoscale()
   end subroutine kipp_load

   pure integer(int32) function list_index(s)
      !! Return 1-based list position typed in `s`.
      !!
      !! 0 if `s` is not a plain number of at most 6 digits.
      ! Arguments
      character(len=*), intent(in) :: s
         !! Typed selector.
      integer(int32) :: ios
      list_index = 0
      if (len_trim(s) == 0 .or. len_trim(s) > 6) return
      if (verify(trim(s), '0123456789') /= 0) return
      read (s, *, iostat=ios) list_index
      if (ios /= 0) list_index = 0
   end function list_index

   subroutine kipp_set_cmap(arg, ok)
      !! Select colormap by name or by number in `kipp_list_cmaps`.
      !!
      !! `_r` suffix on either reverses it; `grey` reads as `gray`.
      ! Arguments
      character(len=*), intent(in) :: arg
         !! Colormap name or number, optionally suffixed `_r`.
      logical, intent(out) :: ok
         !! False for unknown colormap, leaving `st%cmap` unchanged.
      character(len=len(arg)) :: base
      integer(int32) :: k
      logical :: rev
      rev = is_reversed(arg)
      base = arg(1:len_trim(arg) - merge(2, 0, rev))
      if (base == 'grey') base = 'gray'
      k = findloc(CMAP_NAMES, base, 1)
      if (k == 0) k = list_index(base)
      ok = k >= 1 .and. k <= NCMAPS
      if (ok) st%cmap = trim(CMAP_NAMES(k))//merge('_r', '  ', rev)
   end subroutine kipp_set_cmap

   subroutine kipp_list_cmaps()
      !! Print numbered colormaps, marking current one.
      integer(int32) :: k, n
      n = len_trim(st%cmap) - merge(2, 0, is_reversed(st%cmap))
      print '(a)', 'colormaps (cmap <name|number>, append _r to reverse):'
      do k = 1, NCMAPS
         print '(i4,2x,a,a)', k, CMAP_NAMES(k), &
            merge(' (current)', '          ', CMAP_NAMES(k) == st%cmap(1:n))
      end do
   end subroutine kipp_list_cmaps

   subroutine kipp_rebuild()
      !! Rebuild model axes after change of axis quantity.
      !!
      !! Retraces cached bands (they hold mass or radius interfaces) and empties view history (its
      !! views hold the other quantity).
      call cache_invalidate()
      call build_axes()
      call clear_views()
   end subroutine kipp_rebuild

   subroutine kipp_set_unit(arg, ok)
      !! Set display unit of axis matching unit's dimension.
      !!
      !! `solar` and `cgs` set mass and radius units together; a time unit pins time axis, `auto`
      !! lets it follow visible span again. View limits converted so view stays in place; bands
      !! index x strips and hold cgs y, so nothing retraced.
      ! Arguments
      character(len=*), intent(in) :: arg
         !! Unit name or alias known to `unit_id`, or `auto`, `solar` or `cgs`.
      logical, intent(out) :: ok
         !! False for unknown unit.
      integer(int32) :: k
      ok = .true.
      select case (arg)
      case ('auto')
         st%tauto = .true.
         return
      case ('solar')
         call set_y_units('Msun', 'Rsun')
         return
      case ('cgs')
         call set_y_units('g', 'cm')
         return
      end select
      k = unit_id(arg)
      ok = (k > 0)
      if (.not. ok) return
      select case (UDIM(k))
      case (DIM_TIME)
         st%tauto = .false.
         call set_time_unit(k)
      case (DIM_MASS)
         call set_y_units(UNAME(k), st%runit)
      case (DIM_LENGTH)
         call set_y_units(st%munit, UNAME(k))
      end select
   end subroutine kipp_set_unit

   subroutine set_y_units(munit, runit)
      !! Set mass and radius display units, keeping view.
      !!
      !! Rescales y view limits by change in `yscale`.
      ! Arguments
      character(len=*), intent(in) :: munit
         !! Mass unit, a `UNAME` entry.
      character(len=*), intent(in) :: runit
         !! Radius unit, a `UNAME` entry.
      real(real64) :: f
      f = yscale()
      st%munit = munit; st%runit = runit
      f = f/yscale()
      st%ymin = st%ymin*f; st%ymax = st%ymax*f
   end subroutine set_y_units

   subroutine kipp_list_fields()
      !! Print numbered colour selectors of `color <name|number>`.
      !!
      !! 1 to 3 are fixed `convtype`, `epsnuc`, `neu`; loaded input's column fields follow, each w/
      !! scale and value range over run.
      integer(int32) :: k
      character(len=8) :: scale
      print '(a)', 'color selectors (color <name|number>):'
      print '(a)', '   1  convtype   (no colour field, convection hatch only)'
      print '(a)', '   2  epsnuc     nuclear energy layer (log erg/g/s)'
      print '(a)', '   3  neu        neutrino energy layer (log erg/g/s)'
      if (.not. allocated(field_names) .or. nfields < 1) then
         print '(a)', '  (no extra column fields in this source)'
         return
      end if
      print '(a)', '  column fields (min .. max across the run, color -<number> for the other scale):'
      do k = 1, nfields
         scale = merge('log ', 'lin ', field_log(k))
         print '(i4,2x,a16,a,a,es11.3,a,es11.3)', k + 3, field_names(k), &
            '  ', trim(scale), field_vmin(k), ' .. ', field_vmax(k)
      end do
   end subroutine kipp_list_fields

   subroutine kipp_set_cfield(arg, ok)
      !! Select colour field by name or by number in `kipp_list_fields`.
      !!
      !! Negative number shows column field in its other (linear or log) scale. Refused selection
      !! prints reason, leaves `st` unchanged.
      ! Arguments
      character(len=*), intent(in) :: arg
         !! Selector name, number, or negative number.
      logical, intent(out) :: ok
         !! False if selection refused.
      character(len=8), parameter :: FIXED(3) = [character(len=8) :: 'convtype', 'epsnuc', 'neu']
      integer(int32) :: k
      logical :: flip
      flip = .false.
      k = list_index(arg)
      if (k == 0 .and. arg(1:1) == '-') then
         k = list_index(arg(2:))
         flip = k > 0
      end if
      ok = .false.
      if (k > 3 + nfields) then
         print *, 'no color entry ', arg, '   (type color for the list)'
         return
      end if
      if (flip) then
         if (k <= 3) then
            print *, 'no lin/log switch for the fixed selectors 1-3'
            return
         end if
         if (.not. field_log(k - 3) .and. field_vpos(k - 3) > field_vmax(k - 3)) then
            print *, 'no log scale for ', trim(field_names(k - 3)), ': no positive values'
            return
         end if
      end if
      ok = .true.
      st%cflip = flip
      if (k == 0) then
         st%cfield = arg
      else if (k <= 3) then
         st%cfield = FIXED(k)
      else
         st%cfield = field_names(k - 3)
      end if
   end subroutine kipp_set_cfield

end module kipp
