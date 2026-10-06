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

module convbuild

   ! reader-agnostic record builders shared by the mesa/.kipp reader
   ! (mesaload) and the monash seq reader (monload): energy/field
   ! quantization, the colour-field registry, zone run-length compression,
   ! and the shared physical constants.  depends only on convdata + typedef
   ! so either reader can use it without a module cycle.

   use typedef, only: &
      int32, real64
   use convdata, only: &
      convtype, fieldlayer, &
      nuc_kind, idx_kind, &
      FIELD_NBINS, nfields, field_names, field_vmin, field_vmax, field_log

   implicit none (type, external)
   private

   public :: SOLMASS, SOLRAD, YR, EPS_BASE, GROW_FAC, REC_NVERS
   public :: build_zones, build_energy, build_field_layer
   public :: reset_field_registry, update_field_range, finalize_field_log
   public :: alloc_empty_layers

   real(real64), parameter :: SOLMASS = 1.9892d33
   real(real64), parameter :: SOLRAD = 6.9599d10
   real(real64), parameter :: YR = 31556952.d0
   real(real64), parameter :: LOGTINY = 1.d-99
   real(real64), parameter :: GROW_FAC = 0.5d0*(sqrt(5.d0) + 1.d0)
   integer(int32), parameter :: EPS_BASE = 1
   integer(int32), parameter :: REC_NVERS = 10600

contains

   ! run-length compress a per-cell zone-type char array (already mapped from
   ! each reader's own integer codes) into yzip type chars + iconv outer
   ! boundary indices; radiative runs are included so zones tile the whole star.
   subroutine build_zones(zones, nz, cnv)
      character(len=1), intent(in) :: zones(:)
      integer(int32), intent(in) :: nz
      type(convtype), intent(inout) :: cnv
      integer(int32) :: k, nconv
      character(len=1), allocatable :: yz(:)
      integer(int32), allocatable :: ic(:)

      allocate (yz(nz), ic(nz))
      nconv = 0
      do k = 1, nz
         if (k == nz) then
            nconv = nconv + 1
            yz(nconv) = zones(k)
            ic(nconv) = k
         else if (zones(k) /= zones(k + 1)) then
            nconv = nconv + 1
            yz(nconv) = zones(k)
            ic(nconv) = k
         end if
      end do

      cnv%nconv = nconv
      allocate (cnv%yzip(nconv), cnv%iconv(nconv))
      cnv%yzip = yz(1:nconv)
      cnv%iconv = int(ic(1:nconv), idx_kind)
      deallocate (yz, ic)
   end subroutine build_zones

   ! quantize a per-cell energy field (erg/g/s, ascending center->surface)
   ! into the integer level step function kipp draw_energy consumes: a
   ! (level, coordinate-index) pair at every cell where the level changes.
   ! sign is +gain / -loss; cells below the EPS_BASE floor map to level 0.
   subroutine build_energy(f, nz, n, vals, idxs)
      real(real64), intent(in) :: f(:)
      integer(int32), intent(in) :: nz
      integer(int32), intent(out) :: n
      integer(nuc_kind), allocatable, intent(out) :: vals(:)
      integer(idx_kind), allocatable, intent(out) :: idxs(:)
      integer(int32) :: k, lev, prev
      integer(int32), allocatable :: lv(:), ix(:)

      allocate (lv(nz), ix(nz))
      n = 0
      prev = huge(1_int32)     ! forces a pair at the first cell
      do k = 1, nz
         lev = level_of(f(k))
         if (lev /= prev) then
            n = n + 1
            lv(n) = lev
            ix(n) = k
            prev = lev
         end if
      end do

      allocate (vals(n), idxs(n))
      if (n > 0) then
         vals = int(lv(1:n), nuc_kind)
         idxs = int(ix(1:n), idx_kind)
      end if
      deallocate (lv, ix)
   end subroutine build_energy

   ! signed integer contour level of an energy value: nint(log10|f|) shifted
   ! so EPS_BASE is level 1, negative for losses, 0 below the floor
   pure function level_of(f) result(lev)
      real(real64), intent(in) :: f
      integer(int32) :: lev
      real(real64) :: a

      a = abs(f)
      if (a <= 0.d0) then
         lev = 0
         return
      end if
      lev = nint(log10(a)) - EPS_BASE + 1
      if (lev < 1) then
         lev = 0
      else if (f < 0.d0) then
         lev = -lev
      end if
   end function level_of

   ! (re)allocate the shared colour-field registry for nf fields, with ranges
   ! reset to be grown by update_field_range.
   subroutine reset_field_registry(nf)
      integer(int32), intent(in) :: nf

      if (allocated(field_names)) deallocate (field_names)
      if (allocated(field_vmin)) deallocate (field_vmin)
      if (allocated(field_vmax)) deallocate (field_vmax)
      if (allocated(field_log)) deallocate (field_log)
      nfields = nf
      allocate (field_names(nf), field_vmin(nf), field_vmax(nf), field_log(nf))
      if (nf > 0) then
         field_names = ''
         field_vmin = huge(1.d0)
         field_vmax = -huge(1.d0)
         field_log = .false.
      end if
   end subroutine reset_field_registry

   ! widen field f's running [vmin, vmax] with one finite sample
   subroutine update_field_range(f, v)
      integer(int32), intent(in) :: f
      real(real64), intent(in) :: v

      if (v /= v) return                 ! skip NaN
      if (abs(v) > huge(1.d0)) return     ! skip +/-Inf
      if (v < field_vmin(f)) field_vmin(f) = v
      if (v > field_vmax(f)) field_vmax(f) = v
   end subroutine update_field_range

   ! choose log binning for a field whose range is strictly positive and spans
   ! more than two decades (temperature, density, luminosity); linear otherwise
   subroutine finalize_field_log(f)
      integer(int32), intent(in) :: f
      logical :: wide

      if (field_vmax(f) < field_vmin(f)) then
         field_vmin(f) = 0.d0
         field_vmax(f) = 1.d0
      end if
      wide = (field_vmin(f) > 0.d0) .and. &
             (field_vmax(f) > field_vmin(f)*1.d2)
      field_log(f) = wide
   end subroutine finalize_field_log

   ! contour bin (1..FIELD_NBINS) of a value under field f's range and scale
   pure function field_level(v, f) result(lev)
      real(real64), intent(in) :: v
      integer(int32), intent(in) :: f
      integer(int32) :: lev
      real(real64) :: a, b, x, t

      a = field_vmin(f)
      b = field_vmax(f)
      if (field_log(f)) then
         a = log10(max(a, LOGTINY))
         b = log10(max(b, LOGTINY))
         x = log10(max(v, LOGTINY))
      else
         x = v
      end if
      if (b <= a) then
         lev = 1
         return
      end if
      t = (x - a)/(b - a)
      lev = 1 + int(t*real(FIELD_NBINS, real64))
      if (lev < 1) lev = 1
      if (lev > FIELD_NBINS) lev = FIELD_NBINS
   end function field_level

   ! run-length compress a per-cell field (center -> surface) into a
   ! (level, coordinate-index) step function, the same shape build_energy
   ! produces.  every cell maps to a valid bin, so the star tiles fully.
   subroutine build_field_layer(raw, nz, f, out)
      real(real64), intent(in) :: raw(:)
      integer(int32), intent(in) :: nz, f
      type(fieldlayer), intent(out) :: out
      integer(int32) :: k, lev, prev, n
      integer(int32), allocatable :: lv(:), ix(:)

      allocate (lv(nz), ix(nz))
      n = 0
      prev = -huge(1_int32)
      do k = 1, nz
         lev = field_level(raw(k), f)
         if (lev /= prev) then
            n = n + 1
            lv(n) = lev
            ix(n) = k
            prev = lev
         end if
      end do
      out%n = n
      allocate (out%lev(n), out%idx(n))
      if (n > 0) then
         out%lev = int(lv(1:n), nuc_kind)
         out%idx = int(ix(1:n), idx_kind)
      end if
      deallocate (lv, ix)
   end subroutine build_field_layer

   ! allocate the layer-1 and derivative / advection arrays at size zero so
   ! size() and unconditional loops in the renderer are safe
   subroutine alloc_empty_layers(cnv)
      type(convtype), intent(inout) :: cnv

      cnv%nnuk = 0
      cnv%nnucd = 0
      cnv%nnukd = 0
      cnv%nneud = 0
      allocate (cnv%nuk(0), cnv%inuk(0))
      allocate (cnv%nucd(0), cnv%inucd(0))
      allocate (cnv%nukd(0), cnv%inukd(0))
      allocate (cnv%neud(0), cnv%ineud(0))
      allocate (cnv%iadv(0), cnv%dmadv(0), cnv%dvadv(0))
   end subroutine alloc_empty_layers

end module convbuild
