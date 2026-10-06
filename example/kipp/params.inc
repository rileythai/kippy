! "kipp" record (for Kippenhahn diagrams via kippy):
! direct stream file -- every cell of every timestep together!
! toggle set via x_integer_ctrl(kipp_idx) = (cadence): <= 0 off (default), n saves every nth step.
! you should really save n = 1 (all) steps for the best rendering.
! you can choose where you want the ctrl index via the ikipp_on variable below
!
! path is chosen from x_character_ctrl(kipp_idx), else <log_directory>/profile.kipp.
! 12 real(dp) columns per cell, see write_kipp_record / open_kipp_record.

! change these for yourself!
integer, parameter :: kipp_ncols = 12
integer, parameter :: kipp_idx = 4 ! the x_integer_ctrl index to access for cadence

! these are used internally, no need to change them
integer :: kipp_unit = -1     ! stream unit, -1 when closed
integer :: kipp_cadence = 0   ! x_integer_ctrl(kipp_idx); <= 0 disables
logical :: kipp_on = .false.  ! flag if enabled for this run
