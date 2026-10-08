# `kipp` files

## Introduction

When using `kippy` with `MESA`, it is generally optimal for both disk space and file count to instead dump the relevant quantities into Fortran binary over the native ASCII formats of `profile` files. For this reason, described below are a set of routines to make the `.kipp` files that `kippy` expects, and an example/tutorial for their implementation.

This example is also available in the `example/` directory of the repository.
The [file format](#file-format) itself is specified at the end of this page,
for writing `.kipp` files from other codes.

## Implementation

Adding a hook to make `.kipp` files requires overrides to three routine pointers of `subroutine extras_controls` `src/run_star_extras.f90` of the standard `star/work` directory. You may already use these hooks for other science. Worry not, because the process is designed to be modular.

!!! warning
    If use `include`'s as below, you will need to rebuild via `./clean` single time and `./mk` 
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

!!! tip
    `kippy` works best when you output _every single model_ for plotting. This 
    allows you to check for insufficient resolution in both space and time.

```fortran
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

An example of this implementation for `star/work/src/` is held at [github.com/rileythai/kippy:example/](https://github.com/rileythai/kippy/tree/main/example)

## File format

A `.kipp` input is two files: the binary data file, whose path must end in
`.kipp`, and a plain text sidecar header describing its columns.

### Data file

The data file is a headerless stream of **little-endian 64-bit IEEE floats**
with no record markers. It is read as rows of `ncols` values, where `ncols`
comes from the header, and each row is one cell of one model. Integer
quantities such as the model number and mixing type are stored as floats and
rounded to the nearest integer.

- The rows of one model must be contiguous. A row whose model number differs
  from the previous row starts a new model.
- Within a model, rows run from the **surface to the centre**, as MESA numbers
  its zones. `kippy` reverses them on load.
- Model numbers should increase through the file. A restart may append rows
  with model numbers that jump backwards; when a model number appears more than
  once, the last copy in the file is kept.
- The age and time step of a model are taken from its last row, so every row of
  a model should carry the same values.
- The file must contain at least two models. A partial row at the end of the
  file, such as one left by a run that was killed mid-write, is ignored.

The file can be read in Python with:

```python
import numpy as np

data = np.fromfile("profile.kipp", dtype="<f8").reshape(-1, ncols)
```

### Header file

For a data file `path/to/file.kipp`, the header is `path/to/file.kipp.hdr`. If
that is absent, `kippy` looks for `file.kipp.hdr` in the working directory.

The header is read line by line, and the first word of each line decides how it
is used:

| Line | Meaning |
| --- | --- |
| `ncols <n>` | Number of values per row. Required |
| `<index> <name>` | Names column `<index>`, counted from 1 |
| `dtype ...`, `columns`, `columns:` | Ignored |
| Blank lines and any other line | Ignored |

!!! warning
    The `dtype` line is informational only. `kippy` always reads the data as
    little-endian float64, so a file written with any other type will load as
    garbage.

Column names are case-sensitive single words; use letters, digits and
underscores only, since a space, comma or slash ends the name. Every index must
lie between 1 and `ncols`, and `ncols` can be at most 512. Columns without a
name line are skipped.

### Required columns

Each role below must be named by one of its accepted names, except the time
step, which is optional.

| Role | Accepted names | Units |
| --- | --- | --- |
| Model number | `model_number`, `model` | |
| Age | `star_age_yr`, `star_age`, `age_yr` | yr |
| Time step (optional) | `dt_s`, `dt` | s |
| Mass coordinate | `m_g`, `mass_g`, `mass` | g |
| Radius coordinate | `r_cm`, `radius_cm`, `r` | cm |
| Mixing type | `mixing_type`, `mix_type`, `mixing` | MESA mixing code |
| Energy generation | `eps_net_erg_g_s`, `eps_nuc`, `eps_net`, `eps` | erg/g/s |

The mixing column uses MESA's mixing codes, mapped to the `kippy` zone types:

| Code | Zone type |
| --- | --- |
| 0 | Radiative |
| 1 | Convective |
| 2 | Overshoot |
| 3 | Semiconvective |
| 4 | Thermohaline |
| 5 | Neutral (MESA rotational mixing) |
| 9 | Convective (MESA leftover convection) |
| Any other | Neutral |

The energy column drives the single `epsnuc` layer; there is no separate
neutrino layer, so a net rate such as `eps_nuc - non_nuc_neu` is the natural
choice. Each cell is binned to the nearest integer of `log10|eps|`, positive
values as gain and negative values as loss. Cells with `|eps|` below
`10^0.5`, about 3.16 erg/g/s, are not drawn.

### Colour fields

Every other named column, such as `zone`, `dm_g` or `T_K` in the example above,
is offered as a colour field under its header name, so it can be shown with
`color <name>`. Names longer than 32 characters are truncated. See
[colour fields](formats.md#colour-fields) for how the values are binned.
