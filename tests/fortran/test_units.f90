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

! test_units.f90 -- unit tests for the public procedures of units.f90
!
! expected values come from the user docs.
! these are the `units` and `offset` commands in docs/commands.md and "Unit recognition" in docs/formats.md.
! axis offsets come from matplotlib 3.10 ScalarFormatter, given the view limits as its tick locations.
! every failed check is printed, and the program ends in error stop so meson reports a failure.
program test_units

   use typedef, only: int32, real64
   use units, only: unit_id, auto_time_unit, quantity_label, axis_offset, &
      UNAME, UDIM, UFAC, DIM_TIME, DIM_MASS, DIM_LENGTH
   implicit none

   ! seconds per gregorian year and per day (docs/commands.md, `units`)
   real(real64), parameter :: YEAR = 31556952.d0, DAY = 86400.d0

   integer(int32) :: nfail = 0

   call test_unit_id()
   call test_auto_time_unit()
   call test_quantity_label()
   call test_axis_offset()

   if (nfail > 0) then
      print '(i0,a)', nfail, ' check(s) failed'
      error stop 1
   end if
   print '(a)', 'units ok'

contains

   subroutine test_unit_id()
      character(len=4), parameter :: names(15) = [character(len=4) :: &
         's', 'min', 'hr', 'd', 'yr', 'kyr', 'Myr', 'Gyr', &
         'g', 'kg', 'Msun', &
         'cm', 'm', 'km', 'Rsun']
      integer(int32), parameter :: dims(15) = [ &
         DIM_TIME, DIM_TIME, DIM_TIME, DIM_TIME, DIM_TIME, DIM_TIME, DIM_TIME, DIM_TIME, &
         DIM_MASS, DIM_MASS, DIM_MASS, &
         DIM_LENGTH, DIM_LENGTH, DIM_LENGTH, DIM_LENGTH]
      ! cgs factors, 0 where the docs give no value (Msun, Rsun)
      real(real64), parameter :: facs(15) = [ &
         1.d0, 60.d0, 3600.d0, DAY, YEAR, 1.d3*YEAR, 1.d6*YEAR, 1.d9*YEAR, &
         1.d0, 1.d3, 0.d0, &
         1.d0, 1.d2, 1.d5, 0.d0]
      integer(int32) :: k, u

      do k = 1, size(names)
         u = unit_id(names(k))
         call check(u /= 0, 'unit_id knows '//trim(names(k)))
         if (u == 0) cycle
         call check_str(UNAME(u), names(k), 'UNAME of '//trim(names(k)))
         call check(UDIM(u) == dims(k), 'UDIM of '//trim(names(k)))
         if (facs(k) > 0.d0) call check_real(UFAC(u), facs(k), 'UFAC of '//trim(names(k)))
      end do

      call check(unit_id('MSUN') == unit_id('Msun'), 'unit_id ignores case (MSUN)')
      call check(unit_id('myr') == unit_id('Myr'), 'unit_id ignores case (myr)')
      call check(unit_id('rSuN') == unit_id('Rsun'), 'unit_id ignores case (rSuN)')
      call check(unit_id('pc') == 0, 'unit_id rejects pc')
   end subroutine test_unit_id

   ! the largest time unit in which the span is at least 1 (docs/commands.md, `units`)
   subroutine test_auto_time_unit()
      call check_auto(0.5d0, 's')
      call check_auto(59.d0, 's')
      call check_auto(60.d0, 'min')
      call check_auto(DAY, 'd')
      call check_auto(YEAR, 'yr')
      call check_auto(999.d0*YEAR, 'yr')
      call check_auto(1.d3*YEAR, 'kyr')
      call check_auto(1.d12*YEAR, 'Gyr')
   end subroutine test_auto_time_unit

   subroutine check_auto(span, want)
      real(real64), intent(in) :: span
      character(len=*), intent(in) :: want
      character(len=40) :: what
      write (what, '(a,es23.16,a)') 'auto_time_unit(', span, ')'
      call check_str(UNAME(auto_time_unit(span)), want, trim(what))
   end subroutine check_auto

   ! docs/formats.md, "Unit recognition"
   subroutine test_quantity_label()
      character(len=64) :: base, ulab

      call check_label('rho_gcc', '', '\rho', 'g cm^{-3}')
      call check_label('kappa', '', '\kappa', '')
      call check_label('T_K', '', 'T', 'K')
      call check_label('L_erg_s', '', 'L', 'erg s^{-1}')
      call check_label('eps_nuc_erg_g_s', '', 'eps nuc', 'erg g^{-1} s^{-1}')
      call check_label('dens', 'g/cm^3', 'dens', 'g cm^{-3}')
      call check_label('dens', 'g/cm3', 'dens', 'g cm^{-3}')
      call check_label('dens', 'gcc', 'dens', 'g cm^{-3}')
      call check_label('temp', 'log(K)', 'temp', 'log(K)')

      ! a header unit wins over the name's suffix
      call quantity_label('rho_gcc', 'kg/m^3', base, ulab)
      call check_str(ulab, 'kg m^{-3}', 'quantity_label unit of rho_gcc [kg/m^3]')
   end subroutine test_quantity_label

   subroutine check_label(name, unit, base_want, ulab_want)
      character(len=*), intent(in) :: name, unit, base_want, ulab_want
      character(len=64) :: base, ulab
      call quantity_label(name, unit, base, ulab)
      call check_str(base, base_want, 'quantity_label base of '//name//' ['//unit//']')
      call check_str(ulab, ulab_want, 'quantity_label unit of '//name//' ['//unit//']')
   end subroutine check_label

   ! offsets from matplotlib 3.10 ScalarFormatter._compute_offset with the view
   ! limits as the tick locations.
   ! the text follows docs/commands.md, `offset`.
   subroutine test_axis_offset()
      call check_offset(3812330.2d0, 3812331.1d0, 'kyr', 3812330.d0, '+3.81233 Gyr')
      call check_offset(3812331.1d0, 3812330.2d0, 'kyr', 3812330.d0, '+3.81233 Gyr')
      call check_offset(-3812331.1d0, -3812330.2d0, 'kyr', -3812330.d0, '-3.81233 Gyr')
      call check_offset(999999.5d0, 1000000.5d0, 'yr', 1000000.d0, '+1 Myr')
      call check_offset(1234.2d0, 1234.9d0, 'yr', 1234.d0, '+1.234 kyr')
      call check_offset(3000.2d0, 3000.9d0, 's', 3000.d0, '+3000 s')
      ! no offset: fewer than four digits saved, a view across 0, a zero-width view
      call check_offset(123.2d0, 123.9d0, 'yr', 0.d0, '')
      call check_offset(-1.d0, 1.d0, 'yr', 0.d0, '')
      call check_offset(5.d0, 5.d0, 'yr', 0.d0, '')
   end subroutine test_axis_offset

   subroutine check_offset(lo, hi, unit, off_want, txt_want)
      real(real64), intent(in) :: lo, hi, off_want
      character(len=*), intent(in) :: unit, txt_want
      real(real64) :: off
      character(len=64) :: txt, what
      write (what, '(a,es15.8,a,es15.8,3a)') 'axis_offset(', lo, ',', hi, ' ', unit, ')'
      call axis_offset(lo, hi, unit_id(unit), off, txt)
      call check_real(off, off_want, trim(what)//' off')
      call check_str(txt, txt_want, trim(what)//' txt')
   end subroutine check_offset

   subroutine check(ok, what)
      logical, intent(in) :: ok
      character(len=*), intent(in) :: what
      if (ok) return
      nfail = nfail + 1
      print '(2a)', 'FAIL ', what
   end subroutine check

   subroutine check_str(got, want, what)
      character(len=*), intent(in) :: got, want, what
      if (got == want) return
      nfail = nfail + 1
      print '(7a)', 'FAIL ', what, ': got "', trim(got), '", want "', trim(want), '"'
   end subroutine check_str

   subroutine check_real(got, want, what)
      real(real64), intent(in) :: got, want
      character(len=*), intent(in) :: what
      if (got == want) return
      nfail = nfail + 1
      print '(3a,es25.17,a,es25.17)', 'FAIL ', what, ': got', got, ', want', want
   end subroutine check_real

end program test_units
