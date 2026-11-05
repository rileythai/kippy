! cnv routine parameters, riley thai nov 2026
! version 10700 .cnv record
!
! writes .cnv compressed resolution record per n steps for kippenhahn diagrams.
!
! layout from https://kippy.rileythai.com/cnvfiles/#record-layout (version 10700),
! the quoted section names below are on that page.
!
! opt-in via x_integer_ctrl(cnv_idx) (cadence): 
!    <= 0 :: off (default), 
!       n :: saves every nth step (model_number 1, 1+n, ...)
!
! path from x_character_ctrl(cnv_idx) if set,
! else <log_directory>/profile.cnv.

! change these for yourself!
integer, parameter :: cnv_idx = 5 ! the x_integer_ctrl / x_character_ctrl index for cadence and path

! these are used internally, no need to change them
integer :: cnv_unit = 0           ! stream unit; newunit units are negative, so 0 means closed
integer :: cnv_cadence = 0        ! x_integer_ctrl(cnv_idx); <= 0 disables
logical :: cnv_on = .false.       ! flag if enabled for this run
logical :: cnv_warned = .false.   ! the nz > 32767 warning was printed

! BELOW is fixed by the .cnv format, do NOT change them!

! record version 10700 (toffset after dt, ladv after ncoord), with 2-byte grid
! indices and 1-byte energy levels ("File structure" in docs) 
integer(i4), parameter :: cnv_nvers = 10700
integer(i4), parameter :: cnv_idx_kind_len = 4
integer(i4), parameter :: cnv_nuc_kind_len = 2
logical, parameter :: cnv_little = transfer(1_i4, 0_i1) == 1_i1  ! host byte order

! kippy will turn timesec into years of 31556952 s ("Models and time" in docs)
! we transform star_age to that year unit to show MESA's star_age exactly
real(dp), parameter :: cnv_yr = 31556952d0

! the 12 level floors (minloss ... minneugd). 
! kippy reads the first six as (gain, loss)
! pairs for nuc, nuk and neu and labels gain level L as log10 = floor + L - 1
! ("Energy layers" in docs), so floors of 1 make a level its own log10.
! the derivative layers are empty, so their floors are 0.
integer(i4), parameter :: cnv_floors(12) = [1, 1, 1, 1, 1, 1, 0, 0, 0, 0, 0, 0]
