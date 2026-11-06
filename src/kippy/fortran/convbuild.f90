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
   !! Record builders shared by the profile readers.
   !!
   !! mesaload.f90 (MESA and `.kipp`) and monload.f90 (MONASH `seq`) build their records with them.
   !! The builders are energy and field quantization, the colour-field registry and zone run-length compression.
   !! The module also re-exports the physical constants of units.f90.
   !! It depends only on convdata.f90, typedef.f90 and units.f90, so either reader can use it without a module cycle.

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
      !! Growth factor of a reader's record array when it is full, the golden ratio.
   integer(int32), parameter :: EPS_BASE = 1
      !! Energy level floor, `log10` of erg/g/s.
      !! `level_of` maps it to level 1, and the readers store it as the first six level floors of a record.
   integer(int32), parameter :: REC_NVERS = 10600
      !! Record version of the records the readers build.

contains

   subroutine build_zones(zones, nz, cnv)
      !! Run-length compress the zone type of each cell into `yzip` and `iconv`.
      !!
      !! Each run of equal types becomes one zone, with `iconv` its outer cell index.
      !! Radiative runs are included, so the zones tile the whole star ("Convection zones", docs/cnvfiles.md).
      ! Arguments
      character(len=1), intent(in) :: zones(:)
         !! `ZONE_CHAR` type of each cell, centre to surface, already mapped from the reader's own codes.
      integer(int32), intent(in) :: nz
         !! Number of cells.
      type(convtype), intent(inout) :: cnv
         !! Record that receives `nconv`, `yzip` and `iconv`.
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
      !! Quantize an energy rate of each cell into an energy-layer step function.
      !!
      !! A (level, coordinate index) pair is stored at every cell where the level changes.
      !! Levels come from `level_of`, positive for gain and negative for loss.
      !! The step function is described in "Energy layers", docs/cnvfiles.md.
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
      !! Return the signed integer contour level of an energy rate.
      !!
      !! The level is `nint(log10|f|)` shifted so `EPS_BASE` is level 1.
      !! It is negative for losses, and 0 below the floor.
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
      !! Allocate the colour-field registry of convdata.f90 for `nf` fields.
      !!
      !! Names and units are blank.
      !! The ranges are reset to empty, to be widened by `update_field_range`.
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
      !! Widen the running range of field `f` with one sample.
      !!
      !! NaN and infinite samples are skipped.
      !! Positive samples also lower the smallest positive value `field_vpos`.
      ! Arguments
      integer(int32), intent(in) :: f
         !! Field index in the registry.
      real(real64), intent(in) :: v
         !! Sample value.

      if (v /= v) return                 ! skip NaN
      if (abs(v) > huge(1.d0)) return     ! skip +/-Inf
      if (v < field_vmin(f)) field_vmin(f) = v
      if (v > field_vmax(f)) field_vmax(f) = v
      if (v > 0.d0 .and. v < field_vpos(f)) field_vpos(f) = v
   end subroutine update_field_range

   subroutine finalize_field_log(f)
      !! Choose the default binning of field `f` once its range is known.
      !!
      !! A range that is strictly positive and spans more than two decades is binned in log.
      !! Temperature, density and luminosity are typical.
      !! Any other range is binned linearly.
      !! A field with no finite samples gets the range [0, 1].
      ! Arguments
      integer(int32), intent(in) :: f
         !! Field index in the registry.
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
      !! Return the contour bin, from 1 to `FIELD_NBINS`, of a value in the range of field `f`.
      !!
      !! A log scale starts at the smallest positive value in the run, so values at or below 0 fall in bin 1.
      ! Arguments
      real(real64), intent(in) :: v
         !! Value to bin.
      integer(int32), intent(in) :: f
         !! Field index in the registry.
      logical, intent(in) :: logscale
         !! Bin in `log10` rather than linearly.
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
      !! Run-length compress a field of each cell into two (level, coordinate index) step functions.
      !!
      !! These have the same shape that `build_energy` produces.
      !! `out(1)` is binned in the default scale of the field, and `out(2)` in the other one.
      !! Every cell maps to a valid bin, so the star tiles fully.
      ! Arguments
      real(real64), intent(in) :: raw(:)
         !! Field value of each cell, centre to surface.
      integer(int32), intent(in) :: nz
         !! Number of cells.
      integer(int32), intent(in) :: f
         !! Field index in the registry.
      type(fieldlayer), intent(out) :: out(2)
         !! Step functions in the default and the other scale.
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
      !! Allocate the layers and arrays the profile readers do not fill at size zero.
      !!
      !! These are the `nuk` layer, the derivative layers and the advection arrays.
      !! `size` and unconditional loops in the renderer are then safe.
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
