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

! layers.f90 -- data layers and band caches of the kipp renderer
module layers
   !! Data layer lookup and the band caches traced from it.
   !!
   !! A "layer" is one per-model quantity that is traced into bands.
   !! - Convection types come from the zone list `yzip` of each model.
   !! - Energy layers are step functions of signed integer contour levels,
   !!   positive for gain and negative for loss.
   !!   - Layer 0 is nuclear energy generation, 1 nuclear energy loss, 2 neutrinos.
   !! - Colour fields are columns binned into `FIELD_NBINS` levels, registered by
   !!   the readers in convdata.f90.
   !!
   !! Some notes on functions:
   !! - `layer_of_cfield` and `field_of_cfield` resolve the `color` selection `st%cfield`.
   !! - `get_layer` and `get_field_buf` copy a model's step function.
   !! - `level_intervals` turns one contour level of a step function into mass or radius intervals.
   !! - `build_conv_cache`, `build_energy_cache` and `build_field_cache` trace every model
   !!   into `conv_bands` and `conv_chains`, `ecache` and `fcache`.
   !! - `cache_invalidate` drops every cache.
   !!
   !! draw.f90 draws the caches and reads the colour field lookups.
   !! cursor.f90 reads the lookups for `print_cell`.
   !! kipp.f90 calls `cache_invalidate` on file load and axis rebuild.
   !! axes.f90 reads the energy caches and `level_mins` for the energy colorbar.
   !! This module holds the caches used by the `draw` module.

   use typedef, only: int32, real64
   use convdata, only: data, FIELD_NBINS, nfields, field_names, RADIATIVE, NEUTRAL, OVERSHOOT, &
                       SEMICONV, CONVECTIVE, THERMOHALINE, NCONVTYPES, ZONE_CHAR
   use kipp_state, only: st, nmodels
   use bands, only: bandset_t, chainset_t, tracer_t, tracer_alloc, tracer_dealloc, &
                    tracer_reset, tracer_step, tracer_flush, bandset_clear, chainset_clear, &
                    seg_append, symdiff_append, build_chains
   use coords, only: mbound, coord_at

   implicit none
   private

   public :: conv_bands, conv_chains, conv_valid, ecache, fcache, &
             type_of, level_mins, layer_of_cfield, field_of_cfield, field_layer_len, fscale, &
             get_layer, get_field_buf, build_conv_cache, build_energy_cache, build_field_cache, &
             cache_invalidate

   type :: ecache_t
      !! Band cache of one energy layer.
      !!
      !! One bandset per gain level and one per loss level.
      logical :: valid = .false.
         !! The bands are traced.
      integer(int32) :: gmax = 0, lmax = 0
         !! Highest gain level and highest loss level, as a positive number.
      type(bandset_t), allocatable :: gain(:), loss(:)
         !! Bands of each gain level, `gain(1:gmax)`, and each loss level, `loss(1:lmax)`.
   end type ecache_t

   type :: fcache_t
      !! Band cache of one colour field on one scale.
      !!
      !! One nested bandset per contour bin.
      !! Bin 1 covers the whole star and higher bins nest inward.
      logical :: valid = .false.
         !! The bands are traced.
      integer(int32) :: nlev = 0
         !! Number of contour bins.
      type(bandset_t), allocatable :: band(:)
         !! Bands of each bin, `band(1:nlev)`.
   end type fcache_t

   type(bandset_t) :: conv_bands(NCONVTYPES)
      !! Bands of each convection type, indexed by the codes of `type_of`.
   type(chainset_t) :: conv_chains(NCONVTYPES)
      !! Exact region outline of each convection type.
   logical :: conv_valid = .false.
      !! `conv_bands` and `conv_chains` are traced.
   type(ecache_t) :: ecache(0:2)
      !! Band cache of each energy layer.
      !! Traced on first use, so `color` switches do not retrace.
   type(fcache_t), allocatable :: fcache(:, :)
      !! Band cache of each colour field, `(scale, field)` as in `convdata%fld`.
      !! Traced on first use of each field and scale.

contains

   pure function type_of(ch) result(t)
      !! Return the convection-type code of a zone character.
      !!
      !! The codes and their characters are the `ZONE_CHAR` table of convdata.f90.
      !! An unknown character is `RADIATIVE`.
      ! Arguments
      character(len=1), intent(in) :: ch
         !! Zone character from `yzip`.
      integer(int32) :: t
      select case (ch)
      case (ZONE_CHAR(NEUTRAL)); t = NEUTRAL
      case (ZONE_CHAR(OVERSHOOT)); t = OVERSHOOT
      case (ZONE_CHAR(SEMICONV)); t = SEMICONV
      case (ZONE_CHAR(CONVECTIVE)); t = CONVECTIVE
      case (ZONE_CHAR(THERMOHALINE)); t = THERMOHALINE
      case default; t = RADIATIVE
      end select
   end function type_of

   pure function layer_of_cfield() result(layer)
      !! Return the energy layer named by `st%cfield`, or -1.
      !!
      !! -1 means the selection is not an energy layer.
      !! `epsnuc`, `enuc` and `nuc` give layer 0, signed as gain and loss.
      !! `nuk` and `loss` give layer 1.
      !! `neu` and `neutrino` give layer 2.
      integer(int32) :: layer
      select case (trim(st%cfield))
      case ('epsnuc', 'enuc', 'nuc'); layer = 0
      case ('nuk', 'loss'); layer = 1
      case ('neu', 'neutrino'); layer = 2
      case default; layer = -1
      end select
   end function layer_of_cfield

   pure function field_of_cfield() result(f)
      !! Return the colour field named by `st%cfield`, `1..nfields`, or 0.
      !!
      !! An exact source column name is matched first.
      !! Then a few aliases are tried against the canonical names the readers emit.
      integer(int32) :: f, k
      character(len=len(st%cfield)) :: want
      f = 0
      if (.not. allocated(field_names)) return
      want = trim(st%cfield)
      do k = 1, nfields
         if (trim(field_names(k)) == want) then
            f = k
            return
         end if
      end do
      ! aliases: try each canonical name a group maps to, first present wins
      select case (want)
      case ('temperature', 'temp', 'T')
         f = first_field(['T_K   ', 'logT  ', 'T     '])
      case ('density', 'rho', 'Rho')
         f = first_field(['rho_gcc', 'logRho ', 'rho    '])
      case ('luminosity', 'lum', 'L')
         f = first_field(['L_erg_s   ', 'logL      ', 'luminosity'])
      case ('pressure', 'P')
         f = first_field(['logP    ', 'pressure'])
      end select
   end function field_of_cfield

   pure function first_field(names) result(f)
      !! Return the index of the first registered name in `names`, or 0.
      ! Arguments
      character(len=*), intent(in) :: names(:)
         !! Canonical field names, in order of preference.
      integer(int32) :: f, i, k
      f = 0
      if (.not. allocated(field_names)) return
      do i = 1, size(names)
         do k = 1, nfields
            if (trim(field_names(k)) == trim(names(i))) then
               f = k
               return
            end if
         end do
      end do
   end function first_field

   pure function field_layer_len(i, f) result(n)
      !! Return the number of step-function entries of colour field `f` in model `i`.
      !!
      !! The scale is the one selected by `fscale`.
      ! Arguments
      integer(int32), intent(in) :: i
         !! Model index.
      integer(int32), intent(in) :: f
         !! Colour field index.
      integer(int32) :: n
      n = 0
      if (f < 1 .or. f > data(i)%nfld) return
      n = data(i)%fld(fscale(), f)%n
   end function field_layer_len

   pure integer(int32) function fscale()
      !! Return the scale index of the colour field: 1 default, 2 flipped by `st%cflip`.
      fscale = merge(2_int32, 1_int32, st%cflip)
   end function fscale

   subroutine get_field_buf(i, f, vals, idxs, n)
      !! Copy the step function of colour field `f` in model `i` into buffers.
      !!
      !! Parallel to `get_layer_buf` for the energy layers.
      ! Arguments
      integer(int32), intent(in)  :: i
         !! Model index.
      integer(int32), intent(in)  :: f
         !! Colour field index.
      integer(int32), intent(out) :: vals(:)
         !! Contour bin of each entry, at least `n` long.
      integer(int32), intent(out) :: idxs(:)
         !! Coordinate index where each entry starts, at least `n` long.
      integer(int32), intent(out) :: n
         !! Number of entries copied.
      n = field_layer_len(i, f)
      if (n > 0) then
         vals(1:n) = int(data(i)%fld(fscale(), f)%lev, int32)
         idxs(1:n) = int(data(i)%fld(fscale(), f)%idx, int32)
      end if
   end subroutine get_field_buf

   subroutine level_mins(layer, gmin, lmin)
      !! Return the minimum log10 gain and loss levels of an energy layer.
      !!
      !! These come from the file header, read as consecutive (gain, loss) pairs per layer.
      !! The historic KEPLER field names are misleading: `minloss` is the nuclear gain minimum.
      ! Arguments
      integer(int32), intent(in)  :: layer
         !! Energy layer, 0 to 2.
      integer(int32), intent(out) :: gmin
         !! log10 of the lowest gain level.
      integer(int32), intent(out) :: lmin
         !! log10 of the lowest loss level.
      select case (layer)
      case (0); gmin = int(data(1)%minloss, int32); lmin = int(data(1)%mingain, int32)
      case (1); gmin = int(data(1)%minnucl, int32); lmin = int(data(1)%minnucg, int32)
      case (2); gmin = int(data(1)%minneul, int32); lmin = int(data(1)%minneug, int32)
      case default; gmin = 0; lmin = 0
      end select
   end subroutine level_mins

   subroutine get_layer(i, layer, vals, idxs, n)
      !! Copy the step function of an energy layer in model `i` into new arrays.
      ! Arguments
      integer(int32), intent(in)  :: i
         !! Model index.
      integer(int32), intent(in)  :: layer
         !! Energy layer, 0 to 2.
      integer(int32), allocatable, intent(out) :: vals(:)
         !! Signed contour level of each entry.
      integer(int32), allocatable, intent(out) :: idxs(:)
         !! Coordinate index where each entry starts.
      integer(int32), intent(out) :: n
         !! Number of entries.
      select case (layer)
      case (0); n = data(i)%nnuc
      case (1); n = data(i)%nnuk
      case (2); n = data(i)%nneu
      case default; n = 0
      end select
      allocate (vals(n), idxs(n))
      if (n > 0) then
         select case (layer)
         case (0); vals = int(data(i)%nuc, int32); idxs = int(data(i)%inuc, int32)
         case (1); vals = int(data(i)%nuk, int32); idxs = int(data(i)%inuk, int32)
         case (2); vals = int(data(i)%neu, int32); idxs = int(data(i)%ineu, int32)
         end select
      end if
   end subroutine get_layer

   pure function layer_len(i, layer) result(n)
      !! Return the number of step-function entries of an energy layer in model `i`.
      !!
      !! Used to size scratch buffers.
      ! Arguments
      integer(int32), intent(in) :: i
         !! Model index.
      integer(int32), intent(in) :: layer
         !! Energy layer, 0 to 2.
      integer(int32) :: n
      select case (layer)
      case (0); n = int(data(i)%nnuc, int32)
      case (1); n = int(data(i)%nnuk, int32)
      case (2); n = int(data(i)%nneu, int32)
      case default; n = 0
      end select
   end function layer_len

   subroutine get_layer_buf(i, layer, vals, idxs, n)
      !! Copy the step function of an energy layer in model `i` into buffers.
      !!
      !! Same as `get_layer` without the allocation,
      !! so the per-model, per-level loops of `build_energy_cache` stay allocation-free.
      ! Arguments
      integer(int32), intent(in)  :: i
         !! Model index.
      integer(int32), intent(in)  :: layer
         !! Energy layer, 0 to 2.
      integer(int32), intent(out) :: vals(:)
         !! Signed contour level of each entry, at least `n` long.
      integer(int32), intent(out) :: idxs(:)
         !! Coordinate index where each entry starts, at least `n` long.
      integer(int32), intent(out) :: n
         !! Number of entries copied.
      n = layer_len(i, layer)
      if (n > 0) then
         select case (layer)
         case (0); vals(1:n) = int(data(i)%nuc, int32); idxs(1:n) = int(data(i)%inuc, int32)
         case (1); vals(1:n) = int(data(i)%nuk, int32); idxs(1:n) = int(data(i)%inuk, int32)
         case (2); vals(1:n) = int(data(i)%neu, int32); idxs(1:n) = int(data(i)%ineu, int32)
         case default; stop "impossible case hit"
         end select
      end if
   end subroutine get_layer_buf

   subroutine scan_levels(layer, gmax, lmax)
      !! Find the highest gain and loss levels of an energy layer across all models.
      ! Arguments
      integer(int32), intent(in)  :: layer
         !! Energy layer, 0 to 2.
      integer(int32), intent(out) :: gmax
         !! Highest positive level, or 0.
      integer(int32), intent(out) :: lmax
         !! Magnitude of the most negative level, or 0.
      integer(int32) :: i, n, k
      integer(int32), allocatable :: vals(:), idxs(:)
      gmax = 0; lmax = 0
      do i = 1, nmodels
         call get_layer(i, layer, vals, idxs, n)
         do k = 1, n
            gmax = max(gmax, vals(k))
            lmax = max(lmax, -vals(k))
         end do
         deallocate (vals, idxs)
      end do
   end subroutine scan_levels

   subroutine level_intervals(i, vals, idxs, n, L, ivlo, ivhi, m)
      !! Find the intervals of model `i` where a step function reaches level `L`.
      !!
      !! A positive `L` is reached by values at or above it,
      !! a negative `L` by values at or below it.
      !! The intervals are returned in cgs coordinates for the band tracer.
      ! Arguments
      integer(int32), intent(in)  :: i
         !! Model index.
      integer(int32), intent(in)  :: vals(:)
         !! Level of each step-function entry.
      integer(int32), intent(in)  :: idxs(:)
         !! Coordinate index where each entry starts.
      integer(int32), intent(in)  :: n
         !! Number of entries.
      integer(int32), intent(in)  :: L
         !! Contour level, nonzero.
      real(real64), intent(out) :: ivlo(:)
         !! Lower mass (g) or radius (cm) of each interval, at least `n` long.
      real(real64), intent(out) :: ivhi(:)
         !! Upper mass (g) or radius (cm) of each interval, at least `n` long.
      integer(int32), intent(out) :: m
         !! Number of intervals.
      integer(int32) :: pf, xprev, xcur
      logical :: rising, falling, inb
      real(real64) :: ylo
      m = 0; inb = .false.; ylo = 0.d0
      do pf = 1, n
         if (pf == 1) then
            xprev = 0
         else
            xprev = vals(pf - 1)
         end if
         xcur = vals(pf)
         if (L > 0) then
            rising = (xprev < L .and. xcur >= L)
            falling = (xprev >= L .and. xcur < L)
         else
            rising = (xprev > L .and. xcur <= L)
            falling = (xprev <= L .and. xcur > L)
         end if
         if (rising) then
            ylo = coord_at(i, idxs(pf)); inb = .true.
         else if (falling .and. inb) then
            m = m + 1; ivlo(m) = ylo; ivhi(m) = coord_at(i, idxs(pf))
            inb = .false.
         end if
      end do
      if (inb) then
         m = m + 1; ivlo(m) = ylo; ivhi(m) = coord_at(i, data(i)%ncoord)
      end if
   end subroutine level_intervals

   subroutine build_conv_cache()
      !! Trace all five convection types into `conv_bands` and `conv_chains`.
      !!
      !! Each type is traced in one pass over the models.
      !! The exact region outline is built alongside the bands.
      !! It holds the horizontal interface edges of every interval.
      !! At every strip edge it also holds the symmetric difference of the
      !! adjacent models' interval sets, the y covered on one side only.
      !! Seams where the tracer closes and restarts bands are covered on both sides,
      !! so they never enter the outline.
      type(tracer_t) :: tr
      integer(int32) :: t, i, j, m, pm, maxnc, ns
      real(real64), allocatable :: ivlo(:), ivhi(:), plo(:), phi(:), bp(:)
      integer(int32), allocatable :: se0(:), se1(:)
      real(real64), allocatable :: sy0(:), sy1(:)

      maxnc = 1
      do i = 1, nmodels
         maxnc = max(maxnc, int(data(i)%nconv, int32))
      end do
      call tracer_alloc(tr, 64_int32, nmodels)
      allocate (ivlo(maxnc), ivhi(maxnc), plo(maxnc), phi(maxnc))
      allocate (bp(4*maxnc + 4))

      do t = 1, NCONVTYPES
         call bandset_clear(conv_bands(t))
         call chainset_clear(conv_chains(t))
         call tracer_reset(tr)
         ns = 0; pm = 0
         do i = 1, nmodels
            ! intervals of this type in model i (centre -> surface order)
            m = 0
            do j = 1, int(data(i)%nconv, int32)
               if (type_of(data(i)%yzip(j)) /= t) cycle
               m = m + 1
               ivlo(m) = mbound(i, j - 1)
               ivhi(m) = mbound(i, j)
            end do
            call tracer_step(tr, conv_bands(t), i, ivlo, ivhi, m)
            ! outline: vertical boundary at strip edge i, horizontals of model i
            call symdiff_append(plo, phi, pm, ivlo, ivhi, m, i, bp, &
                                se0, se1, sy0, sy1, ns)
            do j = 1, m
               if (ivhi(j) <= ivlo(j)) cycle
               call seg_append(se0, se1, sy0, sy1, ns, i, i + 1, ivlo(j), ivlo(j))
               call seg_append(se0, se1, sy0, sy1, ns, i, i + 1, ivhi(j), ivhi(j))
            end do
            pm = m; plo(1:m) = ivlo(1:m); phi(1:m) = ivhi(1:m)
         end do
         call tracer_flush(tr, conv_bands(t))
         ! right boundary of the last model
         call symdiff_append(plo, phi, pm, ivlo, ivhi, 0_int32, nmodels + 1, bp, &
                             se0, se1, sy0, sy1, ns)
         call build_chains(conv_chains(t), se0, se1, sy0, sy1, ns)
      end do
      deallocate (ivlo, ivhi, plo, phi, bp)
      call tracer_dealloc(tr)
      conv_valid = .true.
   end subroutine build_conv_cache

   subroutine build_energy_cache(layer)
      !! Trace every gain and loss level of an energy layer into `ecache(layer)`.
      ! Arguments
      integer(int32), intent(in) :: layer
         !! Energy layer, 0 to 2.
      type(tracer_t) :: tr
      integer(int32) :: i, n, lev, maxn, m
      integer(int32), allocatable :: lvals(:), lidxs(:)
      real(real64), allocatable   :: ivlo(:), ivhi(:)
      associate (ec => ecache(layer))
         if (allocated(ec%gain)) deallocate (ec%gain)
         if (allocated(ec%loss)) deallocate (ec%loss)
         call scan_levels(layer, ec%gmax, ec%lmax)
         allocate (ec%gain(ec%gmax), ec%loss(ec%lmax))
         maxn = 1
         do i = 1, nmodels
            maxn = max(maxn, layer_len(i, layer))
         end do
         call tracer_alloc(tr, 64_int32, nmodels)
         allocate (lvals(maxn), lidxs(maxn), ivlo(maxn + 1), ivhi(maxn + 1))
         do lev = 1, ec%lmax
            call tracer_reset(tr)
            do i = 1, nmodels
               call get_layer_buf(i, layer, lvals, lidxs, n)
               call level_intervals(i, lvals, lidxs, n, -lev, ivlo, ivhi, m)
               call tracer_step(tr, ec%loss(lev), i, ivlo, ivhi, m)
            end do
            call tracer_flush(tr, ec%loss(lev))
         end do
         do lev = 1, ec%gmax
            call tracer_reset(tr)
            do i = 1, nmodels
               call get_layer_buf(i, layer, lvals, lidxs, n)
               call level_intervals(i, lvals, lidxs, n, lev, ivlo, ivhi, m)
               call tracer_step(tr, ec%gain(lev), i, ivlo, ivhi, m)
            end do
            call tracer_flush(tr, ec%gain(lev))
         end do
         deallocate (lvals, lidxs, ivlo, ivhi)
         call tracer_dealloc(tr)
         ec%valid = .true.
      end associate
   end subroutine build_energy_cache

   subroutine build_field_cache(f)
      !! Trace every contour bin of colour field `f` into `fcache`.
      !!
      !! The scale is the one selected by `fscale`.
      !! Bin 1 covers the whole star and each higher bin nests inward.
      !! The energy band tracer is reused.
      ! Arguments
      integer(int32), intent(in) :: f
         !! Colour field index.
      type(tracer_t) :: tr
      integer(int32) :: i, n, lev, maxn, m
      integer(int32), allocatable :: lvals(:), lidxs(:)
      real(real64), allocatable   :: ivlo(:), ivhi(:)
      associate (fc => fcache(fscale(), f))
         if (allocated(fc%band)) deallocate (fc%band)
         fc%nlev = FIELD_NBINS
         allocate (fc%band(fc%nlev))
         maxn = 1
         do i = 1, nmodels
            maxn = max(maxn, field_layer_len(i, f))
         end do
         call tracer_alloc(tr, 64_int32, nmodels)
         allocate (lvals(maxn), lidxs(maxn), ivlo(maxn + 1), ivhi(maxn + 1))
         do lev = 1, fc%nlev
            call tracer_reset(tr)
            do i = 1, nmodels
               call get_field_buf(i, f, lvals, lidxs, n)
               call level_intervals(i, lvals, lidxs, n, lev, ivlo, ivhi, m)
               call tracer_step(tr, fc%band(lev), i, ivlo, ivhi, m)
            end do
            call tracer_flush(tr, fc%band(lev))
         end do
         deallocate (lvals, lidxs, ivlo, ivhi)
         call tracer_dealloc(tr)
         fc%valid = .true.
      end associate
   end subroutine build_field_cache

   subroutine cache_invalidate()
      !! Drop every cached band, on file load or axis rebuild.
      integer(int32) :: t, l
      do t = 1, NCONVTYPES
         call bandset_clear(conv_bands(t))
         call chainset_clear(conv_chains(t))
      end do
      conv_valid = .false.
      do l = 0, 2
         if (allocated(ecache(l)%gain)) deallocate (ecache(l)%gain)
         if (allocated(ecache(l)%loss)) deallocate (ecache(l)%loss)
         ecache(l)%gmax = 0; ecache(l)%lmax = 0
         ecache(l)%valid = .false.
      end do
      ! field band caches are view-dependent (mass/radius interfaces), so
      ! drop and re-size them to the current registry on every invalidation
      if (allocated(fcache)) deallocate (fcache)
      if (nfields > 0) allocate (fcache(2, nfields))
   end subroutine cache_invalidate

end module layers
