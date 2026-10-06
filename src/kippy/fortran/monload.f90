! kippy - Kippenhahn diagram viewer
! Copyright (C) 2026 the kippy authors (see AUTHORS)
!
! This file is part of kippy.
!
! kippy is free software: you can redistribute it and/or modify
! it under the terms of the GNU Lesser General Public License as
! published by the Free Software Foundation, either version 3 of the
! License, or (at your option) any later version.
!
! kippy is distributed in the hope that it will be useful, but WITHOUT
! ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
! FITNESS FOR A PARTICULAR PURPOSE. See the GNU Lesser General Public
! License for more details.
!
! You should have received a copy of the GNU Lesser General Public
! License along with kippy. If not, see <https://www.gnu.org/licenses/>.

module monload

   use typedef, only: &
      int16, int32, real64
   use convdata, only: &
      convtype, data, idx_kind_len, nuc_kind_len, field_names
   use convbuild, only: &
      SOLRAD, EPS_BASE, GROW_FAC, REC_NVERS, &
      build_zones, build_energy, build_field_layer, alloc_empty_layers, &
      reset_field_registry, update_field_range, finalize_field_log
   use convload, only: &
      sort_models

   implicit none (type, external)
   private

   public :: loadmon

   integer(int32), parameter :: MON_NFIELDS = 11
   real(real64), parameter :: LSUN = 3.851d33
   character(len=32), parameter :: MON_FIELD_NAMES(MON_NFIELDS) = [ &
      character(len=32) :: &
      'Temperature', 'Density', 'Pressure', 'Luminosity', &
      'H_reaction_rate', 'He3_reaction_rate', 'He4_reaction_rate', &
      'C_reaction_rate', 'N_reaction_rate', 'O_reaction_rate', &
      'Other_reaction_rate']

   type :: rawset
      real(real64), allocatable :: v(:, :)
   end type rawset

contains

   subroutine loadmon(path, ifirst, ilast)
      character(len=*), intent(in) :: path
      integer(int32), intent(in) :: ifirst, ilast

      integer :: iunit, iostat, ncurrent, npts, i, j
      integer(int32) :: ndata, ncap, m, fld
      real(real64) :: time, tint, tintn, mass, lolsun
      real(real64) :: ltc, lpc, ltca, lpca
      type(convtype), allocatable :: recs(:)

      open (NEWUNIT=iunit, FILE=trim(path), STATUS='OLD', ACTION='READ', &
            FORM='UNFORMATTED', ACCESS='SEQUENTIAL', IOSTAT=iostat)
      if (iostat /= 0) &
         error stop '[loadmon] cannot open '//trim(path)

      ncap = 128
      ndata = 0
      allocate (recs(ncap))
      call reset_field_registry(MON_NFIELDS)
      field_names = MON_FIELD_NAMES

      do
         read (iunit, IOSTAT=iostat) ncurrent, time, tint, tintn, mass, &
            lolsun, ltc, lpc, ltca, lpca, npts
         if (iostat /= 0) exit
         if (npts < 1) error stop '[loadmon] invalid cell count'
         backspace (iunit, IOSTAT=iostat)
         if (iostat /= 0) error stop '[loadmon] cannot backspace record'

         block
            real(real64), allocatable :: omx(:), up(:), rhop(:)
            real(real64), allocatable :: f(:, :), fa(:, :)
            real, allocatable :: dx(:), vconvp(:), w(:, :), wd(:, :)
            integer(int16), allocatable :: kcvtn(:)
            type(rawset) :: raw

            allocate (omx(npts), dx(npts), kcvtn(npts), up(npts), &
                      rhop(npts), vconvp(npts), f(4, npts), fa(4, npts), &
                      w(7, npts), wd(7, npts))
            read (iunit, IOSTAT=iostat) ncurrent, time, tint, tintn, mass, &
               lolsun, ltc, lpc, ltca, lpca, npts, &
               (omx(j), dx(j), kcvtn(j), up(j), rhop(j), vconvp(j), &
                (f(i, j), fa(i, j), i=1, 4), &
                (w(i, j), wd(i, j), i=1, 7), j=1, npts)
            if (iostat /= 0) exit
            if (ncurrent < ifirst .or. ncurrent > ilast) cycle

            ndata = ndata + 1
            if (ndata > ncap) call grow_models(recs, ncap, ndata - 1)
            call build_mon_record(recs(ndata), raw, ncurrent, npts, &
                                  time, tint, mass, ltc, lpc, omx, rhop, &
                                  kcvtn, f, wd)
         end block
      end do

      if (ndata < 2) then
         close (iunit)
         error stop '[loadmon] need at least 2 models in range'
      end if

      do fld = 1, MON_NFIELDS
         call finalize_field_log(fld)
      end do

      rewind (iunit, IOSTAT=iostat)
      if (iostat /= 0) error stop '[loadmon] cannot rewind '//trim(path)
      m = 0
      do
         read (iunit, IOSTAT=iostat) ncurrent, time, tint, tintn, mass, &
            lolsun, ltc, lpc, ltca, lpca, npts
         if (iostat /= 0) exit
         if (npts < 1) error stop '[loadmon] invalid cell count'
         backspace (iunit, IOSTAT=iostat)
         if (iostat /= 0) error stop '[loadmon] cannot backspace record'

         block
            real(real64), allocatable :: omx(:), up(:), rhop(:)
            real(real64), allocatable :: f(:, :), fa(:, :)
            real, allocatable :: dx(:), vconvp(:), w(:, :), wd(:, :)
            integer(int16), allocatable :: kcvtn(:)
            type(rawset) :: raw

            allocate (omx(npts), dx(npts), kcvtn(npts), up(npts), &
                      rhop(npts), vconvp(npts), f(4, npts), fa(4, npts), &
                      w(7, npts), wd(7, npts))
            read (iunit, IOSTAT=iostat) ncurrent, time, tint, tintn, mass, &
               lolsun, ltc, lpc, ltca, lpca, npts, &
               (omx(j), dx(j), kcvtn(j), up(j), rhop(j), vconvp(j), &
                (f(i, j), fa(i, j), i=1, 4), &
                (w(i, j), wd(i, j), i=1, 7), j=1, npts)
            if (iostat /= 0) exit
            if (ncurrent < ifirst .or. ncurrent > ilast) cycle

            m = m + 1
            if (m > ndata) error stop '[loadmon] file changed between passes'
            if (ncurrent /= recs(m)%ncyc .or. &
                npts /= recs(m)%ncoord) &
               error stop '[loadmon] file changed between passes'
            call build_mon_fields(raw, npts, ltc, lpc, rhop, f, wd)
            recs(m)%nfld = MON_NFIELDS
            allocate (recs(m)%fld(MON_NFIELDS))
            do fld = 1, MON_NFIELDS
               call build_field_layer(raw%v(:, fld), npts, fld, &
                                      recs(m)%fld(fld))
            end do
         end block
      end do
      close (iunit)
      if (m /= ndata) error stop '[loadmon] file changed between passes'

      if (allocated(data)) deallocate (data)
      allocate (data(ndata))
      data = recs(1:ndata)
      deallocate (recs)

      call sort_models()
      print *, '[loadmon] Loaded models', data(1)%ncyc, ' - ', &
         data(size(data))%ncyc
   end subroutine loadmon

   subroutine grow_models(recs, ncap, nkeep)
      type(convtype), allocatable, intent(inout) :: recs(:)
      integer(int32), intent(inout) :: ncap
      integer(int32), intent(in) :: nkeep
      type(convtype), allocatable :: newrecs(:)

      ncap = int(ncap*GROW_FAC)
      allocate (newrecs(ncap))
      newrecs(1:nkeep) = recs(1:nkeep)
      call move_alloc(newrecs, recs)
   end subroutine grow_models

   subroutine build_mon_record(cnv, raw, model, nz, time, dt, mass, ltc, &
                               lpc, omx, rhop, kcvtn, f, wd)
      type(convtype), intent(out) :: cnv
      type(rawset), intent(out) :: raw
      integer, intent(in) :: model, nz
      real(real64), intent(in) :: time, dt, mass, ltc, lpc
      real(real64), intent(in) :: omx(:), rhop(:), f(:, :)
      integer(int16), intent(in) :: kcvtn(:)
      real, intent(in) :: wd(:, :)

      integer(int32) :: j, fld
      real(real64) :: radius, dm
      real(real64), allocatable :: xm(:), rn(:), eps(:)
      character(len=1), allocatable :: zones(:)

      allocate (xm(nz), rn(nz), eps(nz), zones(nz))
      call build_mon_fields(raw, nz, ltc, lpc, rhop, f, wd)

      radius = 0.d0
      do j = 1, nz
         xm(j) = mass*(1.d0 - omx(j))**3
         radius = radius + f(3, j)
         rn(j) = SOLRAD*radius

         dm = xm(j)
         if (j > 1) dm = xm(j) - xm(j - 1)
         ! this dl-based rate includes gravothermal terms, so it approximates the nuclear rate
         if (dm > 0.d0) then
            eps(j) = f(1, j)*LSUN/dm
         else
            eps(j) = 0.d0
         end if
         zones(j) = mon_type_char(kcvtn(j))
      end do

      do fld = 1, MON_NFIELDS
         do j = 1, nz
            call update_field_range(fld, raw%v(j, fld))
         end do
      end do

      cnv%nvers = REC_NVERS
      cnv%ncyc = model
      cnv%ncoord = nz
      cnv%timesec = time
      cnv%dt = dt
      cnv%toffset = 0.d0
      cnv%idx_kind_len = idx_kind_len
      cnv%nuc_kind_len = nuc_kind_len
      cnv%ladv = 0
      cnv%nadv = 0
      cnv%levcnv = 0
      cnv%abun = 0.d0
      cnv%aw = 0.d0
      cnv%angltv = 0.d0
      cnv%xmcoord = xm
      cnv%rncoord = rn

      call build_zones(zones, nz, cnv)
      call build_energy(eps, nz, cnv%nnuc, cnv%nuc, cnv%inuc)
      cnv%nneu = 0
      allocate (cnv%neu(0), cnv%ineu(0))

      cnv%minloss = EPS_BASE
      cnv%mingain = EPS_BASE
      cnv%minnucl = EPS_BASE
      cnv%minnucg = EPS_BASE
      cnv%minneul = EPS_BASE
      cnv%minneug = EPS_BASE
      cnv%minlossd = 0
      cnv%mingaind = 0
      cnv%minnucld = 0
      cnv%minnucgd = 0
      cnv%minneuld = 0
      cnv%minneugd = 0

      call alloc_empty_layers(cnv)
      deallocate (xm, rn, eps, zones)
   end subroutine build_mon_record

   subroutine build_mon_fields(raw, nz, ltc, lpc, rhop, f, wd)
      type(rawset), intent(out) :: raw
      integer, intent(in) :: nz
      real(real64), intent(in) :: ltc, lpc, rhop(:), f(:, :)
      real, intent(in) :: wd(:, :)

      integer :: j
      real(real64) :: lum, ln_temp, ln_pressure

      allocate (raw%v(nz, MON_NFIELDS))
      lum = 0.d0
      ln_temp = ltc
      ln_pressure = lpc
      do j = 1, nz
         lum = lum + f(1, j)
         ln_temp = ln_temp + f(2, j)
         ln_pressure = ln_pressure + f(4, j)
         raw%v(j, 1) = exp(ln_temp)
         raw%v(j, 2) = rhop(j)
         raw%v(j, 3) = exp(ln_pressure)
         raw%v(j, 4) = lum
         raw%v(j, 5:11) = real(wd(1:7, j), real64)
      end do
   end subroutine build_mon_fields

   pure function mon_type_char(m) result(c)
      integer(int16), intent(in) :: m
      character(len=1) :: c

      select case (m)
      case (0); c = ' '
      case (1, 2); c = 'C'
      case (3); c = 'O'
      case default; c = 'C'
      end select
   end function mon_type_char

end module monload
