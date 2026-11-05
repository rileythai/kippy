! kipp routine params, riley thai oct 2026
!
! profile-style extensible binary record for arbitrary structure variables
! per n steps, useful for Kippenhahn diagrams (see kippy).
!
! opt-in via x_integer_ctrl(kipp_idx) (cadence): 
!    <= 0 :: off (default), 
!       n :: saves every nth step (model_number 1, 1+n, ...)
!
! path is chosen from x_character_ctrl(kipp_idx), else <log_directory>/profile.kipp.
! 12 real(dp) columns per cell, see write_kipp_record / open_kipp_record.

! change these for yourself!
integer, parameter :: kipp_ncols = 12
integer, parameter :: kipp_idx = 4 ! the x_integer_ctrl index to access for cadence

! these are used internally, no need to change them
integer :: kipp_unit = 0      ! stream unit; newunit units are negative, so 0 means closed
integer :: kipp_cadence = 0   ! x_integer_ctrl(kipp_idx); <= 0 disables
logical :: kipp_on = .false.  ! flag if enabled for this run
