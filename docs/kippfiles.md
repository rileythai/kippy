# `kipp` files

## Introduction

When using `kippy` with `MESA`, it is generally optimal for both disk space and file count to instead dump the relevant quantities into Fortran binary over the native ASCII formats of `profile` files. For this reason, described below are a set of routines to make the `.kipp` files that `kippy` expects, and an example/tutorial for their implementation.

This example is also available in the `example/` directory of the repository.

## Implementation

Adding a hook to make `.kipp` files requires overrides to three routine pointers of `subroutine extras_controls` `src/run_star_extras.f90` of the standard `star/work` directory. You may already use these hooks for other science. Worry not, because the process is designed to be modular.

> [!WARNING]
> If use `include`'s as below, you will need to rebuild via `./clean` single time and `./mk` 
> every time changes are made because the `make` system is not aware of changes to `*.inc` files.

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

You must then add the relevant variables to the module declaration.

```fortran
module run_star_extras

   use star_lib
   use star_def
   use const_def
   use math_lib
   use auto_diff

   implicit none

   include 'kipp/params.inc' ! <--- this contains kippy variables
```

Where the file `kipp/params.inc` can be:

> [!TIP]
> `kippy` works best when you output _every single model_ for plotting. This 
> allows you to check for insufficient resolution in both space and time.

```fortran
! "kipp" record (for Kippenhahn diagrams via kippy):
! direct stream file -- every cell of every timestep together!
! toggle set via x_integer_ctrl(kipp_idx) = (cadence): <= 0 off (default), n saves every nth step.
! you should really save n = 1 (all) steps for the best rendering.
! you can choose where you want the ctrl index via the ikipp_on variable below
!
! path is chosen from x_character_ctrl(1), else <log_directory>/profile.kipp.
! 12 real(dp) columns per cell, see write_kipp_record / open_kipp_record.

! change these for yourself!
integer, parameter :: kipp_ncols = 12
integer, parameter :: kipp_idx = 4 ! the x_integer_ctrl index to access for cadence

! these are used internally, no need to change them
integer :: kipp_unit = -1     ! stream unit, -1 when closed
integer :: kipp_cadence = 0   ! x_integer_ctrl(kipp_idx); <= 0 disables
logical :: kipp_on = .false.  ! flag if enabled for this run
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

  ! if startup is going well, open the file
  call open_kipp_record(s, restart)
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
end function extras_finish_step

subroutine extras_after_evolve(id, ierr)
  integer, intent(in) :: id
  integer, intent(out) :: ierr
  type(star_info), pointer :: s
  ierr = 0
  call star_ptr(id, s, ierr)
  if (ierr /= 0) return

  ! other stuff here

  ! safely close the file
  call close_kipp_record()
end subroutine extras_after_evolve
```

The three routines themselves to open/write/close the record can be included:
```fortran
  ! anywhere in the "contains" declaration

  include 'kipp/routines.inc'

  ! ....

end module run_star_extras
```

And the file `kipp/routines.inc` should be:
```fortran
   ! kipp files
   !
   ! log a minimal set of vars every timestep for use in plotting the resolution in a 
   ! Kippenhahn diagram (see kippy).
   !
   ! opt-in via x_integer_ctrl(kipp_idx) (cadence): <= 0 off (default), n saves every
   ! nth step (model_number 1, 1+n, ...).  
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
   !   9 rho(g/cc)    10 mlt_mixing_type  11 eps_net(erg/g/s)  12 L(erg/s)
   ! col 11 is eps_nuc - non_nuc_neu (i.e., MESA's net_nuclear_energy)
   !
   ! you may add new columns if you need, this requires:
   !    1. you change the ncols in the params file to accomodate
   !    2. you add the relevant name to the header function below
   !    3. you add the relevant calculated quantity to the record function below
   subroutine open_kipp_record(s, restart)
      type(star_info), pointer :: s
      logical, intent(in) :: restart
      integer :: ierr, u
      character(len=256) :: path

      kipp_on = .false.
      kipp_unit = -1
      kipp_cadence = s%x_integer_ctrl(kipp_idx)
      if (kipp_cadence <= 0) return          ! feature off (default)

      if (len_trim(s%x_character_ctrl(kipp_idx)) > 0) then
         path = trim(s%x_character_ctrl(kipp_idx))
      else
         path = trim(s%log_directory)//'/profile.kipp'
      end if

      ierr = 0
      if (restart) then
         ! continue the existing file across a photo restart
         open (newunit=u, file=trim(path), access='stream', form='unformatted', &
               status='old', position='append', action='write', iostat=ierr)
      else
         ! fresh run: truncate and (re)write the column header sidecar
         open (newunit=u, file=trim(path), access='stream', form='unformatted', &
               status='replace', action='write', iostat=ierr)
      end if
      if (ierr /= 0) then
         write (*, *) 'open_kipp_record: could not open ', trim(path)
         return
      end if

      kipp_unit = u
      kipp_on = .true.

      ! NOTE: this assumes you have already ran it once before restarting
      if (.not. restart) call write_kipp_header(trim(path)) 
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
         ! NOTE: mlt_mixing_type is the END OF STEP value
         !       if you want the START of step, use s% mixing_type(k)
         buf(10, k) = real(s%mlt_mixing_type(k), dp) 
         buf(11, k) = s%eps_nuc(k) - s%non_nuc_neu(k)
         buf(12, k) = s%L(k)
      end do

      ! single bulk write per step (not per cell), then flush so the file is
      ! readable / crash-safe mid-run
      write (kipp_unit) buf
      flush (kipp_unit)
      deallocate (buf)
   end subroutine write_kipp_record

   subroutine close_kipp_record()
      if (kipp_unit >= 0) then
         close (kipp_unit)
         kipp_unit = -1
      end if
      kipp_on = .false.
   end subroutine close_kipp_record
```

An example of this implementation for `star/work/src/` is held at `github.com/rileythai/kippy`.
