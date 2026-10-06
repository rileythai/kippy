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
