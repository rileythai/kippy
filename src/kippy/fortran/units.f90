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
module units
   !! Physical units of the plot axes and the colorbar titles.
   !!
   !! Every reader stores time, mass and radius in cgs.
   !! A plotted axis then divides by the factor `UFAC` of its display unit.
   !! Colour-field units are labels only.
   !! The label are fetched from units given by `.kipp` header, or a unit suffix on the column name.
   !!
   !! Labels are typeset with negative exponents (i.e., `g/cm^3` shows as `g cm^{-3}`).
   !! `axis_offset` is the offset of matplotlib's `ScalarFormatter`, printed in a coarser unit.
   !! It is derived from follows `_compute_offset` in matplotlib 3.10 `ticker.py`
   !!
   !! axes.f90, coords.f90, cursor.f90, draw.f90 and kipp.f90 scale and label the axes with it.
   !! mesaload.f90 converts `.kipp` axis columns to cgs with `unit_id` and `UFAC`.
   !! convbuild.f90 re-exports the solar constants and the year.

   use iso_c_binding, only: c_double
   use typedef, only: int32, int64, real64

   implicit none
   private

   real(real64), parameter, public :: SOLMASS = 1.9892d33
      !! Solar mass (g).
   real(real64), parameter, public :: SOLRAD = 6.9599d10
      !! Solar radius (cm).
   real(real64), parameter, public :: YR = 31556952.d0
      !! Gregorian year (s).

   integer(int32), parameter, public :: DIM_TIME = 1, DIM_MASS = 2, DIM_LENGTH = 3
      !! Dimension codes of `UDIM`: time, mass and length.
   integer(int32), parameter, public :: NUNITS = 15
      !! Number of display units.
   character(len=4), parameter, public :: UNAME(NUNITS) = [character(len=4) :: &
      's', 'min', 'hr', 'd', 'yr', 'kyr', 'Myr', 'Gyr', &
      'g', 'kg', 'Msun', &
      'cm', 'm', 'km', 'Rsun']
      !! Unit names as the `units` command takes them (docs/commands.md).
   integer(int32), parameter, public :: UDIM(NUNITS) = [ &
      DIM_TIME, DIM_TIME, DIM_TIME, DIM_TIME, DIM_TIME, DIM_TIME, DIM_TIME, DIM_TIME, &
      DIM_MASS, DIM_MASS, DIM_MASS, &
      DIM_LENGTH, DIM_LENGTH, DIM_LENGTH, DIM_LENGTH]
      !! Dimension code of each unit.
   real(real64), parameter, public :: UFAC(NUNITS) = [ &
      1.d0, 60.d0, 3600.d0, 86400.d0, YR, 1.d3*YR, 1.d6*YR, 1.d9*YR, &
      1.d0, 1.d3, SOLMASS, &
      1.d0, 1.d2, 1.d5, SOLRAD]
      !! Size of each unit in cgs.
   character(len=8), parameter, public :: ULABEL(NUNITS) = [character(len=8) :: &
      's', 'min', 'hr', 'd', 'yr', 'kyr', 'Myr', 'Gyr', &
      'g', 'kg', 'M_\odot', &
      'cm', 'm', 'km', 'R_\odot']
      !! Axis label of each unit in giza markup.
   integer(int32), parameter :: IYR = 5, IGYR = 8
      !! `UNAME` indices of `yr` and `Gyr`.
      !! The units from `yr` to `Gyr` step by 1000, so an offset moves between them exactly.

   integer(int32), parameter :: NSUF = 8
      !! Number of unit suffixes.
   character(len=7), parameter :: SUF(NSUF) = [character(len=7) :: &
      'erg_g_s', 'erg_s', 'gcc', 'yr', 'cm', 'K', 'g', 's']
      !! Column-name suffixes read as units when the header states none.
      !! Longest first, so `_erg_g_s` is tried before `_s`.
   character(len=7), parameter :: SUFUNIT(NSUF) = [character(len=7) :: &
      'erg/g/s', 'erg/s', 'g/cc', 'yr', 'cm', 'K', 'g', 's']
      !! Unit of each suffix in `SUF`.

   integer(int32), parameter :: NGREEK = 47
      !! Number of Greek-letter tokens.
   character(len=7), parameter :: GREEK(NGREEK) = [character(len=7) :: 'nabla', &
      'alpha', 'beta', 'gamma', 'delta', 'epsilon', 'zeta', 'eta', 'theta', &
      'iota', 'kappa', 'lambda', 'mu', 'nu', 'xi', 'omicron', 'pi', 'rho', &
      'sigma', 'tau', 'phi', 'chi', 'psi', 'omega', &
      'Alpha', 'Beta', 'Gamma', 'Delta', 'Epsilon', 'Zeta', 'Eta', 'Theta', &
      'Iota', 'Kappa', 'Lambda', 'Mu', 'Nu', 'Xi', 'Omicron', 'Pi', 'Rho', &
      'Sigma', 'Tau', 'Phi', 'Chi', 'Psi', 'Omega']
      !! giza's Greek-letter tokens (giza-token-remapper.h), written `\<name>`.

   interface
      pure function c_fmod(x, y) bind(C, name='fmod') result(r)
         !! Return the floating-point remainder of `x/y`, with C `fmod`.
         import :: c_double
         real(c_double), value :: x
            !! Dividend.
         real(c_double), value :: y
            !! Divisor.
         real(c_double) :: r
      end function c_fmod
   end interface

   public :: unit_id, quantity_label, axis_offset, auto_time_unit

contains

   pure function unit_id(name) result(k)
      !! Return the `UNAME` index of a unit name, or 0 when it is unknown.
      !!
      !! Names match in any case.
      !! A few spelled-out aliases are accepted (`sec`, `hour`, `day`, `year`, `msol`, `rsol`).
      ! Arguments
      character(len=*), intent(in) :: name
         !! Unit name.
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

   pure function auto_time_unit(span_sec) result(k)
      !! Return the largest time unit in which a span is at least 1.
      !!
      !! The result is a `UNAME` index from `s` to `Gyr`, and `s` when no unit fits.
      !! This is the automatic time unit of `units auto` (docs/commands.md).
      ! Arguments
      real(real64), intent(in) :: span_sec
         !! Visible time span (s).
      integer(int32) :: k
      do k = IGYR, 2, -1
         if (span_sec >= UFAC(k)) return
      end do
      k = 1
   end function auto_time_unit

   pure subroutine quantity_label(name, unit, base, ulab)
      !! Split a column into the two parts of its colorbar title.
      !!
      !! The base is the name without its unit suffix.
      !! An underscore shows as a space, since giza has no escape for it.
      !! A Greek-letter name shows as its glyph.
      !! The unit is typeset for giza, and blank when there is none.
      !! A unit the header states wins over the suffix ("Unit recognition", docs/formats.md).
      ! Arguments
      character(len=*), intent(in) :: name
         !! Column name.
      character(len=*), intent(in) :: unit
         !! Unit the header states for the column, blank if none.
      character(len=*), intent(out) :: base
         !! Title text of the name, in giza markup.
      character(len=*), intent(out) :: ulab
         !! Typeset unit, blank if none.
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

   pure function unit_tex(u) result(t)
      !! Typeset a unit with negative exponents.
      !!
      !! `a/b^n/c` becomes `a b^{-n} c^{-1}`.
      !! `cc` reads as `cm^3`, and `Msun`, `Rsun` and `Lsun` become solar symbols.
      !! A unit of any other form is returned as written.
      ! Arguments
      character(len=*), intent(in) :: u
         !! Unit as the header or suffix gives it.
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

   pure subroutine axis_offset(lo, hi, k, off, txt)
      !! Find matplotlib's `ScalarFormatter` offset of a linear time axis.
      !!
      !! The offset is taken from the view limits rather than the tick positions.
      !! It is the highest decade at which `lo` and `hi` agree.
      !! It is used only when it saves at least four digits.
      !! The text is in the largest of `yr` to `Gyr` in which the offset is at least 1
      !! when the ticks are in one of those, else in the tick unit (`offset`, docs/commands.md).
      ! Arguments
      real(real64), intent(in) :: lo
         !! Lower view limit, in the tick unit.
      real(real64), intent(in) :: hi
         !! Upper view limit, in the tick unit.
      integer(int32), intent(in) :: k
         !! `UNAME` index of the tick unit.
      real(real64), intent(out) :: off
         !! Offset in the tick unit, 0 when no offset applies.
      character(len=*), intent(out) :: txt
         !! Offset as matplotlib shows it (`+...` and a unit label), blank when none applies.
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

   pure function floordiv(a, b) result(f)
      !! Return Python's float floor division `a // b` for `a, b > 0`.
      !!
      !! It follows CPython `float_floor_div`, so `axis_offset` picks the EXACT same 
      !! decades as matplotlib.
      ! Arguments
      real(real64), intent(in) :: a
         !! Dividend.
      real(real64), intent(in) :: b
         !! Divisor.
      real(real64) :: f, d
      d = (a - c_fmod(a, b))/b
      f = aint(d)
      if (d - f > 0.5d0) f = f + 1.d0
   end function floordiv

   pure function fmt_number(digits, p) result(s)
      !! Format `digits x 10^p` as `giza_format_number` writes it in its automatic form.
      !!
      !! This handles mantissas beyond giza's C `int`.
      ! Arguments
      character(len=*), intent(in) :: digits
         !! Decimal digits of the mantissa.
      integer(int32), intent(in) :: p
         !! Power of ten.
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
      !! Return `s` with ASCII upper-case letters lowered.
      ! Arguments
      character(len=*), intent(in) :: s
         !! Input string.
      character(len=len(s)) :: t
      integer(int32) :: i, c
      t = s
      do i = 1, len(s)
         c = iachar(s(i:i))
         if (c >= iachar('A') .and. c <= iachar('Z')) t(i:i) = achar(c + 32)
      end do
   end function lower

end module units
