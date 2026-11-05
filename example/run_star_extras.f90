! ***********************************************************************
!
!   Copyright (C) 2010-2025  Bill Paxton & The MESA Team
!
!   This program is free software: you can redistribute it and/or modify
!   it under the terms of the GNU Lesser General Public License
!   as published by the Free Software Foundation,
!   either version 3 of the License, or (at your option) any later version.
!
!   This program is distributed in the hope that it will be useful,
!   but WITHOUT ANY WARRANTY; without even the implied warranty of
!   MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.
!   See the GNU Lesser General Public License for more details.
!
!   You should have received a copy of the GNU Lesser General Public License
!   along with this program. If not, see <https://www.gnu.org/licenses/>.
!
! ***********************************************************************

module run_star_extras

   use star_lib
   use star_def
   use const_def
   use math_lib
   use auto_diff

   implicit none

   include 'kipp/params.inc'
   include 'cnv/params.inc'

contains

   include 'kipp/routines.inc'
   include 'cnv/routines.inc'

   subroutine extras_controls(id, ierr)
      integer, intent(in) :: id
      integer, intent(out) :: ierr
      type(star_info), pointer :: s
      ierr = 0
      call star_ptr(id, s, ierr)
      if (ierr /= 0) return

      s%extras_startup => extras_startup
      s%extras_finish_step => extras_finish_step
      s%extras_after_evolve => extras_after_evolve

      ! MESA stops at the first step when any of these is unset (warn_run_star_extras, see
      ! https://docs.mesastar.org/en/latest/reference/star_job.html#warn-run-star-extras),
      ! so the example sets them to the empty versions at the end of this module
      s%extras_check_model => extras_check_model
      s%how_many_extra_history_columns => how_many_extra_history_columns
      s%data_for_extra_history_columns => data_for_extra_history_columns
      s%how_many_extra_profile_columns => how_many_extra_profile_columns
      s%data_for_extra_profile_columns => data_for_extra_profile_columns
   end subroutine extras_controls

   subroutine extras_startup(id, restart, ierr)
      integer, intent(in) :: id
      logical, intent(in) :: restart
      integer, intent(out) :: ierr
      type(star_info), pointer :: s
      ierr = 0
      call star_ptr(id, s, ierr)
      if (ierr /= 0) return
      call open_kipp_record(s, restart)
      call open_cnv_record(s, restart)
   end subroutine extras_startup

   integer function extras_finish_step(id)
      integer, intent(in) :: id
      integer :: ierr
      type(star_info), pointer :: s
      ierr = 0
      call star_ptr(id, s, ierr)
      if (ierr /= 0) return
      extras_finish_step = keep_going
      call write_kipp_record(s)
      call write_cnv_record(s)
   end function extras_finish_step

   subroutine extras_after_evolve(id, ierr)
      integer, intent(in) :: id
      integer, intent(out) :: ierr
      type(star_info), pointer :: s
      ierr = 0
      call star_ptr(id, s, ierr)
      if (ierr /= 0) return
      call close_kipp_record()
      call close_cnv_record()
   end subroutine extras_after_evolve

   integer function extras_check_model(id)
      integer, intent(in) :: id
      extras_check_model = keep_going
   end function extras_check_model

   integer function how_many_extra_history_columns(id)
      integer, intent(in) :: id
      how_many_extra_history_columns = 0
   end function how_many_extra_history_columns

   subroutine data_for_extra_history_columns(id, n, names, vals, ierr)
      integer, intent(in) :: id, n
      character(len=maxlen_history_column_name) :: names(n)
      real(dp) :: vals(n)
      integer, intent(out) :: ierr
      ierr = 0
   end subroutine data_for_extra_history_columns

   integer function how_many_extra_profile_columns(id)
      integer, intent(in) :: id
      how_many_extra_profile_columns = 0
   end function how_many_extra_profile_columns

   subroutine data_for_extra_profile_columns(id, n, nz, names, vals, ierr)
      integer, intent(in) :: id, n, nz
      character(len=maxlen_profile_column_name) :: names(n)
      real(dp) :: vals(nz, n)
      integer, intent(out) :: ierr
      ierr = 0
   end subroutine data_for_extra_profile_columns

end module run_star_extras
