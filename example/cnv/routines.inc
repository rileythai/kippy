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
