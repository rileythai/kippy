# Writing `.kipp` and `.cnv` files from MESA

## Introduction

When using `kippy` with `MESA`, it is generally optimal for both disk space and file count to instead dump Fortran binary streams over the native ASCII `profile` files. 

For this reason, below is a tutorial to implement a set of routines to write the two useful kinds of binary records that `kippy` expect:

- [`.kipp` files](kippfiles.md): an extensible profile-style binary stream, allowing
  arbitrary columns that can be shown as colour fields.
- [`.cnv` files](cnvfiles.md): a compressed, pre-quantized record, useful for 
  resolution studies. This is about 6x as compressed as `.kipp` files.

The two records are independent, so you may write one or both simultaneously.

The exact file formats themselves are specified on the [`.kipp`](kippfiles.md#file-format)
and [`.cnv`](cnvfiles.md#file-structure) pages, for writing them from other codes.

!!! tip
    `kippy` works best when you output _every single model_ for plotting. This 
    allows you to check for insufficient resolution in both space and time.

## Implementation in MESA

Adding a hook to make `.kipp` or `.cnv` files requires overrides to three routine pointers of `subroutine extras_controls` `src/run_star_extras.f90` of the standard `star/work` directory. You may already use these hooks for other science. Worry not, because the process here is designed to be modular.

This example is also available in the `example/` directory of the repository.

!!! warning
    If you use `include`'s as below, you will need to rebuild via `./clean` single time and `./mk` 
    every time changes are made because the `make` system is not aware of changes to `*.inc` files.

```fortran
   subroutine extras_controls(id, ierr)
      integer, intent(in) :: id
      integer, intent(out) :: ierr
      type(star_info), pointer :: s
      ierr = 0
      call star_ptr(id, s, ierr)
      if (ierr /= 0) return

      ! at LEAST the following three hooks are necessary
      s%extras_startup      => extras_startup      ! used to open the file safely
      s%extras_finish_step  => extras_finish_step  ! used to write the data
      s%extras_after_evolve => extras_after_evolve ! used to close the file safely

      ! you may do whatever you want for your science with other hooks
   end subroutine extras_controls
```

`MESA` stops at the first step when `extras_check_model` or any of the extra
history and profile column hooks is left unset
([`warn_run_star_extras`](https://docs.mesastar.org/en/latest/reference/star_job.html#warn-run-star-extras)).
If your `run_star_extras.f90` does not already set them, the example file sets
them to empty versions you can copy.

You must then add the relevant variables to the module declaration. Leave out the
`include` of a record you do not write.

```fortran
module run_star_extras

   use star_lib
   use star_def
   use const_def ! <--- also provides the i1, i2, i4 and i8 integer kinds
   use math_lib
   use auto_diff

   implicit none

   include 'kipp/params.inc' ! <--- this contains the .kipp variables
   include 'cnv/params.inc'  ! <--- this contains the .cnv variables
```

The three pointed routines themselves must look like:
```fortran

subroutine extras_startup(id, restart, ierr)
  integer, intent(in) :: id
  logical, intent(in) :: restart
  integer, intent(out) :: ierr
  type(star_info), pointer :: s
  ierr = 0
  call star_ptr(id, s, ierr)
  if (ierr /= 0) return
  
  ! your stuff here

  ! if startup is going well, open the files
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

  ! other stuff here

  ! best to write at the end of the function
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

  ! other stuff here

  ! safely close the files
  call close_kipp_record()
  call close_cnv_record()
end subroutine extras_after_evolve
```

The routines themselves to open/write/close the records can be included:
```fortran
  ! anywhere in the "contains" declaration

  include 'kipp/routines.inc'
  include 'cnv/routines.inc'

  ! ....

end module run_star_extras
```

The `params.inc` and `routines.inc` files of each record are given in full in
[`.kipp` routines](#kipp-routines) and [`.cnv` routines](#cnv-routines) below.

## Inlist

Both records are off by default. Turn each one on in `&controls` by setting its cadence,
and optionally its path:

```fortran
&controls
   ! ensure s% mixing_type holds converged model mixing state
   recalc_mix_info_after_evolve = .true.

   ! NOTE: if you change the indices in the params.inc files below, you must change the indices 
   ! here too
   x_integer_ctrl(4) = 1                    ! write a .kipp record every step
   x_integer_ctrl(5) = 1                    ! write a .cnv record every step
   ! x_character_ctrl(4) = 'LOGS/run.kipp'  ! optional, else LOGS/profile.kipp
   ! x_character_ctrl(5) = 'LOGS/run.cnv'   ! optional, else LOGS/profile.cnv
/
```

The indices 4 and 5 are `kipp_idx` and `cnv_idx` in the `params.inc` files; change
them there if your run already uses those controls.

!!! warning
    The __mixing column__ of `s% mixing_type` is, by default, the __start of step value__ in `MESA`, which means it is one step lagged.

    To fix this, ensure
    [`recalc_mix_info_after_evolve = .true.`](https://docs.mesastar.org/en/latest/reference/controls.html#recalc-mix-info-after-evolve)
    so `s% mixing_type` will hold the mixing info of the converged model.

## `.kipp` routines

The file `kipp/params.inc` can be:

```fortran
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
```

And the file `kipp/routines.inc` should be:
```fortran
   ! kipp routines, riley thai oct 2026
   !
   ! profile-style extensible binary record for arbitrary structure variables
   ! per n steps, useful for Kippenhahn diagrams (see kippy).
   !
   ! opt-in via x_integer_ctrl(kipp_idx) (cadence): 
   !    <= 0 :: off (default), 
   !       n :: saves every nth step (model_number 1, 1+n, ...)
   !
   ! path from x_character_ctrl(kipp_idx) if set,
   ! else <log_directory>/profile.kipp. file is a raw stream of real(dp) vars.
   !
   ! dumb read in python with np.fromfile(path).reshape(-1, kipp_ncols). 
   ! we use a one-time header write at at <path>.hdr
   !
   ! columns (all real(dp)):
   !   1 model_number  2 star_age(yr)      3 dt(s)      4 zone k
   !   5 dm(g)         6 m(g)              7 r(cm)      8 T(K)
   !   9 rho(g/cc)    10 mixing_type  11 eps_net(erg/g/s)  12 L(erg/s)
   ! col 11 is eps_nuc - non_nuc_neu (i.e., MESA's net_nuclear_energy)
   !
   ! add new columns if you need by:
   !    1. change the ncols in the params.inc file to accomodate length
   !    2. add a name to the header function (write_kipp_header) below
   !    3. add the calculated quantity to the record function (write_kipp_record) below
   subroutine open_kipp_record(s, restart)
      type(star_info), pointer :: s
      logical, intent(in) :: restart
      integer :: ierr, u
      character(len=256) :: path
      logical :: append

      kipp_on = .false.
      kipp_unit = 0
      kipp_cadence = s%x_integer_ctrl(kipp_idx)
      if (kipp_cadence <= 0) return          ! feature off (default)

      ! use filename if given, else default to profile.kipp
      if (len_trim(s%x_character_ctrl(kipp_idx)) > 0) then
         path = trim(s%x_character_ctrl(kipp_idx))
      else
         path = trim(s%log_directory)//'/profile.kipp'
      end if

      ! restart / append checks
      inquire (file=trim(path), exist=append)
      append = append .and. restart

      ierr = 0
      if (append) then
         ! continue the existing file across a photo restart
         open (newunit=u, file=trim(path), access='stream', form='unformatted', &
               status='old', position='append', action='write', iostat=ierr)
      else
         ! fresh run: truncate
         open (newunit=u, file=trim(path), access='stream', form='unformatted', &
               status='replace', action='write', iostat=ierr)
      end if
      if (ierr /= 0) then
         write (*, *) 'open_kipp_record: could not open ', trim(path)
         return
      end if

      kipp_unit = u
      kipp_on = .true.

      ! fresh run: (re)write the column header sidecar
      if (.not. append) call write_kipp_header(trim(path))
   end subroutine open_kipp_record

   ! one-time text file naming the binary columns (help you read it)
   subroutine write_kipp_header(path)
      character(len=*), intent(in) :: path
      integer :: uh, ierr
      ierr = 0
      open (newunit=uh, file=trim(path)//'.hdr', status='replace', &
            action='write', iostat=ierr)
      if (ierr /= 0) return
      write (uh, '(a,i0)') 'ncols ', kipp_ncols
      write (uh, '(a)') 'dtype float64 (little-endian), C order, row-major per cell'
      write (uh, '(a)') 'columns:'
      write (uh, '(a)') '1 model_number'
      write (uh, '(a)') '2 star_age_yr'
      write (uh, '(a)') '3 dt_s'
      write (uh, '(a)') '4 zone'
      write (uh, '(a)') '5 dm_g'
      write (uh, '(a)') '6 m_g'
      write (uh, '(a)') '7 r_cm'
      write (uh, '(a)') '8 T_K'
      write (uh, '(a)') '9 rho_gcc'
      write (uh, '(a)') '10 mixing_type'
      write (uh, '(a)') '11 eps_net_erg_g_s' 
      write (uh, '(a)') '12 L_erg_s'
      close (uh)
   end subroutine write_kipp_header

   subroutine write_kipp_record(s)
      type(star_info), pointer :: s
      integer :: k
      real(dp), allocatable :: buf(:, :)

      if (.not. kipp_on) return
      if (mod(s%model_number - 1, kipp_cadence) /= 0) return

      allocate (buf(kipp_ncols, s%nz))

      ! if you want more variables, add them here!!!
      do k = 1, s%nz
         buf(1, k) = real(s%model_number, dp)
         buf(2, k) = s%star_age
         buf(3, k) = s%dt
         buf(4, k) = real(k, dp)
         buf(5, k) = s%dm(k)
         buf(6, k) = s%m(k)
         buf(7, k) = s%r(k)
         buf(8, k) = s%T(k)
         buf(9, k) = s%rho(k)
         ! NOTE: mixing_type is the START of step value unless the inlist sets
         !       recalc_mix_info_after_evolve = .true., see
         ! https://docs.mesastar.org/en/latest/reference/controls.html#recalc-mix-info-after-evolve
         buf(10, k) = real(s%mixing_type(k), dp)
         buf(11, k) = s%eps_nuc(k) - s%non_nuc_neu(k)
         buf(12, k) = s%L(k)

         ! add more here!
      end do

      ! single bulk write per step (not per cell), then flush so the file is
      ! readable / crash-safe mid-run
      write (kipp_unit) buf
      flush (kipp_unit)
      deallocate (buf)
   end subroutine write_kipp_record

   subroutine close_kipp_record()
      if (kipp_unit /= 0) then
         close (kipp_unit)
         kipp_unit = 0
      end if
      kipp_on = .false.
   end subroutine close_kipp_record
```

## `.cnv` routines

The file `cnv/params.inc` can be:

```fortran
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
```

And the file `cnv/routines.inc` should be:
```fortran
   ! cnv routines, riley thai nov 2026
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
   subroutine open_cnv_record(s, restart)
      type(star_info), pointer :: s
      logical, intent(in) :: restart
      integer :: ierr, u
      character(len=256) :: path
      logical :: append

      cnv_on = .false.
      cnv_unit = 0
      cnv_cadence = s%x_integer_ctrl(cnv_idx)
      if (cnv_cadence <= 0) return          ! feature off (default)

      ! use filename if given, else default to profile.cnv
      if (len_trim(s%x_character_ctrl(cnv_idx)) > 0) then
         path = trim(s%x_character_ctrl(cnv_idx))
      else
         path = trim(s%log_directory)//'/profile.cnv'
      end if

      ! restart / append checks
      inquire (file=trim(path), exist=append)
      append = append .and. restart

      ! NOTE: MESA builds with -std=f2008, which rejects convert= func,
      ! so the file is a stream and write_cnv_record writes the markers and big-endian
      ! bytes itself
      ierr = 0
      if (append) then
         ! continue the existing file across a photo restart
         open (newunit=u, file=trim(path), access='stream', form='unformatted', &
               status='old', position='append', action='write', iostat=ierr)
      else
         ! fresh run: truncate
         open (newunit=u, file=trim(path), access='stream', form='unformatted', &
               status='replace', action='write', iostat=ierr)
      end if
      if (ierr /= 0) then
         write (*, *) 'open_cnv_record: could not open ', trim(path)
         return
      end if

      cnv_unit = u
      cnv_on = .true.
   end subroutine open_cnv_record

   subroutine write_cnv_record(s)
      type(star_info), pointer :: s
      integer :: nz, j, k, nconv, nnuc, nneu, nab
      integer(i8) :: p0, p1
      integer, allocatable :: lev_nuc(:), lev_neu(:)
      character(len=1), allocatable :: yz(:), yzip(:)
      integer(i2), allocatable :: iconv(:), inuc(:), ineu(:)
      integer(i1), allocatable :: nuc(:), neu(:)
      real(dp), allocatable :: xmcoord(:), rncoord(:)
      real(dp) :: abun(20)
      real(dp), parameter :: zero(22) = 0d0

      if (.not. cnv_on) return
      if (mod(s%model_number - 1, cnv_cadence) /= 0) return

      nz = s%nz
      if (nz > huge(0_i2)) then
         if (.not. cnv_warned) then
            write (*, '(a,i0,a)') 'write_cnv_record: skipping records, nz = ', nz, &
               ' is above the 32767 grid points a .cnv record can index'
            cnv_warned = .true.
         end if
         return
      end if

      allocate (lev_nuc(nz), lev_neu(nz), yz(nz), yzip(nz), iconv(nz), xmcoord(nz), rncoord(nz))
      do j = 1, nz
         k = nz + 1 - j
         xmcoord(j) = s%m(k)
         rncoord(j) = s%r(k)
         ! mixing_type is the start-of-step value unless the inlist sets
         ! recalc_mix_info_after_evolve = .true., see
         ! https://docs.mesastar.org/en/latest/reference/controls.html#recalc-mix-info-after-evolve
         yz(j) = cnv_zone_char(s%mixing_type(k))
         lev_nuc(j) = cnv_level(s%eps_nuc(k) - s%non_nuc_neu(k))
         lev_neu(j) = cnv_level(-s%non_nuc_neu(k))
      end do

      ! convection zones
      ! iconv(k) is the outer grid index for zone k
      ! ("Convection zones" in docs)
      nconv = 0
      do j = 1, nz
         if (j < nz) then
            if (yz(j) == yz(j + 1)) cycle
         end if
         nconv = nconv + 1
         yzip(nconv) = yz(j)
         iconv(nconv) = int(j, i2)
      end do

      call cnv_step_function(lev_nuc, nnuc, nuc, inuc)
      call cnv_step_function(lev_neu, nneu, neu, ineu)

      ! central composition: the first 20 species in net order, the rest 0
      ! this gives you enough room for massive star models
      nab = min(s%species, size(abun))
      abun = 0d0
      abun(1:nab) = s%xa(1:nab, nz)

      ! "Record layout" (docs) order.  adjust if you want other summary info
      ! nuk and the derivative layers are empty, ladv = 0

      ! after levcnv and the floors come the f8
      ! fields: central T,rho,P, some other 11 central values (ec ... s2), rotation aw(3), 
      ! summ0 radius0 an,
      ! abun(20), 22 energies (eni ... enpistd), xlum, 7 more (xlum0 ... angit),
      ! angltv(3), xmacc. zeros don't need the byte swap. 
      ! the leading record marker is a
      ! placeholder until the payload length is known
      inquire (unit=cnv_unit, pos=p0)
      write (cnv_unit) 0_i4
      write (cnv_unit) &
         cnv_be4(cnv_nvers), cnv_be4(int(s%model_number, i4)), cnv_be8(s%star_age*cnv_yr), cnv_be8(s%dt), 0d0, &
         cnv_be4([int(nconv, i4), int(nnuc, i4), 0_i4, int(nneu, i4), 0_i4, 0_i4, 0_i4, int(nz, i4), 0_i4, &
                  cnv_idx_kind_len, cnv_nuc_kind_len]), &
         nuc, neu, yzip(1:nconv), cnv_be8(xmcoord), cnv_be8(rncoord), &
         cnv_be2(inuc), cnv_be2(ineu), cnv_be2(iconv(1:nconv)), &
         0_i4, cnv_be4(cnv_floors), &
         cnv_be8([s%T(nz), s%rho(nz), s%Peos(nz)]), zero(1:14), cnv_be8(s%M_center), zero(1:2), cnv_be8(abun), &
         zero(1:22), cnv_be8(s%L(1)), zero(1:11)
      inquire (unit=cnv_unit, pos=p1)
      write (cnv_unit, pos=p0) cnv_be4(int(p1 - p0 - 4, i4))
      write (cnv_unit, pos=p1) cnv_be4(int(p1 - p0 - 4, i4))
      ! flush so the file is readable / crash-safe mid-run
      flush (cnv_unit)
   end subroutine write_cnv_record

   subroutine close_cnv_record()
      if (cnv_on) close (cnv_unit)
      cnv_unit = 0
      cnv_on = .false.
   end subroutine close_cnv_record

   ! maps MESA mixing type to yzip character ("Convection zones" in docs)
   pure character(len=1) function cnv_zone_char(mix)
      integer, intent(in) :: mix
      select case (mix)
      case (no_mixing); cnv_zone_char = ' '
      case (convective_mixing, leftover_convective_mixing); cnv_zone_char = 'C'
      case (overshoot_mixing); cnv_zone_char = 'O'
      case (semiconvective_mixing); cnv_zone_char = 'S'
      case (thermohaline_mixing); cnv_zone_char = 'T'
      case default; cnv_zone_char = 'N'
      end select
   end function cnv_zone_char

   ! signed contour level of energy rate f (erg/g/s): nint(log10|f|) 
   ! negative for loss, 0 for |f| < 10^0.5 or f = 0, as quantized in kippy
   ! clamp keeps non-finite f inside 1-byte range
   pure integer function cnv_level(f)
      real(dp), intent(in) :: f
      real(dp) :: a
      cnv_level = 0
      a = abs(f)
      if (.not. (a > 0d0)) return
      cnv_level = nint(min(log10(a), real(huge(0_i1), dp)))
      if (cnv_level < 1) then
         cnv_level = 0
      else if (f < 0d0) then
         cnv_level = -cnv_level
      end if
   end function cnv_level

   ! energy layers: step function stored as pairs
   ! one entry at grid index 1 and one wherever it changes 
   ! ("Energy layers" in docs)
   subroutine cnv_step_function(lev, n, vals, idx)
      integer, intent(in) :: lev(:)
      integer, intent(out) :: n
      integer(i1), allocatable, intent(out) :: vals(:)
      integer(i2), allocatable, intent(out) :: idx(:)
      integer :: j

      n = 1 + count(lev(2:) /= lev(:size(lev) - 1))
      allocate (vals(n), idx(n))
      n = 0
      do j = 1, size(lev)
         if (j > 1) then
            if (lev(j) == lev(j - 1)) cycle
         end if
         n = n + 1
         vals(n) = int(lev(j), i1)
         idx(n) = int(j, i2)
      end do
   end subroutine cnv_step_function

   ! x with its bytes in big-endian order, on either host byte order
   elemental integer(i2) function cnv_be2(x)
      integer(i2), intent(in) :: x
      integer(i1) :: b(2)
      cnv_be2 = x
      if (.not. cnv_little) return
      b = transfer(x, b)
      cnv_be2 = transfer(b(2:1:-1), x)
   end function cnv_be2

   elemental integer(i4) function cnv_be4(x)
      integer(i4), intent(in) :: x
      integer(i1) :: b(4)
      cnv_be4 = x
      if (.not. cnv_little) return
      b = transfer(x, b)
      cnv_be4 = transfer(b(4:1:-1), x)
   end function cnv_be4

   elemental real(dp) function cnv_be8(x)
      real(dp), intent(in) :: x
      integer(i1) :: b(8)
      cnv_be8 = x
      if (.not. cnv_little) return
      b = transfer(x, b)
      cnv_be8 = transfer(b(8:1:-1), x)
   end function cnv_be8
```

An example of this implementation for `star/work/src/` is held at [github.com/rileythai/kippy:example/](https://github.com/rileythai/kippy/tree/main/example)
