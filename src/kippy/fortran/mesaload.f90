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

! mesaload.f90 -- MESA profile and .kipp readers, and the input dispatcher
module mesaload
   !! MESA profile and `.kipp` readers, and dispatcher over every input format.
   !!
   !! `load_convection` picks reader from path ("Input formats", docs/formats.md); every reader
   !! fills `convdata%data` w/ one `.cnv`-layout record per model. Non-structural source columns
   !! (every named `.kipp` column, a curated MESA set) register as colour fields, binned into
   !! `FIELD_NBINS` levels over whole-sequence range.

   use typedef, only: &
      int32, int64, real64
   use convdata, only: &
      convtype, data, nuc_kind_len, idx_kind_len, field_names, field_units, &
      ZONE_CHAR, RADIATIVE, NEUTRAL, OVERSHOOT, SEMICONV, CONVECTIVE, THERMOHALINE
   use convbuild, only: &
      SOLMASS, SOLRAD, YR, EPS_BASE, GROW_FAC, REC_NVERS, &
      build_zones, build_energy, build_field_layer, alloc_empty_layers, &
      reset_field_registry, update_field_range, finalize_field_log
   use convload, only: &
      loadconv, sort_models
   use units, only: &
      unit_id, UNAME, UDIM, UFAC, DIM_TIME, DIM_MASS, DIM_LENGTH
   use monload, only: &
      loadmon
!$ use omp_lib, only: omp_get_max_threads

   implicit none (type, external)
   private

   public :: loadmesa, load_convection, cnv_loaded, kipp_axis_units

   logical :: cnv_loaded = .false.
      !! Last load went through `.cnv` reader, whose grid may be reduced.

   character(len=4) :: kipp_axis_units(3) = ''
      !! Units a `.kipp` header states for age, mass and radius columns, blank where none.
      !!
      !! Indexed by `DIM_TIME`, `DIM_MASS`, `DIM_LENGTH`.

   integer(int32), parameter :: MESA_MAX_THREADS = 4
      !! Cap on profile-read thread pool.
      !!
      !! Parsing is memory-bandwidth bound, peaking around 3 to 4 threads; a lower `OMP_NUM_THREADS`
      !! overrides it at runtime.

   integer(int32), parameter :: MESA_NO_MIXING = 0
      !! MESA `no_mixing`, drawn as radiative.
      !!
      !! Mixing codes named as in MESA r26.04.1 const/public/const_def.f90.
   integer(int32), parameter :: MESA_CONVECTIVE_MIXING = 1
      !! MESA `convective_mixing`, drawn as convective.
   integer(int32), parameter :: MESA_OVERSHOOT_MIXING = 2
      !! MESA `overshoot_mixing`, drawn as overshoot.
   integer(int32), parameter :: MESA_SEMICONVECTIVE_MIXING = 3
      !! MESA `semiconvective_mixing`, drawn as semiconvective.
   integer(int32), parameter :: MESA_THERMOHALINE_MIXING = 4
      !! MESA `thermohaline_mixing`, drawn as thermohaline.
   integer(int32), parameter :: MESA_ROTATION_MIXING = 5
      !! MESA `rotation_mixing`, drawn as neutral.
   integer(int32), parameter :: MESA_LEFTOVER_CONVECTIVE_MIXING = 9
      !! MESA `leftover_convective_mixing`, drawn as convective.

   integer(int32), parameter :: MESA_NCAND = 9
      !! Number of curated MESA colour-field columns.
   character(len=16), parameter :: MESA_FIELD_CAND(MESA_NCAND) = [ &
      character(len=16) :: 'logT', 'logRho', 'logL', 'luminosity', 'logP', &
      'pressure', 'opacity', 'entropy', 'velocity']
      !! Curated MESA profile body columns offered as colour fields.
      !!
      !! Only these scalars are read, since full body is huge; names absent from a run are skipped.

   type :: rawset
      !! Colour-field values of one profile, held between parallel read and serial binning.
      real(real64), allocatable :: v(:, :)
         !! Value per cell (rows, centre to surface) and field (columns).
   end type rawset

contains

   subroutine load_convection(path, ifirst, ilast)
      !! Load any supported input into `data`, reader picked from path.
      !!
      !! Basename `seq.*` or `*.seq`: MONASH; `.kipp`: raw float64 cell stream; directory holding
      !! `profiles.index`: MESA run; else KEPLER `.cnv`. Lets every format work wherever a `.cnv`
      !! path did.
      ! Arguments
      character(len=*), intent(in) :: path
         !! Input path.
      integer(int32), intent(in) :: ifirst
         !! First model number to load.
      integer(int32), intent(in) :: ilast
         !! Last model number to load.
      integer(int32) :: slash
      character(len=:), allocatable :: basename
      logical :: is_mesa
      cnv_loaded = .false.
      slash = index(trim(path), '/', back=.true.)
      basename = path(slash + 1:len_trim(path))
      if ((len_trim(basename) >= 4 .and. basename(1:4) == 'seq.') .or. &
          has_suffix(basename, '.seq')) then
         call loadmon(path, ifirst, ilast)
         return
      end if
      if (has_suffix(path, '.kipp')) then
         call loadkipp(path, ifirst, ilast)
         return
      end if
      inquire (file=trim(path)//'/profiles.index', exist=is_mesa)
      if (is_mesa) then
         call loadmesa(path, ifirst, ilast)
      else
         call loadconv(path, ifirst, ilast)
         cnv_loaded = .true.
      end if
   end subroutine load_convection

   subroutine loadmesa(dirname, ifirst, ilast)
      !! Load profiles of MESA run directory into `data`.
      !!
      !! `profiles.index` maps model numbers `ifirst` to `ilast` to profiles, at least 2 in range.
      !! Each profile becomes one record (model number, age, mass and radius grid, zones from
      !! `mixing_type`, energy layers from `eps_nuc` and `eps_nuc_neu_total`), parsed concurrently
      !! w/ OpenMP by at most `MESA_MAX_THREADS` threads; field ranges and layers then built
      !! serially, then `sort_models`.
      ! Arguments
      character(len=*), intent(in) :: dirname
         !! Path of MESA run directory.
      integer(int32), intent(in) :: ifirst
         !! First model number to load.
      integer(int32), intent(in) :: ilast
         !! Last model number to load.

      integer(int32) :: iunit, iostat, nidx, i, nkeep, m, prio, pf, nthreads
      integer(int32) :: nf, f, k
      integer(int32), allocatable :: mdl(:), prof(:), fld_col(:)
      character(len=256) :: idxfile
      type(rawset), allocatable :: rf(:)

      idxfile = trim(dirname)//'/profiles.index'
      open (NEWUNIT=iunit, FILE=trim(idxfile), STATUS='OLD', &
            ACTION='READ', IOSTAT=iostat)
      if (iostat /= 0) &
         error stop '[loadmesa] cannot open profiles.index'

      ! line 1 holds the model count; the rest are model / priority / profile
      read (iunit, *, IOSTAT=iostat) nidx
      if (iostat /= 0) &
         error stop '[loadmesa] cannot read profiles.index header'

      allocate (mdl(nidx), prof(nidx))
      nkeep = 0
      do i = 1, nidx
         read (iunit, *, IOSTAT=iostat) m, prio, pf
         if (iostat /= 0) exit
         if (m < ifirst .or. m > ilast) cycle
         nkeep = nkeep + 1
         mdl(nkeep) = m
         prof(nkeep) = pf
      end do
      close (iunit)

      if (nkeep < 2) &
         error stop '[loadmesa] need at least 2 profiles in range'

      if (allocated(data)) deallocate (data)
      allocate (data(nkeep))
      allocate (rf(nkeep))

      ! register the colour fields present in this run from the first profile's
      ! body header, so every read_profile call fills the same field slots
      call register_mesa_fields(dirname, prof(1), fld_col, nf)

      ! each profile parses into its own data(i) slot with no shared state, so
      ! read them concurrently. schedule(dynamic) balances the uneven per-file
      ! cost (profiles differ in zone count). read_profile uses NEWUNIT units
      ! and only local storage, so it is thread-safe as written
      nthreads = 1
!$    nthreads = max(1, min(omp_get_max_threads(), MESA_MAX_THREADS))
      !$omp parallel do default(shared) private(i) schedule(dynamic) &
      !$omp num_threads(nthreads)
      do i = 1, nkeep
         call read_profile(dirname, prof(i), data(i), fld_col, nf, rf(i))
         data(i)%ncyc = mdl(i)     ! index mapping is authoritative
      end do
      !$omp end parallel do
      deallocate (mdl, prof)

      ! range over the whole sequence, then quantize each profile's raw field
      ! columns into its record's fld layers (serial: the reduction and the
      ! shared registry are not thread-safe)
      do i = 1, nkeep
         do f = 1, nf
            do k = 1, size(rf(i)%v, 1)
               call update_field_range(f, rf(i)%v(k, f))
            end do
         end do
      end do
      do f = 1, nf
         call finalize_field_log(f)
      end do
      do i = 1, nkeep
         data(i)%nfld = nf
         if (nf > 0) allocate (data(i)%fld(2, nf))
         do f = 1, nf
            call build_field_layer(rf(i)%v(:, f), size(rf(i)%v, 1), f, &
                                   data(i)%fld(:, f))
         end do
      end do
      deallocate (rf, fld_col)

      call sort_models()
      print *, '[loadmesa] Loaded models', data(1)%ncyc, ' - ', &
         data(size(data))%ncyc
   end subroutine loadmesa

   subroutine register_mesa_fields(dirname, pnum, fld_col, nf)
      !! Register curated colour fields present in a run.
      !!
      !! Matches one profile's body header against `MESA_FIELD_CAND`, setting shared registry and
      !! each matched field's body column.
      ! Arguments
      character(len=*), intent(in) :: dirname
         !! Path of MESA run directory.
      integer(int32), intent(in) :: pnum
         !! Profile number whose body header is read.
      integer(int32), allocatable, intent(out) :: fld_col(:)
         !! Body column of each registered field.
      integer(int32), intent(out) :: nf
         !! Number of registered fields.
      integer(int32) :: iunit, iostat, c, ci
      integer(int32), allocatable :: tmpcol(:)
      integer(int32) :: tmpcand(MESA_NCAND)
      character(len=256) :: fname, bnames
      character(len=8192) :: scratch

      fname = trim(dirname)//'/profile'//trim(itoa(pnum))//'.data'
      open (NEWUNIT=iunit, FILE=trim(fname), STATUS='OLD', &
            ACTION='READ', IOSTAT=iostat)
      if (iostat /= 0) &
         error stop '[register_mesa_fields] cannot open '//trim(fname)
      read (iunit, '(a)') scratch      ! 1 header col indices
      read (iunit, '(a)') scratch      ! 2 header names
      read (iunit, '(a)') scratch      ! 3 header values
      read (iunit, '(a)') scratch      ! 4 blank
      read (iunit, '(a)') scratch      ! 5 body col indices
      read (iunit, '(a)') bnames       ! 6 body names
      close (iunit)

      allocate (tmpcol(MESA_NCAND))
      nf = 0
      do c = 1, MESA_NCAND
         ci = col_index(bnames, trim(MESA_FIELD_CAND(c)))
         if (ci < 1) cycle
         nf = nf + 1
         tmpcol(nf) = ci
         tmpcand(nf) = c
      end do

      call reset_field_registry(nf)
      allocate (fld_col(nf))
      do c = 1, nf
         fld_col(c) = tmpcol(c)
         field_names(c) = MESA_FIELD_CAND(tmpcand(c))
      end do
      deallocate (tmpcol)
   end subroutine register_mesa_fields

   subroutine loadkipp(path, ifirst, ilast)
      !! Stream raw `.kipp` cell file into `data`.
      !!
      !! One contiguous float64 array of `ncols`-wide cells, grouped by model, surface to centre
      !! within a model, column layout from sidecar header `<path>.hdr` (docs/kippfiles.md). Read in
      !! large chunks holding only current model's cells and finished records, so multi-GB files
      !! never fully reside in memory. Pass one builds records and field ranges; `fill_kipp_fields`
      !! bins fields in pass two.
      ! Arguments
      character(len=*), intent(in) :: path
         !! Path of `.kipp` file.
      integer(int32), intent(in) :: ifirst
         !! First model number to load.
      integer(int32), intent(in) :: ilast
         !! Last model number to load.

      integer(int32), parameter :: CHUNK = 65536

      character(len=512) :: hdrfile
      integer(int32) :: ncols, ncols2
      integer(int32) :: c_model, c_age, c_dt, c_mass, c_radius, c_mix, c_eps
      integer(int32) :: iunit, iostat, j, m, ndata, ncap, cur, nz, zcap, nf, f
      integer(int64) :: fbytes, ncells, ndone, take
      real(real64) :: tsec, dtsec, fage, fdt, fmass, frad
      logical :: stopping
      real(real64), allocatable :: buf(:, :)
      real(real64), allocatable :: am(:), ar(:), ae(:)
      integer(int32), allocatable :: amt(:)
      integer(int32), allocatable :: fld_col(:)
      character(len=32), allocatable :: colnames(:), colunits(:)
      character(len=4) :: dtunit
      type(convtype), allocatable :: recs(:)

      call find_kipp_header(path, hdrfile)
      call parse_kipp_header(hdrfile, ncols, c_model, c_age, c_dt, &
                             c_mass, c_radius, c_mix, c_eps)
      call kipp_colnames(hdrfile, ncols2, colnames, colunits)
      call register_kipp_fields(colnames, colunits, ncols, fld_col, nf)
      ! factors to s, g and cm; unstated units are those the names imply
      call kipp_axis_unit(colnames(c_age), colunits(c_age), DIM_TIME, YR, &
                          fage, kipp_axis_units(DIM_TIME))
      fdt = 1.d0
      if (c_dt > 0) call kipp_axis_unit(colnames(c_dt), colunits(c_dt), DIM_TIME, &
                                        1.d0, fdt, dtunit)
      call kipp_axis_unit(colnames(c_mass), colunits(c_mass), DIM_MASS, 1.d0, &
                          fmass, kipp_axis_units(DIM_MASS))
      call kipp_axis_unit(colnames(c_radius), colunits(c_radius), DIM_LENGTH, 1.d0, &
                          frad, kipp_axis_units(DIM_LENGTH))

      open (NEWUNIT=iunit, FILE=trim(path), STATUS='OLD', ACTION='READ', &
            FORM='UNFORMATTED', ACCESS='STREAM', CONVERT='little_endian', &
            IOSTAT=iostat)
      if (iostat /= 0) &
         error stop '[loadkipp] cannot open '//trim(path)

      inquire (UNIT=iunit, SIZE=fbytes)
      ncells = fbytes/(int(ncols, int64)*8_int64)
      if (ncells < 2) &
         error stop '[loadkipp] file too small'

      ncap = 1024
      allocate (recs(ncap))
      ndata = 0

      zcap = 8192
      allocate (am(zcap), ar(zcap), ae(zcap), amt(zcap))
      nz = 0
      cur = -huge(1_int32)
      tsec = 0.d0; dtsec = 0.d0
      stopping = .false.

      ! pass A: build the coord/convection/eps records and, in the same sweep,
      ! accumulate the global min/max of every registered field.  fields are
      ! quantized in a second streaming pass (below) once the range is known,
      ! which keeps only the compact step functions resident rather than the
      ! full raw columns of the whole file.
      allocate (buf(ncols, CHUNK))
      ndone = 0
      do while (ndone < ncells .and. .not. stopping)
         take = min(int(CHUNK, int64), ncells - ndone)
         read (iunit, IOSTAT=iostat) buf(:, 1:take)
         if (iostat /= 0) &
            error stop '[loadkipp] short read'
         ndone = ndone + take
         do j = 1, int(take, int32)
            m = nint(buf(c_model, j))
            if (m /= cur) then
               ! model_number rises monotonically across the stream, so a
               ! change means the previous model is complete
               call flush_kipp(recs, ndata, ncap, cur, nz, tsec, dtsec, &
                               am, ar, amt, ae, ifirst, ilast)
               cur = m
               nz = 0
               if (m > ilast) then
                  stopping = .true.
                  exit
               end if
            end if
            if (m < ifirst .or. m > ilast) cycle
            nz = nz + 1
            if (nz > zcap) call grow_accum(am, ar, ae, amt, zcap)
            am(nz) = buf(c_mass, j)*fmass
            ar(nz) = buf(c_radius, j)*frad
            amt(nz) = nint(buf(c_mix, j))
            ae(nz) = buf(c_eps, j)
            tsec = buf(c_age, j)*fage
            if (c_dt > 0) dtsec = buf(c_dt, j)*fdt
            do f = 1, nf
               call update_field_range(f, buf(fld_col(f), j))
            end do
         end do
      end do
      call flush_kipp(recs, ndata, ncap, cur, nz, tsec, dtsec, &
                      am, ar, amt, ae, ifirst, ilast)
      close (iunit)
      deallocate (buf, am, ar, ae, amt)

      if (ndata < 2) &
         error stop '[loadkipp] need at least 2 models in range'

      do f = 1, nf
         call finalize_field_log(f)
      end do

      ! pass B: quantize each field into recs(k)%fld.  recs is still in stream
      ! order (sort_models runs after), so the k-th in-range model of this pass
      ! lands in the same record it built in pass A.
      if (nf > 0) &
         call fill_kipp_fields(path, ncols, c_model, fld_col, nf, &
                               recs, ndata, ifirst, ilast)

      if (allocated(data)) deallocate (data)
      allocate (data(ndata))
      data(1:ndata) = recs(1:ndata)
      deallocate (recs)

      call sort_models()
      print *, '[loadkipp] Loaded models', data(1)%ncyc, ' - ', &
         data(size(data))%ncyc
   end subroutine loadkipp

   subroutine fill_kipp_fields(path, ncols, c_model, fld_col, nf, &
                               recs, ndata, ifirst, ilast)
      !! Re-read `.kipp` file and bin each registered field into `recs(k)%fld`.
      !!
      !! Second streaming pass of `loadkipp`: grouping mirrors pass one exactly (same model
      !! boundaries and range filter), so a running counter maps each completed in-range model to
      !! its record.
      ! Arguments
      character(len=*), intent(in) :: path
         !! Path of `.kipp` file.
      integer(int32), intent(in) :: ncols
         !! Number of values per cell.
      integer(int32), intent(in) :: c_model
         !! Column of model number.
      integer(int32), intent(in) :: nf
         !! Number of registered fields.
      integer(int32), intent(in) :: ndata
         !! Number of records pass one built.
      integer(int32), intent(in) :: ifirst
         !! First model number to load.
      integer(int32), intent(in) :: ilast
         !! Last model number to load.
      integer(int32), intent(in) :: fld_col(:)
         !! Column of each registered field.
      type(convtype), intent(inout) :: recs(:)
         !! Records of pass one, in stream order.

      integer(int32), parameter :: CHUNK = 65536
      integer(int32) :: iunit, iostat, j, m, cur, nz, zcap, counter, f
      integer(int64) :: fbytes, ncells, ndone, take
      logical :: stopping
      real(real64), allocatable :: buf(:, :), fb(:, :)

      open (NEWUNIT=iunit, FILE=trim(path), STATUS='OLD', ACTION='READ', &
            FORM='UNFORMATTED', ACCESS='STREAM', CONVERT='little_endian', &
            IOSTAT=iostat)
      if (iostat /= 0) &
         error stop '[fill_kipp_fields] cannot reopen '//trim(path)
      inquire (UNIT=iunit, SIZE=fbytes)
      ncells = fbytes/(int(ncols, int64)*8_int64)

      zcap = 8192
      allocate (fb(nf, zcap))
      nz = 0
      cur = -huge(1_int32)
      counter = 0
      stopping = .false.

      allocate (buf(ncols, CHUNK))
      ndone = 0
      do while (ndone < ncells .and. .not. stopping)
         take = min(int(CHUNK, int64), ncells - ndone)
         read (iunit, IOSTAT=iostat) buf(:, 1:take)
         if (iostat /= 0) &
            error stop '[fill_kipp_fields] short read'
         ndone = ndone + take
         do j = 1, int(take, int32)
            m = nint(buf(c_model, j))
            if (m /= cur) then
               call flush_kipp_fields(recs, counter, cur, nz, fb, nf, &
                                      ifirst, ilast)
               cur = m
               nz = 0
               if (m > ilast) then
                  stopping = .true.
                  exit
               end if
            end if
            if (m < ifirst .or. m > ilast) cycle
            nz = nz + 1
            if (nz > zcap) call grow_fb(fb, zcap)
            do f = 1, nf
               fb(f, nz) = buf(fld_col(f), j)
            end do
         end do
      end do
      call flush_kipp_fields(recs, counter, cur, nz, fb, nf, ifirst, ilast)
      close (iunit)
      deallocate (buf, fb)

      if (counter /= ndata) &
         error stop '[fill_kipp_fields] model grouping drifted between passes'
   end subroutine fill_kipp_fields

   subroutine flush_kipp_fields(recs, counter, model, nz, fb, nf, ifirst, ilast)
      !! Bin one model's accumulated field values into its record's `fld` layers.
      !!
      !! Values reversed from surface-to-centre (as read) to centre-to-surface; out-of-range or
      !! empty models skipped, as in pass one.
      ! Arguments
      type(convtype), intent(inout) :: recs(:)
         !! Records of pass one, in stream order.
      integer(int32), intent(inout) :: counter
         !! Index of last filled record, advanced by one when model is kept.
      integer(int32), intent(in) :: model
         !! Model number.
      integer(int32), intent(in) :: nz
         !! Number of cells.
      integer(int32), intent(in) :: nf
         !! Number of registered fields.
      integer(int32), intent(in) :: ifirst
         !! First model number to load.
      integer(int32), intent(in) :: ilast
         !! Last model number to load.
      real(real64), intent(in) :: fb(:, :)
         !! Value of each field (rows) and cell (columns, surface to centre).
      real(real64), allocatable :: raw(:)
      integer(int32) :: f, k

      if (nz < 1) return
      if (model < ifirst .or. model > ilast) return
      counter = counter + 1
      if (recs(counter)%ncyc /= model) &
         error stop '[flush_kipp_fields] record/model mismatch between passes'

      recs(counter)%nfld = nf
      allocate (recs(counter)%fld(2, nf))
      allocate (raw(nz))
      do f = 1, nf
         do k = 1, nz
            raw(k) = fb(f, nz - k + 1)
         end do
         call build_field_layer(raw, nz, f, recs(counter)%fld(:, f))
      end do
      deallocate (raw)
   end subroutine flush_kipp_fields

   subroutine grow_fb(fb, zcap)
      !! Double cell capacity of field accumulation buffer, keeping contents.
      ! Arguments
      real(real64), allocatable, intent(inout) :: fb(:, :)
         !! Value of each field (rows) and cell (columns).
      integer(int32), intent(inout) :: zcap
         !! Cell capacity, doubled.
      real(real64), allocatable :: t(:, :)
      integer(int32) :: old
      old = zcap
      zcap = zcap*2
      allocate (t(size(fb, 1), zcap))
      t(:, 1:old) = fb
      call move_alloc(t, fb)
   end subroutine grow_fb

   subroutine kipp_colnames(hdrfile, ncols, names, colunits)
      !! Read every column name and optional unit of a `.kipp` sidecar header, in column order.
      !!
      !! Second read of header, after `parse_kipp_header`; unit is third word of a column line
      !! ("Header file", docs/kippfiles.md), columns w/o a name line are blank.
      ! Arguments
      character(len=*), intent(in) :: hdrfile
         !! Path of sidecar header.
      integer(int32), intent(out) :: ncols
         !! Number of columns, from `ncols` line, or 512 if missing.
      character(len=32), allocatable, intent(out) :: names(:)
         !! Name of each column, blank if unnamed.
      character(len=32), allocatable, intent(out) :: colunits(:)
         !! Unit of each column, blank if none stated.
      integer(int32), parameter :: MAXC = 512
      integer(int32) :: iunit, iostat, idx
      character(len=256) :: line, key, nm
      character(len=32) :: tmp(MAXC), utmp(MAXC)

      tmp = ''; utmp = ''
      ncols = 0
      open (NEWUNIT=iunit, FILE=trim(hdrfile), STATUS='OLD', ACTION='READ', &
            IOSTAT=iostat)
      if (iostat /= 0) &
         error stop '[kipp_colnames] cannot open '//trim(hdrfile)
      do
         read (iunit, '(a)', IOSTAT=iostat) line
         if (iostat /= 0) exit
         line = adjustl(line)
         if (len_trim(line) == 0) cycle
         read (line, *, IOSTAT=iostat) key
         if (iostat /= 0) cycle
         if (key == 'ncols') then
            read (line, *, IOSTAT=iostat) key, ncols
         else if (key == 'dtype' .or. key == 'columns' .or. key == 'columns:') then
            cycle
         else
            read (line, *, IOSTAT=iostat) idx, nm
            if (iostat /= 0) cycle
            if (idx >= 1 .and. idx <= MAXC) then
               tmp(idx) = nm
               utmp(idx) = third_word(line)
            end if
         end if
      end do
      close (iunit)
      if (ncols < 1) ncols = MAXC
      allocate (names(ncols), colunits(ncols))
      names = tmp(1:ncols)
      colunits = utmp(1:ncols)
   end subroutine kipp_colnames

   pure function third_word(line) result(w)
      !! Return third blank-separated word of header line, blank if none.
      !!
      !! Not read list-directed, which would end unit at a `/`.
      ! Arguments
      character(len=*), intent(in) :: line
         !! Header line.
      character(len=len(line)) :: w
      integer(int32) :: k, p
      w = adjustl(line)
      do k = 1, 2
         p = index(trim(w), ' ')
         if (p == 0) then
            w = ''
            return
         end if
         w = adjustl(w(p:))
      end do
      p = index(w, ' ')
      if (p > 0) w = w(1:p - 1)
   end function third_word

   subroutine kipp_axis_unit(col, tok, dm, def, fac, unit)
      !! Find cgs factor of a `.kipp` age, time step, mass or radius column.
      !!
      !! `def` when header gives no unit, else stated unit's factor, which must have dimension `dm`.
      !! Any other unit stops load w/ error listing allowed units.
      ! Arguments
      character(len=*), intent(in) :: col
         !! Column name, for the error message.
      character(len=*), intent(in) :: tok
         !! Unit the header states, blank if none.
      integer(int32), intent(in) :: dm
         !! Dimension code of column, a `units` `DIM_` constant.
      real(real64), intent(in) :: def
         !! Factor of unit column name implies.
      real(real64), intent(out) :: fac
         !! Factor to cgs.
      character(len=*), intent(out) :: unit
         !! `UNAME` entry of stated unit, blank if none.
      character(len=64) :: allowed
      integer(int32) :: k
      fac = def; unit = ''
      if (len_trim(tok) == 0) return
      k = unit_id(tok)
      if (k > 0) then
         if (UDIM(k) == dm) then
            fac = UFAC(k); unit = UNAME(k)
            return
         end if
      end if
      allowed = ''
      do k = 1, size(UNAME)
         if (UDIM(k) == dm) allowed = trim(allowed)//' '//trim(UNAME(k))
      end do
      error stop '[loadkipp] column '//trim(col)//' has unit '//trim(tok)// &
         '; use one of'//trim(allowed)
   end subroutine kipp_axis_unit

   subroutine register_kipp_fields(names, colunits, ncols, fld_col, nf)
      !! Register every named non-structural `.kipp` column as a colour field.
      !!
      !! Sets names, units and reset ranges of shared registry in convdata.f90.
      ! Arguments
      character(len=*), intent(in) :: names(:)
         !! Name of each column, blank if unnamed.
      character(len=*), intent(in) :: colunits(:)
         !! Unit of each column, blank if none.
      integer(int32), intent(in) :: ncols
         !! Number of columns.
      integer(int32), allocatable, intent(out) :: fld_col(:)
         !! Source column of each registered field.
      integer(int32), intent(out) :: nf
         !! Number of registered fields.
      integer(int32) :: c
      integer(int32), allocatable :: tmpcol(:)

      allocate (tmpcol(ncols))
      nf = 0
      do c = 1, ncols
         if (len_trim(names(c)) == 0) cycle
         if (is_structural_kipp(names(c))) cycle
         nf = nf + 1
         tmpcol(nf) = c
      end do
      call reset_field_registry(nf)
      allocate (fld_col(nf))
      do c = 1, nf
         fld_col(c) = tmpcol(c)
         field_names(c) = names(tmpcol(c))
         field_units(c) = colunits(tmpcol(c))
      end do
      deallocate (tmpcol)
   end subroutine register_kipp_fields

   pure function is_structural_kipp(name) result(yes)
      !! Test whether `.kipp` column is structural, so not offered as colour field.
      !!
      !! Structural: accepted names of required columns ("Required columns", docs/kippfiles.md) and
      !! `mlt_mixing_type`.
      ! Arguments
      character(len=*), intent(in) :: name
         !! Column name.
      logical :: yes
      select case (trim(name))
      case ('model_number', 'model', &
            'star_age_yr', 'star_age', 'age_yr', 'dt_s', 'dt', &
            'm_g', 'mass_g', 'mass', 'r_cm', 'radius_cm', 'r', &
            'mixing_type', 'mix_type', 'mixing', 'mlt_mixing_type', &
            'eps_net_erg_g_s', 'eps_nuc', 'eps_net', 'eps')
         yes = .true.
      case default
         yes = .false.
      end select
   end function is_structural_kipp

   subroutine flush_kipp(recs, ndata, ncap, model, nz, tsec, dtsec, &
                         am, ar, amt, ae, ifirst, ilast)
      !! Append record of one model's accumulated cells to `recs`.
      !!
      !! Cells reversed from surface-to-centre (as read) to centre-to-surface; `recs` grows by
      !! `GROW_FAC` when full; out-of-range or empty models produce nothing.
      ! Arguments
      type(convtype), allocatable, intent(inout) :: recs(:)
         !! Records built so far, in stream order.
      integer(int32), intent(inout) :: ndata
         !! Number of records in `recs`.
      integer(int32), intent(inout) :: ncap
         !! Capacity of `recs`.
      integer(int32), intent(in) :: model
         !! Model number.
      integer(int32), intent(in) :: nz
         !! Number of cells.
      integer(int32), intent(in) :: ifirst
         !! First model number to load.
      integer(int32), intent(in) :: ilast
         !! Last model number to load.
      real(real64), intent(in) :: tsec
         !! Age (s).
      real(real64), intent(in) :: dtsec
         !! Time step (s).
      real(real64), intent(in) :: am(:)
         !! Mass coordinate of each cell (g), surface to centre.
      real(real64), intent(in) :: ar(:)
         !! Radius coordinate of each cell (cm), surface to centre.
      real(real64), intent(in) :: ae(:)
         !! Energy rate of each cell (erg/g/s), surface to centre.
      integer(int32), intent(in) :: amt(:)
         !! MESA mixing code of each cell, surface to centre.
      type(convtype), allocatable :: tmp(:)
      real(real64), allocatable :: xm(:), rn(:), eps(:)
      integer(int32), allocatable :: mt(:)
      integer(int32) :: k, src

      if (nz < 1) return
      if (model < ifirst .or. model > ilast) return

      ndata = ndata + 1
      if (ndata > ncap) then
         ncap = int(ncap*GROW_FAC)
         allocate (tmp(ncap))
         tmp(1:ndata - 1) = recs(1:ndata - 1)
         deallocate (recs)
         call move_alloc(tmp, recs)
      end if

      ! reverse to the center -> surface ascending order the renderer expects
      allocate (xm(nz), rn(nz), eps(nz), mt(nz))
      do k = 1, nz
         src = nz - k + 1
         xm(k) = am(src)
         rn(k) = ar(src)
         eps(k) = ae(src)
         mt(k) = amt(src)
      end do

      call build_kipp_record(recs(ndata), model, nz, tsec, dtsec, xm, rn, mt, eps)
      deallocate (xm, rn, eps, mt)
   end subroutine flush_kipp

   subroutine build_kipp_record(cnv, model, nz, tsec, dtsec, xm, rn, mt, eps)
      !! Build record of one `.kipp` model.
      !!
      !! Age, mass and radius arrive in cgs (s, g, cm). Energy column is net (nuclear minus
      !! neutrino), driving `nuc` layer w/ both signs; `neu` layer stays empty.
      ! Arguments
      type(convtype), intent(out) :: cnv
         !! Record to build.
      integer(int32), intent(in) :: model
         !! Model number.
      integer(int32), intent(in) :: nz
         !! Number of cells.
      real(real64), intent(in) :: tsec
         !! Age (s).
      real(real64), intent(in) :: dtsec
         !! Time step (s).
      real(real64), intent(in) :: xm(:)
         !! Mass coordinate of each cell (g), centre to surface.
      real(real64), intent(in) :: rn(:)
         !! Radius coordinate of each cell (cm), centre to surface.
      real(real64), intent(in) :: eps(:)
         !! Net energy rate of each cell (erg/g/s), centre to surface.
      integer(int32), intent(in) :: mt(:)
         !! MESA mixing code of each cell, centre to surface.

      cnv%nvers = REC_NVERS
      cnv%ncyc = model
      cnv%ncoord = nz
      cnv%timesec = tsec
      cnv%dt = dtsec
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

      call build_mesa_zones(mt, nz, cnv)
      call build_energy(eps, nz, cnv%nnuc, cnv%nuc, cnv%inuc)

      cnv%nneu = 0
      allocate (cnv%neu(0), cnv%ineu(0))

      cnv%minloss = EPS_BASE
      cnv%mingain = EPS_BASE
      cnv%minnucl = EPS_BASE
      cnv%minnucg = EPS_BASE
      cnv%minneul = EPS_BASE
      cnv%minneug = EPS_BASE
      cnv%minlossd = 0; cnv%mingaind = 0
      cnv%minnucld = 0; cnv%minnucgd = 0
      cnv%minneuld = 0; cnv%minneugd = 0

      call alloc_empty_layers(cnv)
   end subroutine build_kipp_record

   subroutine grow_accum(am, ar, ae, amt, zcap)
      !! Double cell accumulation buffers of `loadkipp`, keeping contents.
      ! Arguments
      real(real64), allocatable, intent(inout) :: am(:)
         !! Mass coordinate of each cell.
      real(real64), allocatable, intent(inout) :: ar(:)
         !! Radius coordinate of each cell.
      real(real64), allocatable, intent(inout) :: ae(:)
         !! Energy rate of each cell.
      integer(int32), allocatable, intent(inout) :: amt(:)
         !! Mixing code of each cell.
      integer(int32), intent(inout) :: zcap
         !! Cell capacity, doubled.
      real(real64), allocatable :: t(:)
      integer(int32), allocatable :: ti(:)
      integer(int32) :: old

      old = zcap
      zcap = zcap*2
      allocate (t(zcap)); t(1:old) = am; call move_alloc(t, am)
      allocate (t(zcap)); t(1:old) = ar; call move_alloc(t, ar)
      allocate (t(zcap)); t(1:old) = ae; call move_alloc(t, ae)
      allocate (ti(zcap)); ti(1:old) = amt; call move_alloc(ti, amt)
   end subroutine grow_accum

   subroutine find_kipp_header(path, hdrfile)
      !! Locate sidecar header of `.kipp` file ("Header file", docs/kippfiles.md).
      !!
      !! Tries `<path>.hdr` next to data file, then `<basename>.hdr` in working directory (skipped
      !! if data file is there). Missing header stops load w/ error.
      ! Arguments
      character(len=*), intent(in) :: path
         !! Path of `.kipp` file.
      character(len=*), intent(out) :: hdrfile
         !! Path of header.
      integer(int32) :: slash
      logical :: ex

      hdrfile = trim(path)//'.hdr'
      inquire (file=trim(hdrfile), exist=ex)
      if (ex) return

      slash = index(trim(path), '/', back=.true.)
      if (slash > 0) then
         hdrfile = trim(path(slash + 1:))//'.hdr'
         inquire (file=trim(hdrfile), exist=ex)
         if (ex) return
      end if

      error stop '[loadkipp] cannot find sidecar .hdr for '//trim(path)
   end subroutine find_kipp_header

   subroutine parse_kipp_header(hdrfile, ncols, c_model, c_age, c_dt, &
                                c_mass, c_radius, c_mix, c_eps)
      !! Read `ncols` and required-role columns from `.kipp` sidecar header.
      !!
      !! First word of each line decides its use ("Header file", docs/kippfiles.md): `ncols N` gives
      !! row width, `<index> <name>` names a column, `dtype` and `columns` ignored. Missing `ncols`
      !! or required column stops load w/ error.
      ! Arguments
      character(len=*), intent(in) :: hdrfile
         !! Path of sidecar header.
      integer(int32), intent(out) :: ncols
         !! Number of values per cell.
      integer(int32), intent(out) :: c_model
         !! Column of model number.
      integer(int32), intent(out) :: c_age
         !! Column of age.
      integer(int32), intent(out) :: c_dt
         !! Column of time step, 0 if absent.
      integer(int32), intent(out) :: c_mass
         !! Column of mass coordinate.
      integer(int32), intent(out) :: c_radius
         !! Column of radius coordinate.
      integer(int32), intent(out) :: c_mix
         !! Column of mixing type.
      integer(int32), intent(out) :: c_eps
         !! Column of energy rate.
      integer(int32) :: iunit, iostat, idx
      character(len=256) :: line, key, name

      c_model = 0; c_age = 0; c_dt = 0
      c_mass = 0; c_radius = 0; c_mix = 0; c_eps = 0
      ncols = 0

      open (NEWUNIT=iunit, FILE=trim(hdrfile), STATUS='OLD', ACTION='READ', &
            IOSTAT=iostat)
      if (iostat /= 0) &
         error stop '[loadkipp] cannot open '//trim(hdrfile)

      do
         read (iunit, '(a)', IOSTAT=iostat) line
         if (iostat /= 0) exit
         line = adjustl(line)
         if (len_trim(line) == 0) cycle

         read (line, *, IOSTAT=iostat) key
         if (iostat /= 0) cycle

         if (key == 'ncols') then
            read (line, *, IOSTAT=iostat) key, ncols
         else if (key == 'dtype' .or. key == 'columns' .or. key == 'columns:') then
            cycle
         else
            ! "<index> <name>" column line; key holds the index token
            read (line, *, IOSTAT=iostat) idx, name
            if (iostat /= 0) cycle
            call assign_kipp_col(name, idx, c_model, c_age, c_dt, &
                                 c_mass, c_radius, c_mix, c_eps)
         end if
      end do
      close (iunit)

      if (ncols < 1) &
         error stop '[loadkipp] header missing ncols'
      if (min(c_model, c_age, c_mass, c_radius, c_mix, c_eps) < 1) &
         error stop '[loadkipp] header missing a required column'
   end subroutine parse_kipp_header

   subroutine assign_kipp_col(name, idx, c_model, c_age, c_dt, &
                              c_mass, c_radius, c_mix, c_eps)
      !! Assign header column to its role by accepted names ("Required columns", docs/kippfiles.md).
      !!
      !! Ignores unknown names, so extra stream columns are skipped.
      ! Arguments
      character(len=*), intent(in) :: name
         !! Column name.
      integer(int32), intent(in) :: idx
         !! Column index, from 1.
      integer(int32), intent(inout) :: c_model
         !! Column of model number.
      integer(int32), intent(inout) :: c_age
         !! Column of age.
      integer(int32), intent(inout) :: c_dt
         !! Column of time step.
      integer(int32), intent(inout) :: c_mass
         !! Column of mass coordinate.
      integer(int32), intent(inout) :: c_radius
         !! Column of radius coordinate.
      integer(int32), intent(inout) :: c_mix
         !! Column of mixing type.
      integer(int32), intent(inout) :: c_eps
         !! Column of energy rate.
      select case (trim(name))
      case ('model_number', 'model'); c_model = idx
      case ('star_age_yr', 'star_age', 'age_yr'); c_age = idx
      case ('dt_s', 'dt'); c_dt = idx
      case ('m_g', 'mass_g', 'mass'); c_mass = idx
      case ('r_cm', 'radius_cm', 'r'); c_radius = idx
      case ('mixing_type', 'mix_type', 'mixing'); c_mix = idx
      case ('eps_net_erg_g_s', 'eps_nuc', 'eps_net', 'eps'); c_eps = idx
      end select
   end subroutine assign_kipp_col

   pure function has_suffix(s, suf) result(yes)
      !! Test whether `s` ends with `suf`.
      ! Arguments
      character(len=*), intent(in) :: s
         !! String to test.
      character(len=*), intent(in) :: suf
         !! Suffix.
      logical :: yes
      integer(int32) :: ls, lf
      ls = len_trim(s); lf = len_trim(suf)
      yes = (ls >= lf)
      if (yes) yes = (s(ls - lf + 1:ls) == suf)
   end function has_suffix

   subroutine read_profile(dirname, pnum, cnv, fld_col, nf, rf)
      !! Parse `profile<pnum>.data` into one record.
      !!
      !! Header needs `model_number`, `num_zones`, `star_age`, `star_mass`; body needs `mass`,
      !! `logR`, `mixing_type`, `eps_nuc` (drives `nuc` layer) and `eps_nuc_neu_total` (drives `neu`
      !! layer). Raw colour-field columns go into `rf`, centre to surface, for caller to bin.
      ! Arguments
      character(len=*), intent(in) :: dirname
         !! Path of MESA run directory.
      integer(int32), intent(in) :: pnum
         !! Profile number.
      integer(int32), intent(in) :: nf
         !! Number of registered fields.
      integer(int32), intent(in) :: fld_col(:)
         !! Body column of each registered field.
      type(convtype), intent(out) :: cnv
         !! Record to build.
      type(rawset), intent(out) :: rf
         !! Colour-field values of profile.

      integer(int32) :: iunit, iostat, r, src, nz, k, f
      integer(int32) :: maxh, maxb
      integer(int32) :: c_model, c_age, c_mass_h, c_nz
      integer(int32) :: c_mass, c_logr, c_mix, c_eps, c_neu
      character(len=256) :: fname
      character(len=8192) :: hnames, bnames, hvals
      real(real64), allocatable :: hv(:), row(:)
      real(real64), allocatable :: massf(:), logrf(:), epsf(:), enuf(:)
      real(real64), allocatable :: fldf(:, :)
      integer(int32), allocatable :: mtf(:)
      real(real64), allocatable :: xm(:), rn(:), eps(:), enu(:)
      integer(int32), allocatable :: mt(:)

      fname = trim(dirname)//'/profile'//trim(itoa(pnum))//'.data'
      open (NEWUNIT=iunit, FILE=trim(fname), STATUS='OLD', &
            ACTION='READ', IOSTAT=iostat)
      if (iostat /= 0) &
         error stop '[read_profile] cannot open '//trim(fname)

      ! header block: skip col-index line, read names + values
      read (iunit, '(a)') hnames        ! line 1 (col indices), reused as scratch
      read (iunit, '(a)') hnames        ! line 2 header names
      read (iunit, '(a)') hvals         ! line 3 header values
      read (iunit, '(a)') bnames        ! line 4 blank, reused as scratch
      read (iunit, '(a)') bnames        ! line 5 body col indices, reused
      read (iunit, '(a)') bnames        ! line 6 body names

      c_model = col_index(hnames, 'model_number')
      c_nz = col_index(hnames, 'num_zones')
      c_age = col_index(hnames, 'star_age')
      c_mass_h = col_index(hnames, 'star_mass')
      if (min(c_model, c_nz, c_age, c_mass_h) < 1) &
         error stop '[read_profile] missing header column'

      c_mass = col_index(bnames, 'mass')
      c_logr = col_index(bnames, 'logR')
      c_mix = col_index(bnames, 'mixing_type')
      c_eps = col_index(bnames, 'eps_nuc')
      c_neu = col_index(bnames, 'eps_nuc_neu_total')
      if (min(c_mass, c_logr, c_mix, c_eps, c_neu) < 1) &
         error stop '[read_profile] missing body column'

      ! read only up to the highest needed column; the header value line has
      ! trailing string columns (version, compiler) a numeric read would choke
      ! on, but they sit past every field we want
      maxh = max(c_model, c_nz, c_age, c_mass_h)
      allocate (hv(maxh))
      read (hvals, *) hv(1:maxh)

      nz = nint(hv(c_nz))
      cnv%ncyc = nint(hv(c_model))
      cnv%timesec = hv(c_age)*YR

      ! body rows run surface -> center; read them then reverse to the
      ! center -> surface ascending order the renderer expects
      maxb = max(c_mass, c_logr, c_mix, c_eps, c_neu)
      do f = 1, nf
         maxb = max(maxb, fld_col(f))
      end do
      allocate (row(maxb))
      allocate (massf(nz), logrf(nz), mtf(nz), epsf(nz), enuf(nz))
      allocate (fldf(nz, nf))
      do r = 1, nz
         read (iunit, *, IOSTAT=iostat) row(1:maxb)
         if (iostat /= 0) &
            error stop '[read_profile] short profile body'
         massf(r) = row(c_mass)
         logrf(r) = row(c_logr)
         mtf(r) = nint(row(c_mix))
         epsf(r) = row(c_eps)
         enuf(r) = row(c_neu)
         do f = 1, nf
            fldf(r, f) = row(fld_col(f))
         end do
      end do
      close (iunit)

      allocate (xm(nz), rn(nz), mt(nz), eps(nz), enu(nz))
      allocate (rf%v(nz, nf))
      do k = 1, nz
         src = nz - k + 1
         xm(k) = massf(src)*SOLMASS
         rn(k) = 10.d0**logrf(src)*SOLRAD
         mt(k) = mtf(src)
         eps(k) = epsf(src)
         enu(k) = enuf(src)
         do f = 1, nf
            rf%v(k, f) = fldf(src, f)
         end do
      end do
      deallocate (massf, logrf, mtf, epsf, enuf, hv, row, fldf)

      cnv%nvers = REC_NVERS
      cnv%ncoord = nz
      cnv%dt = 0.d0
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

      call build_mesa_zones(mt, nz, cnv)
      call build_energy(eps, nz, cnv%nnuc, cnv%nuc, cnv%inuc)
      call build_energy(enu, nz, cnv%nneu, cnv%neu, cnv%ineu)

      ! layer minima drive the colorbar labels (kipp level_mins): layer 0 nuc
      ! uses minloss as the gain-min log value / mingain as the loss-min;
      ! layer 2 neu uses minneul / minneug
      cnv%minloss = EPS_BASE
      cnv%mingain = EPS_BASE
      cnv%minnucl = EPS_BASE
      cnv%minnucg = EPS_BASE
      cnv%minneul = EPS_BASE
      cnv%minneug = EPS_BASE
      cnv%minlossd = 0; cnv%mingaind = 0
      cnv%minnucld = 0; cnv%minnucgd = 0
      cnv%minneuld = 0; cnv%minneugd = 0

      ! layer 1 (nuk) and all derivative / advection arrays stay empty
      call alloc_empty_layers(cnv)

      deallocate (xm, rn, mt, eps, enu)
   end subroutine read_profile

   subroutine build_mesa_zones(mt, nz, cnv)
      !! Build convection zones of record from MESA mixing codes, mapped by `type_char`.
      ! Arguments
      integer(int32), intent(in) :: mt(:)
         !! MESA mixing code of each cell, centre to surface.
      integer(int32), intent(in) :: nz
         !! Number of cells.
      type(convtype), intent(inout) :: cnv
         !! Record receiving zones.
      integer(int32) :: k
      character(len=1), allocatable :: zones(:)

      allocate (zones(nz))
      do k = 1, nz
         zones(k) = type_char(mt(k))
      end do
      call build_zones(zones, nz, cnv)
      deallocate (zones)
   end subroutine build_mesa_zones

   pure function type_char(m) result(c)
      !! Return `ZONE_CHAR` type of MESA mixing code ("Required columns", docs/kippfiles.md).
      !!
      !! Unknown codes fall back to neutral.
      ! Arguments
      integer(int32), intent(in) :: m
         !! MESA mixing code.
      character(len=1) :: c
      select case (m)
      case (MESA_NO_MIXING); c = ZONE_CHAR(RADIATIVE)
      case (MESA_CONVECTIVE_MIXING); c = ZONE_CHAR(CONVECTIVE)
      case (MESA_OVERSHOOT_MIXING); c = ZONE_CHAR(OVERSHOOT)
      case (MESA_SEMICONVECTIVE_MIXING); c = ZONE_CHAR(SEMICONV)
      case (MESA_THERMOHALINE_MIXING); c = ZONE_CHAR(THERMOHALINE)
      case (MESA_ROTATION_MIXING); c = ZONE_CHAR(NEUTRAL)
      case (MESA_LEFTOVER_CONVECTIVE_MIXING); c = ZONE_CHAR(CONVECTIVE)
      case default; c = ZONE_CHAR(NEUTRAL)
      end select
   end function type_char

   pure function col_index(line, name) result(idx)
      !! Return 1-based position of whitespace-separated token equal to `name`, or -1.
      ! Arguments
      character(len=*), intent(in) :: line
         !! Line of column names.
      character(len=*), intent(in) :: name
         !! Column name to find.
      integer(int32) :: idx, col, i, s, L
      idx = -1
      col = 0
      i = 1
      L = len_trim(line)
      do
         do while (i <= L)
            if (line(i:i) /= ' ' .and. line(i:i) /= char(9)) exit
            i = i + 1
         end do
         if (i > L) exit
         s = i
         do while (i <= L)
            if (line(i:i) == ' ' .or. line(i:i) == char(9)) exit
            i = i + 1
         end do
         col = col + 1
         if (line(s:i - 1) == trim(name)) then
            idx = col
            return
         end if
      end do
   end function col_index

   function itoa(n) result(s)
      !! Return left-justified decimal string of non-negative integer.
      ! Arguments
      integer(int32), intent(in) :: n
         !! Integer to write.
      character(len=12) :: s
      write (s, '(i0)') n
   end function itoa

end module mesaload
