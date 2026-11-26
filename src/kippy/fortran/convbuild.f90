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

! convbuild.f90 -- record builders shared by the profile readers
module convbuild
   !! Record builders shared by profile readers (mesaload.f90, monload.f90).
   !!
   !! Energy and field quantization, colour-field registry, zone run-length compression; re-exports
   !! units.f90 constants. Depends only on convdata, typedef and units, so either reader uses it w/o
   !! a module cycle.

   use typedef, only: &
      int32, real64
   use convdata, only: &
      convtype, fieldlayer, &
      nuc_kind, idx_kind, &
      FIELD_NBINS, nfields, field_names, field_units, field_vmin, field_vmax, field_vpos, &
      field_log
   use units, only: SOLMASS, SOLRAD, YR

   implicit none (type, external)
   private

   public :: SOLMASS, SOLRAD, YR, EPS_BASE, GROW_FAC, REC_NVERS
   public :: build_zones, build_energy, build_field_layer
   public :: reset_field_registry, update_field_range, finalize_field_log
   public :: alloc_empty_layers

   real(real64), parameter :: GROW_FAC = 0.5d0*(sqrt(5.d0) + 1.d0)
      !! Growth factor of a reader's full record array, golden ratio.
   integer(int32), parameter :: EPS_BASE = 1
      !! Energy level floor, `log10` of erg/g/s.
      !!
      !! `level_of` maps it to level 1; readers store it as a record's first six level floors.
   integer(int32), parameter :: REC_NVERS = 10600
      !! Record version readers build.

contains

   subroutine build_zones(zones, nz, cnv)
      !! Run-length compress cell zone types into `yzip` and `iconv`.
      !!
      !! Each run of equal types is one zone, `iconv` its outer cell index. Radiative runs included,
      !! so zones tile whole star ("Convection zones", docs/cnvfiles.md).
      ! Arguments
      character(len=1), intent(in) :: zones(:)
         !! `ZONE_CHAR` type of each cell, centre to surface, already mapped from reader's codes.
      integer(int32), intent(in) :: nz
         !! Number of cells.
      type(convtype), intent(inout) :: cnv
         !! Record receiving `nconv`, `yzip`, `iconv`.
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

   subroutine build_energy(f, nz, n, vals, idxs)
      !! Quantize per-cell energy rate into energy-layer step function.
      !!
      !! Stores a (level, coordinate index) pair at each level change, levels from `level_of`
      !! ("Energy layers", docs/cnvfiles.md).
      ! Arguments
      real(real64), intent(in) :: f(:)
         !! Energy rate of each cell (erg/g/s), centre to surface.
      integer(int32), intent(in) :: nz
         !! Number of cells.
      integer(int32), intent(out) :: n
         !! Number of pairs.
      integer(nuc_kind), allocatable, intent(out) :: vals(:)
         !! Level of each pair.
      integer(idx_kind), allocatable, intent(out) :: idxs(:)
         !! Coordinate index where each pair starts.
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

   pure function level_of(f) result(lev)
      !! Return signed integer contour level of energy rate.
      !!
      !! `nint(log10|f|)` shifted so `EPS_BASE` is level 1; negative for losses, 0 below floor.
      ! Arguments
      real(real64), intent(in) :: f
         !! Energy rate (erg/g/s).
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

   subroutine reset_field_registry(nf)
      !! Allocate convdata.f90 colour-field registry for `nf` fields.
      !!
      !! Names and units blank, ranges empty until widened by `update_field_range`.
      ! Arguments
      integer(int32), intent(in) :: nf
         !! Number of fields.

      if (allocated(field_names)) deallocate (field_names)
      if (allocated(field_vmin)) deallocate (field_vmin)
      if (allocated(field_vmax)) deallocate (field_vmax)
      if (allocated(field_vpos)) deallocate (field_vpos)
      if (allocated(field_log)) deallocate (field_log)
      if (allocated(field_units)) deallocate (field_units)
      nfields = nf
      allocate (field_names(nf), field_vmin(nf), field_vmax(nf), field_vpos(nf), &
                field_log(nf))
      allocate (field_units(nf))
      if (nf > 0) then
         field_names = ''
         field_units = ''
         field_vmin = huge(1.d0)
         field_vmax = -huge(1.d0)
         field_vpos = huge(1.d0)
         field_log = .false.
      end if
   end subroutine reset_field_registry

   subroutine update_field_range(f, v)
      !! Widen running range of field `f` w/ one sample.
      !!
      !! Skips NaN and infinite samples; positive samples also lower `field_vpos`.
      ! Arguments
      integer(int32), intent(in) :: f
         !! Field index in registry.
      real(real64), intent(in) :: v
         !! Sample value.

      if (v /= v) return                 ! skip NaN
      if (abs(v) > huge(1.d0)) return     ! skip +/-Inf
      if (v < field_vmin(f)) field_vmin(f) = v
      if (v > field_vmax(f)) field_vmax(f) = v
      if (v > 0.d0 .and. v < field_vpos(f)) field_vpos(f) = v
   end subroutine update_field_range

   subroutine finalize_field_log(f)
      !! Choose default binning of field `f` once its range is known.
      !!
      !! Log if range is strictly positive and spans over two decades (e.g. temperature, density,
      !! luminosity), else linear. No finite samples gives range [0, 1].
      ! Arguments
      integer(int32), intent(in) :: f
         !! Field index in registry.
      logical :: wide

      if (field_vmax(f) < field_vmin(f)) then
         field_vmin(f) = 0.d0
         field_vmax(f) = 1.d0
      end if
      wide = (field_vmin(f) > 0.d0) .and. &
             (field_vmax(f) > field_vmin(f)*1.d2)
      field_log(f) = wide
   end subroutine finalize_field_log

   pure function field_level(v, f, logscale) result(lev)
      !! Return contour bin (1 to `FIELD_NBINS`) of value in range of field `f`.
      !!
      !! Log scale starts at run's smallest positive value, so values at or below 0 fall in bin 1.
      ! Arguments
      real(real64), intent(in) :: v
         !! Value to bin.
      integer(int32), intent(in) :: f
         !! Field index in registry.
      logical, intent(in) :: logscale
         !! Bin in `log10`, not linearly.
      integer(int32) :: lev
      real(real64) :: a, b, x, t

      lev = 1
      if (logscale) then
         if (field_vpos(f) > field_vmax(f)) return   ! no positive values
         a = log10(field_vpos(f))
         b = log10(field_vmax(f))
         x = log10(max(v, field_vpos(f)))
      else
         a = field_vmin(f)
         b = field_vmax(f)
         x = v
      end if
      if (b <= a) return
      t = (x - a)/(b - a)
      lev = 1 + int(t*real(FIELD_NBINS, real64))
      if (lev < 1) lev = 1
      if (lev > FIELD_NBINS) lev = FIELD_NBINS
   end function field_level

   subroutine build_field_layer(raw, nz, f, out)
      !! Run-length compress per-cell field into two (level, coordinate index) step functions.
      !!
      !! Same shape as `build_energy` output: `out(1)` in field's default scale, `out(2)` in other.
      !! Every cell maps to a valid bin, so star tiles fully.
      ! Arguments
      real(real64), intent(in) :: raw(:)
         !! Field value of each cell, centre to surface.
      integer(int32), intent(in) :: nz
         !! Number of cells.
      integer(int32), intent(in) :: f
         !! Field index in registry.
      type(fieldlayer), intent(out) :: out(2)
         !! Step functions in default and other scale.
      integer(int32) :: j, k, lev, prev, n
      integer(int32), allocatable :: lv(:), ix(:)

      allocate (lv(nz), ix(nz))
      do k = 1, 2
         n = 0
         prev = -huge(1_int32)
         do j = 1, nz
            lev = field_level(raw(j), f, field_log(f) .neqv. (k == 2))
            if (lev /= prev) then
               n = n + 1
               lv(n) = lev
               ix(n) = j
               prev = lev
            end if
         end do
         out(k)%n = n
         allocate (out(k)%lev(n), out(k)%idx(n))
         if (n > 0) then
            out(k)%lev = int(lv(1:n), nuc_kind)
            out(k)%idx = int(ix(1:n), idx_kind)
         end if
      end do
      deallocate (lv, ix)
   end subroutine build_field_layer

   subroutine alloc_empty_layers(cnv)
      !! Allocate layers and arrays profile readers leave unfilled, at size zero.
      !!
      !! `nuk`, derivative layers and advection arrays; keeps renderer's `size` calls and
      !! unconditional loops safe.
      ! Arguments
      type(convtype), intent(inout) :: cnv
         !! Record to complete.

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
