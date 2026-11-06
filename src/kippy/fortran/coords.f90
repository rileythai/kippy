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

! coords.f90 -- model axes and world-coordinate transforms of the kipp renderer
module coords
   !! Model axes and world-coordinate transforms.
   !!
   !! - `build_axes` rebuilds `xval`, `xedge` and `ystar` of kipp_state.f90.
   !! - `kipp_autoscale` sets the auto view limits from them.
   !! - `xtrans`, `ytrans` and `ytrans2` map data to giza world coordinates.
   !!   `inv_x` and `inv_y` map world coordinates back.
   !! - `mbound` and `coord_at` give the mass or radius of a model's
   !!   convection boundary or coordinate index.
   !! - `bisect_le` finds the model strip that holds an x value.
   !!
   !! "Display units" are the units of the view limits in `st`:
   !! `xval` units on x, `st%munit` or `st%runit` on y.
   !! "World coordinates" are giza window coordinates.
   !! A linear axis gives display units, shifted by `xoff` on x.
   !! A logarithmic axis gives their log10.
   !!
   !! kipp.f90 uses every routine and sets `xoff` on each render.
   !! This module holds only `xoff`.

   use typedef, only: int32, real64
   use convdata, only: data
   use units, only: unit_id, UFAC
   use kipp_state, only: st, nmodels, xval, xedge, ystar

   implicit none
   private

   public :: xoff, build_axes, kipp_autoscale, yscale, xtrans, ytrans, ytrans2, &
             inv_x, inv_y, mbound, coord_at, bisect_le

   real(real64), parameter :: LOGMIN = 1.d-99
      !! Floor applied before a log10 so zero and negative values stay finite.

   real(real64) :: xoff = 0.d0
      !! Time offset subtracted from linear x world coordinates, in `st%tunit`.
      !! Set on each render by `draw_scene`, with its label.

contains

   subroutine build_axes()
      !! Build the per-model x coordinate, strip edges and outer boundary.
      !!
      !! `xval`, `xedge` and `ystar` are rebuilt from `convdata%data` to
      !! follow `st%xaxis`, `st%tunit` and `st%yaxis`.
      integer(int32) :: i
      if (allocated(xval)) deallocate (xval)
      if (allocated(xedge)) deallocate (xedge)
      if (allocated(ystar)) deallocate (ystar)
      allocate (xval(nmodels), xedge(nmodels + 1), ystar(nmodels))
      do i = 1, nmodels
         if (st%xaxis == 'model') then
            xval(i) = real(data(i)%ncyc, real64)
         else
            xval(i) = data(i)%timesec/UFAC(unit_id(st%tunit))
         end if
         if (st%yaxis == 'radius') then
            ystar(i) = data(i)%rncoord(data(i)%ncoord)
         else
            ystar(i) = data(i)%xmcoord(data(i)%ncoord)
         end if
      end do
      ! strip edges = midpoints between successive model x-values
      xedge(1) = xval(1) - 0.5d0*(xval(2) - xval(1))
      do i = 2, nmodels
         xedge(i) = 0.5d0*(xval(i - 1) + xval(i))
      end do
      xedge(nmodels + 1) = xval(nmodels) + 0.5d0*(xval(nmodels) - xval(nmodels - 1))
   end subroutine build_axes

   subroutine kipp_autoscale()
      !! Reset the auto view limits from the data.
      !!
      !! Only the axes flagged by `st%xauto` and `st%yauto` are reset.
      !! x spans all model strips.
      !! y spans the centre to the largest outer boundary, or four decades
      !! below it on a logarithmic axis.
      if (st%xauto) then
         st%xmin = xedge(1)
         st%xmax = xedge(nmodels + 1)
      end if
      if (st%yauto) then
         st%ymin = 0.d0
         st%ymax = maxval(ystar)/yscale()
         if (st%ylog) st%ymin = st%ymax*1.d-4
      end if
   end subroutine kipp_autoscale

   pure function yscale() result(s)
      !! Return the cgs size of one y display unit.
      !!
      !! The unit is `st%runit` on the radius axis, else `st%munit`.
      real(real64) :: s
      if (st%yaxis == 'radius') then
         s = UFAC(unit_id(st%runit))
      else
         s = UFAC(unit_id(st%munit))
      end if
   end function yscale

   pure function xtrans(x) result(p)
      !! Map an x value to world coordinates.
      !!
      !! A logarithmic axis takes the log10, floored at `LOGMIN`.
      !! A linear axis subtracts `xoff`.
      ! Arguments
      real(real64), intent(in) :: x
         !! x value in `xval` units: time in `st%tunit`, or model number.
      real(real64) :: p
      if (st%xlog) then
         p = log10(max(x, LOGMIN))
      else
         p = x - xoff
      end if
   end function xtrans

   pure function ytrans(c) result(p)
      !! Map a cgs mass or radius to world coordinates.
      !!
      !! The value is scaled to the display unit, then a logarithmic axis
      !! takes the log10.
      ! Arguments
      real(real64), intent(in) :: c
         !! Mass (g) or radius (cm).
      real(real64) :: p
      p = c/yscale()
      if (st%ylog) p = log10(max(p, LOGMIN))
   end function ytrans

   pure function ytrans2(v) result(p)
      !! Map a y value in display units to world coordinates.
      !!
      !! Used for the view limits, which are already scaled, so only the
      !! log10 of a logarithmic axis applies.
      ! Arguments
      real(real64), intent(in) :: v
         !! y value in `st%munit` or `st%runit`.
      real(real64) :: p
      if (st%ylog) then
         p = log10(max(v, LOGMIN))
      else
         p = v
      end if
   end function ytrans2

   pure function inv_x(w) result(v)
      !! Map a world x coordinate back to display units.
      !!
      !! Inverse of `xtrans`.
      !! The exponent is clamped to +-300 to stay inside the real64 range.
      ! Arguments
      real(real64), intent(in) :: w
         !! World x coordinate.
      real(real64) :: v
      if (st%xlog) then
         v = 10.d0**max(min(w, 300.d0), -300.d0)
      else
         v = w + xoff
      end if
   end function inv_x

   pure function inv_y(w) result(v)
      !! Map a world y coordinate back to display units.
      !!
      !! Inverse of `ytrans2`.
      !! The exponent is clamped to +-300 to stay inside the real64 range.
      ! Arguments
      real(real64), intent(in) :: w
         !! World y coordinate.
      real(real64) :: v
      if (st%ylog) then
         v = 10.d0**max(min(w, 300.d0), -300.d0)
      else
         v = w
      end if
   end function inv_y

   pure function mbound(i, k) result(c)
      !! Return the cgs mass or radius of convection boundary `k` of model `i`.
      !!
      !! Boundary 0 is the inner edge of the grid.
      !! Boundary `k > 0` lies midway between coordinates `iconv(k)` and
      !! `iconv(k) + 1`.
      !! On the radius axis the midpoint is taken in r^3, so it halves the
      !! shell volume.
      ! Arguments
      integer(int32), intent(in) :: i, k
         !! Model index; boundary index, `0..nconv`.
      real(real64) :: c
      integer(int32) :: ic, nc
      nc = data(i)%ncoord
      if (st%yaxis == 'radius') then
         if (k == 0) then
            c = data(i)%rncoord(1)
         else
            ic = data(i)%iconv(k)
            c = (0.5d0*(data(i)%rncoord(ic)**3 + &
                        data(i)%rncoord(min(ic + 1, nc))**3))**(1.d0/3.d0)
         end if
      else
         if (k == 0) then
            c = data(i)%xmcoord(1)
         else
            ic = data(i)%iconv(k)
            c = 0.5d0*(data(i)%xmcoord(ic) + data(i)%xmcoord(min(ic + 1, nc)))
         end if
      end if
   end function mbound

   pure function coord_at(i, ic) result(c)
      !! Return the cgs mass or radius at coordinate index `ic` of model `i`.
      !!
      !! `ic` is the 1-based KEPLER coordinate index, clamped to `1..ncoord`.
      ! Arguments
      integer(int32), intent(in) :: i, ic
         !! Model index; coordinate index.
      real(real64) :: c
      integer(int32) :: j
      j = max(1_int32, min(ic, data(i)%ncoord))
      if (st%yaxis == "radius") then
         c = data(i)%rncoord(j)
      else
         c = data(i)%xmcoord(j)
      end if
   end function coord_at

   pure function bisect_le(arr, v) result(k)
      !! Return the largest `k` with `arr(k) <= v`, or 0 when `v < arr(1)`.
      !!
      !! Found by bisection, so `arr` must be ascending.
      ! Arguments
      real(real64), intent(in) :: arr(:), v
         !! Ascending array; value to place.
      integer(int32) :: k, lo, hi, mid
      if (v < arr(1)) then
         k = 0
         return
      end if
      lo = 1; hi = int(size(arr), int32)
      do while (lo < hi)
         mid = (lo + hi + 1)/2
         if (arr(mid) <= v) then
            lo = mid
         else
            hi = mid - 1
         end if
      end do
      k = lo
   end function bisect_le

end module coords
