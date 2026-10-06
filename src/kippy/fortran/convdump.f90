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

! convdump.f90 -- diagnostic tool to load any supported input and print
! first/last model summary stats.
!
! Usage:  ./convdump [file.cnv]      (default: convdata.cnv)
!
program convdump

   use typedef, only: int32
   use convdata, only: data
   use mesaload, only: load_convection
   implicit none

   character(len=256) :: fname
   integer(int32) :: n

   if (command_argument_count() >= 1) then
      call get_command_argument(1, fname)
   else
      fname = 'convdata.cnv'
   end if

   call load_convection(trim(fname), 1_int32, huge(1_int32))
   n = int(size(data), int32)
   print '(a,i0)', 'nmodels ', n
   call show(1_int32)
   call show(n)

contains

   subroutine show(i)
      integer(int32), intent(in) :: i
      print '(a,i0,a,i0,a,i0)', '--- model index ', i, &
         '  ncyc=', data(i)%ncyc, '  nconv=', data(i)%nconv
      print '(a,i0,a,es22.15,a,es22.15)', '  ncoord=', data(i)%ncoord, &
         '  tc=', data(i)%tc, '  dc=', data(i)%dc
      print '(a,es22.15,a,es22.15)', '  summ0=', data(i)%summ0, &
         '  xmcoord.sum=', sum(data(i)%xmcoord)
   end subroutine show

end program convdump
