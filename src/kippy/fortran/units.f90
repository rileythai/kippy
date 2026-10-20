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

! units.f90 -- physical units for the axes and colorbar titles
!
! every reader stores time, mass and radius in cgs; a plotted axis divides by
! its display unit's factor.  colour-field units are labels only: an explicit
! .kipp header token, else a unit suffix on the column name, typeset with
! negative exponents (g/cm^3 -> g cm^{-3}).  axis_offset is matplotlib's
! ScalarFormatter offset (ticker.py _compute_offset, matplotlib 3.10,
! PSF-based BSD-compatible licence) with the offset printed in a coarser unit.
module units

   use iso_c_binding, only: c_double
   use typedef, only: int32, int64, real64

   implicit none
   private

   real(real64), parameter, public :: SOLMASS = 1.9892d33      ! g
   real(real64), parameter, public :: SOLRAD = 6.9599d10       ! cm
   real(real64), parameter, public :: YR = 31556952.d0         ! s (Gregorian year)

   integer(int32), parameter, public :: DIM_TIME = 1, DIM_MASS = 2, DIM_LENGTH = 3
   integer(int32), parameter, public :: NUNITS = 15
   character(len=4), parameter, public :: UNAME(NUNITS) = [character(len=4) :: &
      's', 'min', 'hr', 'd', 'yr', 'kyr', 'Myr', 'Gyr', &
      'g', 'kg', 'Msun', &
      'cm', 'm', 'km', 'Rsun']
   integer(int32), parameter, public :: UDIM(NUNITS) = [ &
      DIM_TIME, DIM_TIME, DIM_TIME, DIM_TIME, DIM_TIME, DIM_TIME, DIM_TIME, DIM_TIME, &
      DIM_MASS, DIM_MASS, DIM_MASS, &
      DIM_LENGTH, DIM_LENGTH, DIM_LENGTH, DIM_LENGTH]
   real(real64), parameter, public :: UFAC(NUNITS) = [ &
      1.d0, 60.d0, 3600.d0, 86400.d0, YR, 1.d3*YR, 1.d6*YR, 1.d9*YR, &
      1.d0, 1.d3, SOLMASS, &
      1.d0, 1.d2, 1.d5, SOLRAD]
   character(len=8), parameter, public :: ULABEL(NUNITS) = [character(len=8) :: &
      's', 'min', 'hr', 'd', 'yr', 'kyr', 'Myr', 'Gyr', &
      'g', 'kg', 'M_\odot', &
      'cm', 'm', 'km', 'R_\odot']
   ! yr .. Gyr step by 1000, so an offset moves between them exactly
   integer(int32), parameter :: IYR = 5, IGYR = 8

   ! name suffixes read as units when the header gives none, longest first
   integer(int32), parameter :: NSUF = 8
   character(len=7), parameter :: SUF(NSUF) = [character(len=7) :: &
      'erg_g_s', 'erg_s', 'gcc', 'yr', 'cm', 'K', 'g', 's']
   character(len=7), parameter :: SUFUNIT(NSUF) = [character(len=7) :: &
      'erg/g/s', 'erg/s', 'g/cc', 'yr', 'cm', 'K', 'g', 's']

   ! giza's Greek-letter tokens (giza-token-remapper.h)
   integer(int32), parameter :: NGREEK = 47
   character(len=7), parameter :: GREEK(NGREEK) = [character(len=7) :: 'nabla', &
      'alpha', 'beta', 'gamma', 'delta', 'epsilon', 'zeta', 'eta', 'theta', &
      'iota', 'kappa', 'lambda', 'mu', 'nu', 'xi', 'omicron', 'pi', 'rho', &
      'sigma', 'tau', 'phi', 'chi', 'psi', 'omega', &
      'Alpha', 'Beta', 'Gamma', 'Delta', 'Epsilon', 'Zeta', 'Eta', 'Theta', &
      'Iota', 'Kappa', 'Lambda', 'Mu', 'Nu', 'Xi', 'Omicron', 'Pi', 'Rho', &
      'Sigma', 'Tau', 'Phi', 'Chi', 'Psi', 'Omega']

   interface
      pure function c_fmod(x, y) bind(C, name='fmod') result(r)
         import :: c_double
         real(c_double), value :: x, y
         real(c_double) :: r
      end function c_fmod
   end interface

   public :: unit_id, quantity_label, axis_offset

contains

   ! index into UNAME of a unit name (any case, a few spelled-out aliases),
   ! or 0 if unknown
   pure function unit_id(name) result(k)
      character(len=*), intent(in) :: name
      integer(int32) :: k
      character(len=32) :: s
      s = lower(adjustl(name))
      select case (trim(s))
      case ('sec'); s = 's'
      case ('h', 'hour'); s = 'hr'
      case ('day'); s = 'd'
      case ('year'); s = 'yr'
      case ('msol'); s = 'msun'
      case ('rsol'); s = 'rsun'
      end select
      do k = 1, NUNITS
         if (trim(s) == lower(trim(UNAME(k)))) return
      end do
      k = 0
   end function unit_id

   ! colorbar title parts for a column: the name without its unit suffix
   ! ('_' shown as a space, giza has no escape for it; a Greek-letter name as
   ! its glyph) and the unit typeset for giza, blank when there is none.  an
   ! explicit header unit wins over the suffix.
   pure subroutine quantity_label(name, unit, base, ulab)
      character(len=*), intent(in) :: name, unit
      character(len=*), intent(out) :: base, ulab
      character(len=len(name)) :: b
      character(len=64) :: u
      integer(int32) :: k, n
      b = name; u = unit
      n = len_trim(name)
      do k = 1, NSUF
         if (n <= len_trim(SUF(k)) + 1) cycle
         if (name(n - len_trim(SUF(k)):n) == '_'//trim(SUF(k))) then
            b = name(1:n - len_trim(SUF(k)) - 1)
            if (len_trim(unit) == 0) u = SUFUNIT(k)
            exit
         end if
      end do
      base = b
      if (any(GREEK == b)) base = '\'//b
      do while (index(base, '_') > 0)
         base(index(base, '_'):index(base, '_')) = ' '
      end do
      ulab = ''
      if (len_trim(u) > 0) ulab = unit_tex(u)
   end subroutine quantity_label

   ! typeset a/b^n/c as 'a b^{-n} c^{-1}'; anything else is returned verbatim
   pure function unit_tex(u) result(t)
      character(len=*), intent(in) :: u
      character(len=96) :: t
      character(len=64) :: rest, seg, base, ex
      character(len=*), parameter :: LETTERS = &
         'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ'
      integer(int32) :: p, nb, e, ios, nseg

      t = ''; nseg = 0
      rest = adjustl(u)
      if (trim(rest) == 'gcc') rest = 'g/cc'
      do
         nseg = nseg + 1
         p = index(rest, '/')
         if (p == 0) then
            seg = rest
         else
            seg = rest(1:p - 1)
         end if
         nb = verify(seg, LETTERS) - 1
         if (nb < 0) nb = len_trim(seg)
         if (nb == 0) then
            if (nseg /= 1 .or. trim(seg) /= '1') then
               t = u
               return
            end if
         else
            base = seg(1:nb)
            ex = seg(nb + 1:)
            if (ex(1:1) == '^') ex = ex(2:)
            if (ex(1:1) == '{' .and. index(ex, '}') == len_trim(ex)) ex = ex(2:len_trim(ex) - 1)
            e = 1
            if (len_trim(ex) > 0) then
               ios = 1
               if (verify(trim(ex), '+-0123456789') == 0) read (ex, *, iostat=ios) e
               if (ios /= 0) then
                  t = u
                  return
               end if
            end if
            if (nseg > 1) e = -e
            select case (trim(base))
            case ('cc'); base = 'cm'; e = 3*e
            case ('Msun'); base = 'M_\odot'
            case ('Rsun'); base = 'R_\odot'
            case ('Lsun'); base = 'L_\odot'
            end select
            if (len_trim(t) > 0) then
               t = trim(t)//' '//trim(base)
            else
               t = base
            end if
            if (e /= 1) then
               write (ex, '(i0)') e
               t = trim(t)//'^{'//trim(ex)//'}'
            end if
         end if
         if (p == 0) exit
         rest = rest(p + 1:)
      end do
   end function unit_tex

   ! matplotlib's ScalarFormatter offset for the view [lo, hi] in tick unit
   ! UNAME(k), taken from the view limits rather than tick positions: the
   ! highest decade at which lo and hi agree, used only when it saves at
   ! least four digits.  txt is the offset as matplotlib shows it ('+...'),
   ! in the largest of yr .. Gyr in which it is at least 1 when the ticks are
   ! in one of those, else in the tick unit.  off = 0 and txt = '' when no
   ! offset applies.
   pure subroutine axis_offset(lo, hi, k, off, txt)
      real(real64), intent(in) :: lo, hi
      integer(int32), intent(in) :: k
      real(real64), intent(out) :: off
      character(len=*), intent(out) :: txt
      real(real64) :: amin, amax, sgn, oommax, oom, n
      character(len=24) :: digits
      integer(int32) :: u, q

      off = 0.d0; txt = ''
      if (lo == hi .or. (min(lo, hi) <= 0.d0 .and. max(lo, hi) >= 0.d0)) return
      amin = min(abs(lo), abs(hi)); amax = max(abs(lo), abs(hi))
      sgn = sign(1.d0, min(lo, hi))
      oommax = real(ceiling(log10(amax)), real64)
      oom = oommax
      do while (floordiv(amin, 10.d0**oom) == floordiv(amax, 10.d0**oom))
         oom = oom - 1.d0
      end do
      oom = oom + 1.d0
      ! straddling a multiple of a large power of ten (relative to the span)
      if ((amax - amin)/10.d0**oom <= 1.d-2) then
         oom = oommax
         do while (floordiv(amax, 10.d0**oom) - floordiv(amin, 10.d0**oom) <= 1.d0)
            oom = oom - 1.d0
         end do
         oom = oom + 1.d0
      end if
      n = floordiv(amax, 10.d0**oom)
      if (n < 1.d3) return
      off = sgn*n*10.d0**oom

      ! the offset is n x 10^q in unit u
      write (digits, '(i0)') int(n, int64)
      u = k; q = int(oom, int32)
      if (k >= IYR .and. k <= IGYR) then
         do u = IGYR, IYR, -1
            if (len_trim(digits) - 1 + q + 3*(k - u) >= 0) exit
         end do
         u = max(u, IYR)
         q = q + 3*(k - u)
      end if
      txt = merge('+', '-', sgn > 0.d0)//trim(fmt_number(trim(digits), q))//' '//trim(ULABEL(u))
   end subroutine axis_offset

   ! python's float floor division (CPython float_floor_div) for a, b > 0,
   ! so axis_offset picks the same decades as matplotlib
   pure function floordiv(a, b) result(f)
      real(real64), intent(in) :: a, b
      real(real64) :: f, d
      d = (a - c_fmod(a, b))/b
      f = aint(d)
      if (d - f > 0.5d0) f = f + 1.d0
   end function floordiv

   ! the number digits x 10^p as giza_format_number writes it in its auto
   ! form, for a mantissa beyond giza's c int
   pure function fmt_number(digits, p) result(s)
      character(len=*), intent(in) :: digits
      integer(int32), intent(in) :: p
      character(len=64) :: s
      character(len=32) :: d, ex
      integer(int32) :: nd, pw, dbp

      d = digits; pw = p
      nd = len_trim(d)
      do while (nd > 1 .and. d(nd:nd) == '0')
         d(nd:nd) = ' '
         nd = nd - 1
         pw = pw + 1
      end do
      dbp = nd + min(pw, 0)
      if (pw >= 0 .and. pw + nd <= 4) then
         s = trim(d)//repeat('0', pw)
         return
      else if (dbp >= 1 .and. dbp <= 4 .and. dbp < nd) then
         s = d(1:dbp)//'.'//d(dbp + 1:nd)
         return
      end if
      pw = pw + nd - 1
      if (pw == -1 .or. pw == -2) then
         d = repeat('0', -pw)//d
         nd = nd - pw
         pw = 0
      end if
      s = d(1:1)
      if (nd > 1) s = d(1:1)//'.'//d(2:nd)
      if (pw /= 0) then
         write (ex, '(i0)') pw
         s = trim(s)//'\times10^{'//trim(ex)//'}'
      end if
   end function fmt_number

   pure function lower(s) result(t)
      character(len=*), intent(in) :: s
      character(len=len(s)) :: t
      integer(int32) :: i, c
      t = s
      do i = 1, len(s)
         c = iachar(s(i:i))
         if (c >= iachar('A') .and. c <= iachar('Z')) t(i:i) = achar(c + 32)
      end do
   end function lower

end module units
