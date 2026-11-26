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

! test_bands.f90 -- unit tests for the public procedures of bands.f90
!
! expected values are worked by hand from the docstrings in bands.f90.
! the seam case follows the `build_conv_cache` docstring in layers.f90.
! the order of stored bands and the walk order of chains are not documented.
! so bands are looked up by model range, and chains are checked segment by segment.
! every failed check is printed, and the program ends in error stop so meson reports a failure.
program test_bands

   use typedef, only: int32, real64
   use kipp_state, only: nmodels
   use bands, only: tracer_t, bandset_t, chainset_t, tracer_alloc, tracer_dealloc, &
      tracer_reset, tracer_step, tracer_flush, bandset_clear, seg_append, symdiff_append, &
      build_chains, chainset_clear
   implicit none

   real(real64), parameter :: NONE(0) = [real(real64) ::]

   integer(int32) :: nfail = 0

   call test_tracer()
   call test_symdiff()
   call test_chains()

   if (nfail > 0) then
      print '(i0,a)', nfail, ' check(s) failed'
      error stop 1
   end if
   print '(a)', 'bands ok'

contains

   ! intervals match an open band of model i - 1 by overlap.
   ! unmatched intervals open new bands, and bands with no continuation are stored.
   subroutine test_tracer()
      type(tracer_t) :: tr
      type(bandset_t) :: bs
      integer(int32) :: i, k
      real(real64) :: y

      call tracer_alloc(tr, 4, 10)

      ! overlap extends the band, which is stored at the flush
      call tracer_step(tr, bs, 1, [0.d0], [2.d0], 1)
      call tracer_step(tr, bs, 2, [1.d0], [3.d0], 1)
      call tracer_step(tr, bs, 3, [2.5d0], [4.d0], 1)
      call check_int(bs%nb, 0, 'extend: stored before the flush')
      call tracer_flush(tr, bs)
      call check_int(bs%nb, 1, 'extend: bands')
      call check_band(bs, 1, 3, [0.d0, 1.d0, 2.5d0], [2.d0, 3.d0, 4.d0], 'extend')

      ! no overlap: the band is stored at model 2 and a new one opens
      call bandset_clear(bs)
      call tracer_step(tr, bs, 1, [0.d0], [1.d0], 1)
      call tracer_step(tr, bs, 2, [2.d0], [3.d0], 1)
      call check_int(bs%nb, 1, 'no overlap: stored at model 2')
      call check_band(bs, 1, 1, [0.d0], [1.d0], 'no overlap')
      call tracer_flush(tr, bs)
      call check_int(bs%nb, 2, 'no overlap: bands')
      call check_band(bs, 2, 2, [2.d0], [3.d0], 'no overlap')

      ! split: a band holds one interval per model, so the second interval opens a band
      call bandset_clear(bs)
      call tracer_step(tr, bs, 1, [0.d0], [10.d0], 1)
      call tracer_step(tr, bs, 2, [0.d0, 5.d0], [2.d0, 7.d0], 2)
      call tracer_flush(tr, bs)
      call check_int(bs%nb, 2, 'split: bands')
      call check_band(bs, 1, 2, [0.d0, 0.d0], [10.d0, 2.d0], 'split')
      call check_band(bs, 2, 2, [5.d0], [7.d0], 'split')

      ! merge: one band continues and the other is stored.
      ! which band continues is not documented, so only model 2 of the continued band is checked.
      call bandset_clear(bs)
      call tracer_step(tr, bs, 1, [0.d0, 5.d0], [2.d0, 7.d0], 2)
      call tracer_step(tr, bs, 2, [0.d0], [10.d0], 1)
      call check_int(bs%nb, 1, 'merge: stored at model 2')
      call tracer_flush(tr, bs)
      call check_int(bs%nb, 2, 'merge: bands')
      call check(find_band(bs, 1, 1) > 0, 'merge: band (1,1) stored')
      k = find_band(bs, 1, 2)
      call check(k > 0, 'merge: band (1,2) stored')
      if (k > 0) call check(bs%b(k)%ylo(2) == 0.d0 .and. bs%b(k)%yhi(2) == 10.d0, &
                            'merge: band (1,2) interfaces at model 2')

      ! a model without intervals stores every open band
      call bandset_clear(bs)
      call tracer_step(tr, bs, 1, [0.d0], [1.d0], 1)
      call tracer_step(tr, bs, 2, NONE, NONE, 0)
      call check_int(bs%nb, 1, 'empty model: stored at model 2')
      call tracer_step(tr, bs, 3, [0.d0], [1.d0], 1)
      call tracer_flush(tr, bs)
      call check_int(bs%nb, 2, 'empty model: bands')
      call check_band(bs, 1, 1, [0.d0], [1.d0], 'empty model')
      call check_band(bs, 3, 3, [0.d0], [1.d0], 'empty model')

      ! reset drops open bands without storing them, so the flush stores only the new feature
      call bandset_clear(bs)
      call tracer_step(tr, bs, 1, [0.d0], [1.d0], 1)
      call tracer_step(tr, bs, 2, [0.5d0], [2.d0], 1)
      call tracer_reset(tr)
      call check_int(bs%nb, 0, 'reset: stored by the reset')
      call tracer_step(tr, bs, 1, [5.d0], [6.d0], 1)
      call tracer_flush(tr, bs)
      call check_int(bs%nb, 1, 'reset: bands')
      call check_band(bs, 1, 1, [5.d0], [6.d0], 'reset')

      ! ten bands, past the first array doubling of a band set (initial capacity 8)
      call bandset_clear(bs)
      do i = 1, 10
         y = 2*mod(i + 1, 2)
         call tracer_step(tr, bs, i, [y], [y + 1], 1)
      end do
      call tracer_flush(tr, bs)
      call check_int(bs%nb, 10, 'growth: bands')
      do i = 1, 10
         y = 2*mod(i + 1, 2)
         call check_band(bs, i, i, [y], [y + 1], 'growth')
      end do

      call tracer_dealloc(tr)
   end subroutine test_tracer

   ! vertical segments at strip edge e span the y covered by exactly one of the two interval sets
   subroutine test_symdiff()
      integer(int32), allocatable :: se0(:), se1(:)
      real(real64), allocatable :: sy0(:), sy1(:)
      real(real64) :: bp(16)
      integer(int32) :: ns

      ! partial overlap: the one-sided spans below and above the overlap
      ns = 0
      call symdiff_append([0.d0], [2.d0], 1, [1.d0], [3.d0], 1, 2, bp, se0, se1, sy0, sy1, ns)
      call check_int(ns, 2, 'overlap: segments')
      call check_int(count_seg(2, 2, 0.d0, 1.d0, se0, se1, sy0, sy1, ns), 1, 'overlap: (2,0)-(2,1)')
      call check_int(count_seg(2, 2, 2.d0, 3.d0, se0, se1, sy0, sy1, ns), 1, 'overlap: (2,2)-(2,3)')

      ! identical sets are covered on both sides, so a seam adds no segment
      ns = 0
      call symdiff_append([0.d0, 2.d0], [1.d0, 3.d0], 2, [0.d0, 2.d0], [1.d0, 3.d0], 2, 2, bp, &
                          se0, se1, sy0, sy1, ns)
      call check_int(ns, 0, 'seam: segments')

      ! contiguous spans at one edge form one segment, but spans at different edges do not join
      ns = 0
      call symdiff_append(NONE, NONE, 0, [-1.d0], [0.d0], 1, 1, bp, se0, se1, sy0, sy1, ns)
      call symdiff_append([0.d0, 1.d0], [1.d0, 2.d0], 2, NONE, NONE, 0, 2, bp, se0, se1, sy0, sy1, ns)
      call check_int(ns, 2, 'contiguous: segments')
      call check_int(count_seg(1, 1, -1.d0, 0.d0, se0, se1, sy0, sy1, ns), 1, 'contiguous: (1,-1)-(1,0)')
      call check_int(count_seg(2, 2, 0.d0, 2.d0, se0, se1, sy0, sy1, ns), 1, 'contiguous: (2,0)-(2,2)')

      ! a zero-width interval covers no span, so it neither adds nor splits a segment
      ns = 0
      call symdiff_append([0.d0], [2.d0], 1, [1.d0], [1.d0], 1, 2, bp, se0, se1, sy0, sy1, ns)
      call check_int(ns, 1, 'zero width: segments')
      call check_int(count_seg(2, 2, 0.d0, 2.d0, se0, se1, sy0, sy1, ns), 1, 'zero width: (2,0)-(2,2)')
   end subroutine test_symdiff

   ! segments are linked into chains through shared endpoints
   subroutine test_chains()
      type(chainset_t) :: cs
      integer(int32), allocatable :: se0(:), se1(:)
      real(real64), allocatable :: sy0(:), sy1(:)
      integer(int32) :: ns

      ! one model with one interval gives one closed outline
      nmodels = 1
      ns = 0
      call add_rect(1, 0.d0, 1.d0, se0, se1, sy0, sy1, ns)
      call build_chains(cs, se0, se1, sy0, sy1, ns)
      call check_int(cs%nc, 1, 'rectangle: chains')
      call check_chains(cs, se0, se1, sy0, sy1, ns, 'rectangle')

      nmodels = 3
      ns = 0
      call chainset_clear(cs)
      call add_rect(1, 0.d0, 1.d0, se0, se1, sy0, sy1, ns)
      call add_rect(3, 0.d0, 1.d0, se0, se1, sy0, sy1, ns)
      call build_chains(cs, se0, se1, sy0, sy1, ns)
      call check_int(cs%nc, 2, 'two rectangles: chains')
      call check_chains(cs, se0, se1, sy0, sy1, ns, 'two rectangles')

      ! rectangles touching at the corner (2, 1), where four segments meet
      nmodels = 2
      ns = 0
      call chainset_clear(cs)
      call add_rect(1, 0.d0, 1.d0, se0, se1, sy0, sy1, ns)
      call add_rect(2, 1.d0, 2.d0, se0, se1, sy0, sy1, ns)
      call build_chains(cs, se0, se1, sy0, sy1, ns)
      call check_chains(cs, se0, se1, sy0, sy1, ns, 'corner')
   end subroutine test_chains

   ! append the four outline segments of model i's strip between y0 and y1
   subroutine add_rect(i, y0, y1, se0, se1, sy0, sy1, ns)
      integer(int32), intent(in) :: i
      real(real64), intent(in) :: y0, y1
      integer(int32), allocatable, intent(inout) :: se0(:), se1(:)
      real(real64), allocatable, intent(inout) :: sy0(:), sy1(:)
      integer(int32), intent(inout) :: ns
      call seg_append(se0, se1, sy0, sy1, ns, i, i, y0, y1)
      call seg_append(se0, se1, sy0, sy1, ns, i + 1, i + 1, y0, y1)
      call seg_append(se0, se1, sy0, sy1, ns, i, i + 1, y0, y0)
      call seg_append(se0, se1, sy0, sy1, ns, i, i + 1, y1, y1)
   end subroutine add_rect

   ! every segment is drawn exactly once across the chains (build_chains docstring)
   subroutine check_chains(cs, se0, se1, sy0, sy1, ns, what)
      type(chainset_t), intent(in) :: cs
      integer(int32), intent(in) :: se0(:), se1(:), ns
      real(real64), intent(in) :: sy0(:), sy1(:)
      character(len=*), intent(in) :: what
      integer(int32), allocatable :: pe0(:), pe1(:)
      real(real64), allocatable :: py0(:), py1(:)
      integer(int32) :: np, c, k, s
      character(len=64) :: msg
      np = 0
      do c = 1, cs%nc
         do k = 1, cs%c(c)%n - 1
            call seg_append(pe0, pe1, py0, py1, np, cs%c(c)%ei(k), cs%c(c)%ei(k + 1), &
                            cs%c(c)%y(k), cs%c(c)%y(k + 1))
         end do
      end do
      call check_int(np, ns, what//': segments drawn')
      if (np == 0) return
      do s = 1, ns
         write (msg, '(2a,i0)') what, ': times drawn, segment ', s
         call check_int(count_seg(se0(s), se1(s), sy0(s), sy1(s), pe0, pe1, py0, py1, np), 1, trim(msg))
      end do
   end subroutine check_chains

   ! number of segments joining (e0, y0) and (e1, y1), in either direction
   integer(int32) function count_seg(e0, e1, y0, y1, se0, se1, sy0, sy1, ns) result(n)
      integer(int32), intent(in) :: e0, e1, ns, se0(:), se1(:)
      real(real64), intent(in) :: y0, y1, sy0(:), sy1(:)
      integer(int32) :: k
      n = 0
      do k = 1, ns
         if (se0(k) == e0 .and. se1(k) == e1 .and. sy0(k) == y0 .and. sy1(k) == y1) n = n + 1
         if (se0(k) == e1 .and. se1(k) == e0 .and. sy0(k) == y1 .and. sy1(k) == y0) n = n + 1
      end do
   end function count_seg

   ! index of the band over models i0 to i1, 0 if none is stored
   integer(int32) function find_band(bs, i0, i1) result(k)
      type(bandset_t), intent(in) :: bs
      integer(int32), intent(in) :: i0, i1
      do k = 1, bs%nb
         if (bs%b(k)%i0 == i0 .and. bs%b(k)%i1 == i1) return
      end do
      k = 0
   end function find_band

   subroutine check_band(bs, i0, i1, ylo, yhi, what)
      type(bandset_t), intent(in) :: bs
      integer(int32), intent(in) :: i0, i1
      real(real64), intent(in) :: ylo(:), yhi(:)
      character(len=*), intent(in) :: what
      character(len=64) :: msg
      integer(int32) :: k
      write (msg, '(2a,i0,a,i0,a)') what, ': band (', i0, ',', i1, ')'
      k = find_band(bs, i0, i1)
      call check(k > 0, trim(msg)//' stored')
      if (k == 0) return
      if (size(bs%b(k)%ylo) /= size(ylo) .or. size(bs%b(k)%yhi) /= size(yhi)) then
         call check(.false., trim(msg)//' length')
         return
      end if
      call check(all(bs%b(k)%ylo == ylo) .and. all(bs%b(k)%yhi == yhi), trim(msg)//' interfaces')
   end subroutine check_band

   subroutine check(ok, what)
      logical, intent(in) :: ok
      character(len=*), intent(in) :: what
      if (ok) return
      nfail = nfail + 1
      print '(2a)', 'FAIL ', what
   end subroutine check

   subroutine check_int(got, want, what)
      integer(int32), intent(in) :: got, want
      character(len=*), intent(in) :: what
      if (got == want) return
      nfail = nfail + 1
      print '(3a,i0,a,i0)', 'FAIL ', what, ': got ', got, ', want ', want
   end subroutine check_int

end program test_bands
