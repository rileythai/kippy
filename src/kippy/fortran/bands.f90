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

! bands.f90 -- band tracer and region outlines of the kipp renderer
module bands
   !! Traced bands and region outlines datatypes and methods.
   !!
   !! - `tracer_t` and the `tracer_*` routines turn per-model intervals of
   !!   one feature into bands, stored in a `bandset_t`.
   !! - `seg_append`, `symdiff_append` and `build_chains` build the outline
   !!   of a region as a `chainset_t` of polylines.
   !!
   !! Outline segments live on a "strip-edge" grid, where distinct
   !! vertical/horizontal segments are defined via the edge coordinates
   !! relative to vertical segmentation of model strips, i.e.:
   !! `(e0, y0)-(e1, y1)`. `e0 == e1` is vertical at strip edge
   !! `e0`. `y0 == y1 && e1 == e0 + 1` is horizontal across a time boundary.
   !!
   !! The cache builders fill the band and chainsets. These are later used
   !! by the draw routines (draw.f90). `build_chains` reads `nmodels` from `kipp_state`.
   !! This module holds no state.

   use typedef, only: int32, real64
   use kipp_state, only: nmodels

   implicit none
   private

   public :: tracer_t, band_t, bandset_t, chain_t, chainset_t, &
             tracer_alloc, tracer_dealloc, tracer_reset, tracer_step, tracer_flush, &
             bandset_clear, seg_append, symdiff_append, build_chains, chainset_clear

   type :: tracer_t
      !! Greedy band tracer.
      !!
      !! Turns per-model `(ylo, yhi)` intervals of one
      !! feature (a convection type, or one energy contour level) into a
      !! small number of bands spanning contiguous runs of models.
      !! Closed bands are stored into a `bandset_t` cache.
      integer(int32) :: maxbands = 0
         !! Number of band slots.
      integer(int32), allocatable :: i0(:), i1(:)
         !! First and last model of the band in each slot.
      logical, allocatable :: opn(:), ext(:)
         !! The slot holds an open band; the band was extended this step.
      real(real64), allocatable :: ylo(:, :), yhi(:, :)
         !! Lower and upper interface of each band, `(slot, model)`.
   end type tracer_t

   type :: band_t
      !! One traced band in data coordinates.
      !!
      !! This is a model range on x, cgs mass or radius interfaces on y.
      !! Designed to be view-independent so zoom, pan and units
      !! only change on transforms.
      !! Bands are cached across renders so redraws only cost a polygon fill.
      integer(int32) :: i0 = 0, i1 = 0
         !! First and last model of the band.
      real(real64), allocatable :: ylo(:), yhi(:)
         !! Lower and upper interface in each model, `i1 - i0 + 1` entries.
   end type band_t

   type :: bandset_t
      !! A growable list of bands.
      integer(int32) :: nb = 0
         !! Number of bands stored.
      type(band_t), allocatable :: b(:)
         !! The bands, `b(1:nb)`; extended with array doubling.
   end type bandset_t

   type :: chain_t
      !! One outline polyline along a region boundary.
      !!
      !! In data coordinates: x is a strip-edge index into `xedge`, y a cgs mass or radius.
      integer(int32) :: n = 0
         !! Number of points.
      integer(int32), allocatable :: ei(:)
         !! Strip-edge index of each point.
      real(real64), allocatable :: y(:)
         !! y coordinate of each point.
   end type chain_t

   type :: chainset_t
      !! A growable list of outline chains.
      integer(int32) :: nc = 0
         !! Number of chains stored.
      type(chain_t), allocatable :: c(:)
         !! The chains, `c(1:nc)`; extended with array doubling.
   end type chainset_t

contains

   !---------------------------------------------------------------------
   ! band tracer

   subroutine tracer_alloc(tr, maxbands, nm)
      !! Allocate a tracer with `maxbands` band slots over `nm` models, all
      !! slots closed.
      ! Arguments
      type(tracer_t), intent(out) :: tr
         !! The tracer.
      integer(int32), intent(in)  :: maxbands, nm
         !! Number of band slots; number of models.
      tr%maxbands = maxbands
      allocate (tr%i0(maxbands), tr%i1(maxbands))
      allocate (tr%opn(maxbands), tr%ext(maxbands))
      allocate (tr%ylo(maxbands, nm), tr%yhi(maxbands, nm))
      tr%opn = .false.
   end subroutine tracer_alloc

   subroutine tracer_dealloc(tr)
      !! Free the band slots of a tracer.
      ! Arguments
      type(tracer_t), intent(inout) :: tr
         !! The tracer.
      deallocate (tr%i0, tr%i1, tr%opn, tr%ext, tr%ylo, tr%yhi)
      tr%maxbands = 0
   end subroutine tracer_dealloc

   subroutine tracer_reset(tr)
      !! Begin a new feature: close out any leftover bands without emitting.
      ! Arguments
      type(tracer_t), intent(inout) :: tr
         !! The tracer.
      tr%opn = .false.
   end subroutine tracer_reset

   subroutine tracer_step(tr, bs, i, ivlo, ivhi, m)
      !! Feed model `i`'s intervals (`ivlo`/`ivhi`, `m` of them, ascending
      !! in y).
      !! Each interval is matched to an open band from model `i - 1`
      !! by overlap; unmatched intervals open new ones; bands with no
      !! continuation are stored to `bs`.
      ! Arguments
      type(tracer_t), intent(inout) :: tr
         !! The tracer.
      type(bandset_t), intent(inout) :: bs
         !! Receives the bands closed at this model.
      integer(int32), intent(in)    :: i, m
         !! Model index; number of intervals.
      real(real64), intent(in)    :: ivlo(:), ivhi(:)
         !! Lower and upper y of each interval, `1:m` used.
      integer(int32) :: k, b, newb
      logical :: matched
      tr%ext = .false.
      do k = 1, m
         matched = .false.
         do b = 1, tr%maxbands
            if (.not. tr%opn(b) .or. tr%ext(b) .or. tr%i1(b) /= i - 1) cycle
            if (ivlo(k) < tr%yhi(b, i - 1) .and. tr%ylo(b, i - 1) < ivhi(k)) then
               tr%ylo(b, i) = ivlo(k); tr%yhi(b, i) = ivhi(k)
               tr%i1(b) = i; tr%ext(b) = .true.
               matched = .true.
               exit
            end if
         end do
         if (matched) cycle
         newb = 0
         do b = 1, tr%maxbands
            if (.not. tr%opn(b)) then; newb = b; exit; end if
         end do
         if (newb > 0) then
            tr%opn(newb) = .true.; tr%ext(newb) = .true.
            tr%i0(newb) = i; tr%i1(newb) = i
            tr%ylo(newb, i) = ivlo(k); tr%yhi(newb, i) = ivhi(k)
         else
            ! overflow fallback: store as a single-model band
            call bandset_append(bs, i, i, ivlo(k:k), ivhi(k:k))
         end if
      end do
      do b = 1, tr%maxbands
         if (tr%opn(b) .and. .not. tr%ext(b)) then
            call tracer_close(tr, bs, b)
         end if
      end do
   end subroutine tracer_step

   subroutine tracer_flush(tr, bs)
      !! Store all bands still open at the final model.
      ! Arguments
      type(tracer_t), intent(inout) :: tr
         !! The tracer.
      type(bandset_t), intent(inout) :: bs
         !! Receives the stored bands.
      integer(int32) :: b
      do b = 1, tr%maxbands
         if (tr%opn(b)) call tracer_close(tr, bs, b)
      end do
   end subroutine tracer_flush

   subroutine tracer_close(tr, bs, b)
      !! Store the band in slot `b` to `bs` and free the slot.
      ! Arguments
      type(tracer_t), intent(inout) :: tr
         !! The tracer.
      type(bandset_t), intent(inout) :: bs
         !! Receives the band.
      integer(int32), intent(in)    :: b
         !! Slot to close.
      call bandset_append(bs, tr%i0(b), tr%i1(b), &
                          tr%ylo(b, tr%i0(b):tr%i1(b)), tr%yhi(b, tr%i0(b):tr%i1(b)))
      tr%opn(b) = .false.
   end subroutine tracer_close

   !---------------------------------------------------------------------
   ! band sets

   subroutine bandset_clear(bs)
      !! Drop every band of a set.
      ! Arguments
      type(bandset_t), intent(inout) :: bs
         !! The band set.
      if (allocated(bs%b)) deallocate (bs%b)
      bs%nb = 0
   end subroutine bandset_clear

   subroutine bandset_append(bs, i0, i1, ylo, yhi)
      !! Append one band (grow-by-doubling).
      ! Arguments
      type(bandset_t), intent(inout) :: bs
         !! The band set.
      integer(int32), intent(in)    :: i0, i1
         !! First and last model of the band.
      real(real64), intent(in)    :: ylo(:), yhi(:)
         !! Lower and upper interface in each model, `i1 - i0 + 1` entries.
      type(band_t), allocatable :: tmp(:)
      integer(int32) :: cap
      if (.not. allocated(bs%b)) allocate (bs%b(8))
      cap = int(size(bs%b), int32)
      if (bs%nb == cap) then
         allocate (tmp(2*cap))
         tmp(1:cap) = bs%b
         call move_alloc(tmp, bs%b)
      end if
      bs%nb = bs%nb + 1
      bs%b(bs%nb)%i0 = i0
      bs%b(bs%nb)%i1 = i1
      bs%b(bs%nb)%ylo = ylo
      bs%b(bs%nb)%yhi = yhi
   end subroutine bandset_append

   !---------------------------------------------------------------------
   ! region outlines

   subroutine seg_append(se0, se1, sy0, sy1, ns, e0, e1, y0, y1)
      !! Append one outline segment (grow-by-doubling).
      ! Arguments
      integer(int32), allocatable, intent(inout) :: se0(:), se1(:)
         !! Strip edge of each segment's first and second end.
      real(real64), allocatable, intent(inout) :: sy0(:), sy1(:)
         !! y of each segment's first and second end.
      integer(int32), intent(inout) :: ns
         !! Number of segments, incremented.
      integer(int32), intent(in)    :: e0, e1
         !! Strip edges of the new segment's ends.
      real(real64), intent(in)    :: y0, y1
         !! y of the new segment's ends.
      ns = ns + 1
      call grow_i32(se0, ns); call grow_i32(se1, ns)
      call grow_r64(sy0, ns); call grow_r64(sy1, ns)
      se0(ns) = e0; se1(ns) = e1
      sy0(ns) = y0; sy1(ns) = y1
   end subroutine seg_append

   subroutine symdiff_append(alo, ahi, na, blo, bhi, nb, e, bp, &
                             se0, se1, sy0, sy1, ns)
      !! Append the vertical outline segments at strip edge `e`.
      !!
      !! Spans of y covered by exactly one of the two adjacent models' interval
      !! sets.
      !! All values are exact copies of the `mbound` reals to give exact membership tests.
      ! Arguments
      real(real64), intent(in)    :: alo(:), ahi(:), blo(:), bhi(:)
         !! Intervals of the models left (`a`) and right (`b`) of the edge.
      integer(int32), intent(in)    :: na, nb, e
         !! Number of `a` intervals; number of `b` intervals; the strip edge.
      real(real64), intent(inout) :: bp(:)
         !! Breakpoint scratch, at least `2*(na + nb)` long.
      integer(int32), allocatable, intent(inout) :: se0(:), se1(:)
         !! Strip edge of each segment's first and second end.
      real(real64), allocatable, intent(inout) :: sy0(:), sy1(:)
         !! y of each segment's first and second end.
      integer(int32), intent(inout) :: ns
         !! Number of segments, incremented per appended segment.
      integer(int32) :: k, p, nbp
      real(real64) :: y0, y1, v
      logical :: ina, inb

      nbp = 0
      do k = 1, na
         if (ahi(k) > alo(k)) then
            nbp = nbp + 1; bp(nbp) = alo(k)
            nbp = nbp + 1; bp(nbp) = ahi(k)
         end if
      end do
      do k = 1, nb
         if (bhi(k) > blo(k)) then
            nbp = nbp + 1; bp(nbp) = blo(k)
            nbp = nbp + 1; bp(nbp) = bhi(k)
         end if
      end do
      if (nbp < 2) return
      ! insertion sort: the lists are tiny and already mostly ordered
      do p = 2, nbp
         v = bp(p)
         k = p - 1
         do while (k >= 1)
            if (bp(k) <= v) exit
            bp(k + 1) = bp(k)
            k = k - 1
         end do
         bp(k + 1) = v
      end do
      do p = 1, nbp - 1
         y0 = bp(p); y1 = bp(p + 1)
         if (y1 <= y0) cycle
         ina = .false.
         do k = 1, na
            if (alo(k) <= y0 .and. y1 <= ahi(k)) then
               ina = .true.; exit
            end if
         end do
         inb = .false.
         do k = 1, nb
            if (blo(k) <= y0 .and. y1 <= bhi(k)) then
               inb = .true.; exit
            end if
         end do
         if (ina .neqv. inb) then
            ! merge with the previous segment when contiguous
            if (ns > 0) then
               if (se0(ns) == e .and. se1(ns) == e .and. sy1(ns) == y0) then
                  sy1(ns) = y1
                  cycle
               end if
            end if
            call seg_append(se0, se1, sy0, sy1, ns, e, e, y0, y1)
         end if
      end do
   end subroutine symdiff_append

   subroutine build_chains(cs, se0, se1, sy0, sy1, ns)
      !! Link the outline segments into polyline chains by walking shared
      !! endpoints (exact equality; see `symdiff_append`).
      !! Where more than two segments meet, the walker picks any
      !! continuation: every segment is drawn exactly once either way.
      ! Arguments
      type(chainset_t), intent(inout) :: cs
         !! Receives the chains.
      integer(int32), intent(in) :: ns
         !! Number of segments.
      integer(int32), intent(in) :: se0(:), se1(:)
         !! Strip edge of each segment's first and second end.
      real(real64), intent(in) :: sy0(:), sy1(:)
         !! y of each segment's first and second end.
      logical, allocatable :: used(:)
      integer(int32), allocatable :: cnt(:), off(:), ids(:), fil(:)
      integer(int32), allocatable :: cei(:)
      real(real64), allocatable :: cy(:)
      integer(int32) :: nedge, s, e, k, cn, tmpe
      real(real64) :: tmpy

      if (ns == 0) return
      ! bucket the segments by the strip edges they touch (CSR layout)
      nedge = nmodels + 1
      allocate (used(ns)); used = .false.
      allocate (cnt(nedge), off(nedge + 1), fil(nedge))
      cnt = 0
      do s = 1, ns
         cnt(se0(s)) = cnt(se0(s)) + 1
         if (se1(s) /= se0(s)) cnt(se1(s)) = cnt(se1(s)) + 1
      end do
      off(1) = 1
      do e = 1, nedge
         off(e + 1) = off(e) + cnt(e)
      end do
      allocate (ids(off(nedge + 1) - 1))
      fil = off(1:nedge)
      do s = 1, ns
         ids(fil(se0(s))) = s; fil(se0(s)) = fil(se0(s)) + 1
         if (se1(s) /= se0(s)) then
            ids(fil(se1(s))) = s; fil(se1(s)) = fil(se1(s)) + 1
         end if
      end do

      do s = 1, ns
         if (used(s)) cycle
         used(s) = .true.
         cn = 0
         call chain_push(cei, cy, cn, se0(s), sy0(s))
         call chain_push(cei, cy, cn, se1(s), sy1(s))
         call chain_extend()
         ! reverse and extend from the other end too
         do k = 1, cn/2
            tmpe = cei(k); cei(k) = cei(cn + 1 - k); cei(cn + 1 - k) = tmpe
            tmpy = cy(k); cy(k) = cy(cn + 1 - k); cy(cn + 1 - k) = tmpy
         end do
         call chain_extend()
         call chainset_append(cs, cei, cy, cn)
      end do

   contains

      subroutine chain_extend()
         !! Extend the chain from its tail while an unused segment connects.
         integer(int32) :: et, kk, s2
         real(real64) :: yt
         logical :: found
         do
            et = cei(cn); yt = cy(cn)
            found = .false.
            do kk = off(et), off(et + 1) - 1
               s2 = ids(kk)
               if (used(s2)) cycle
               if (se0(s2) == et .and. sy0(s2) == yt) then
                  used(s2) = .true.
                  call chain_push(cei, cy, cn, se1(s2), sy1(s2))
                  found = .true.
                  exit
               else if (se1(s2) == et .and. sy1(s2) == yt) then
                  used(s2) = .true.
                  call chain_push(cei, cy, cn, se0(s2), sy0(s2))
                  found = .true.
                  exit
               end if
            end do
            if (.not. found) return
         end do
      end subroutine chain_extend
   end subroutine build_chains

   subroutine chain_push(cei, cy, cn, e, y)
      !! Append one point to a growable chain.
      ! Arguments
      integer(int32), allocatable, intent(inout) :: cei(:)
         !! Strip edge of each point.
      real(real64), allocatable, intent(inout) :: cy(:)
         !! y of each point.
      integer(int32), intent(inout) :: cn
         !! Number of points, incremented.
      integer(int32), intent(in) :: e
         !! Strip edge of the new point.
      real(real64), intent(in) :: y
         !! y of the new point.
      cn = cn + 1
      call grow_i32(cei, cn)
      call grow_r64(cy, cn)
      cei(cn) = e; cy(cn) = y
   end subroutine chain_push

   subroutine chainset_clear(cs)
      !! Drop every chain of a set.
      ! Arguments
      type(chainset_t), intent(inout) :: cs
         !! The chain set.
      if (allocated(cs%c)) deallocate (cs%c)
      cs%nc = 0
   end subroutine chainset_clear

   subroutine chainset_append(cs, cei, cy, cn)
      !! Store one chain (grow-by-doubling, like `bandset_append`). A chain
      !! of fewer than two points is dropped.
      ! Arguments
      type(chainset_t), intent(inout) :: cs
         !! The chain set.
      integer(int32), intent(in) :: cei(:), cn
         !! Strip edge of each point; number of points.
      real(real64), intent(in) :: cy(:)
         !! y of each point.
      type(chain_t), allocatable :: tmp(:)
      integer(int32) :: cap
      if (cn < 2) return
      if (.not. allocated(cs%c)) allocate (cs%c(8))
      cap = int(size(cs%c), int32)
      if (cs%nc == cap) then
         allocate (tmp(2*cap))
         tmp(1:cap) = cs%c
         call move_alloc(tmp, cs%c)
      end if
      cs%nc = cs%nc + 1
      cs%c(cs%nc)%n = cn
      cs%c(cs%nc)%ei = cei(1:cn)
      cs%c(cs%nc)%y = cy(1:cn)
   end subroutine chainset_append

   !---------------------------------------------------------------------
   ! growable arrays

   subroutine grow_i32(a, need)
      !! Make room for `need` entries, keeping the contents: the capacity
      !! doubles when needed, and a new array starts at `max(need, 64)`.
      ! Arguments
      integer(int32), allocatable, intent(inout) :: a(:)
         !! The array.
      integer(int32), intent(in) :: need
         !! Number of entries needed.
      integer(int32), allocatable :: tmp(:)
      integer(int32) :: cap
      if (.not. allocated(a)) then
         allocate (a(max(need, 64_int32)))
         return
      end if
      cap = int(size(a), int32)
      if (need <= cap) return
      allocate (tmp(max(need, 2*cap)))
      tmp(1:cap) = a
      call move_alloc(tmp, a)
   end subroutine grow_i32

   subroutine grow_r64(a, need)
      !! Real counterpart of `grow_i32`.
      ! Arguments
      real(real64), allocatable, intent(inout) :: a(:)
         !! The array.
      integer(int32), intent(in) :: need
         !! Number of entries needed.
      real(real64), allocatable :: tmp(:)
      integer(int32) :: cap
      if (.not. allocated(a)) then
         allocate (a(max(need, 64_int32)))
         return
      end if
      cap = int(size(a), int32)
      if (need <= cap) return
      allocate (tmp(max(need, 2*cap)))
      tmp(1:cap) = a
      call move_alloc(tmp, a)
   end subroutine grow_r64

end module bands
