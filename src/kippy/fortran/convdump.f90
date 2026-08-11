! convdump.f90 -- diagnostic tool to load a .cnv via the keppy Fortran
! reader and print first/last model summary stats.  Used to cross-check
! the Fortran reader against the Python ConvData oracle.
!
! Usage:  ./convdump [file.cnv]      (default: convdata.cnv)
!
program convdump

   use typedef, only: int32
   use convdata, only: data
   use convload, only: loadconv
   implicit none

   character(len=256) :: fname
   integer(int32) :: n

   if (command_argument_count() >= 1) then
      call get_command_argument(1, fname)
   else
      fname = 'convdata.cnv'
   end if

   call loadconv(trim(fname), 1_int32, huge(1_int32))
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
