module mesaload

   ! mesaload.f90
   !
   ! reads a MESA profiles directory into the convtype objects
   !
   ! MESA writes profileN.data text files plus a profiles.index that maps
   ! profile number -> model number.  profiles can be sampled sparsely in time;
   ! (because its ascii), so kippy renderer traces them into continuous polygons,
   ! so no renderer change is needed.
   !
   ! each profile becomes a convtype record of: model number / age, the
   ! mass+radius grid, convection zones from the mixing_type column, and the
   ! nuclear/neutrino energy overlay quantized from eps_nuc into the integer
   ! level representation kipp's draw_energy consumes.
   !
   ! a .kipp file is the same model sequence packed as one raw float64 stream
   ! (cells grouped by model, one row per zone); its column layout comes from a
   ! sidecar <file>.hdr.  loadkipp streams it into the same convtype records.
   !
   ! TODO: add the option to use EITHER eps_nuc or net_total_energy or wahterve the column is

   use typedef, only: &
      int32, int64, real64
   use convdata, only: &
      convtype, data, &
      nuc_kind, idx_kind, nuc_kind_len, idx_kind_len
   use convload, only: &
      loadconv, sort_models
!$ use omp_lib, only: omp_get_max_threads

   implicit none (type, external)
   private

   public :: loadmesa, load_convection

   ! physical constants
   ! TODO: move to separate module
   real(real64), parameter :: SOLMASS = 1.9892d33   ! g
   real(real64), parameter :: SOLRAD = 6.9599d10   ! cm
   real(real64), parameter :: YR = 31556952.d0  ! s

   ! log10(erg/g/s) value mapped to energy level 1; cells below this floor
   ! draw no energy band.  tunable -- higher hides weak burning.  the
   ! colorbar labels level k as EPS_BASE + k - 1 (see kipp level_mins).
   integer(int32), parameter :: EPS_BASE = 1

   ! record version sentinel; the renderer ignores nvers once in memory
   integer(int32), parameter :: MESA_NVERS = 10600

   ! growth factor for the record array (matches convload cnv_fac)
   real(real64), parameter :: GROW_FAC = 0.5d0*(sqrt(5.d0) + 1.d0)

   ! cap on the profile-read thread pool. profile parsing is memory-bandwidth
   ! bound: throughput will peak around 3-4 threads as the shared
   ! memory subsystem saturates,
   ! override at runtime with a lower OMP_NUM_THREADS
   integer(int32), parameter :: MESA_MAX_THREADS = 4

contains

   ! dispatch on the path: a .kipp file is a raw float64 cell stream, a
   ! directory holding profiles.index is a MESA run, anything else is a kepler
   ! .cnv file.  single entry point so any of the three works everywhere a
   ! .cnv path did.
   subroutine load_convection(path, ifirst, ilast)
      character(len=*), intent(in) :: path
      integer(int32), intent(in) :: ifirst, ilast
      logical :: is_mesa
      if (has_suffix(path, '.kipp')) then
         call loadkipp(path, ifirst, ilast)
         return
      end if
      inquire (file=trim(path)//'/profiles.index', exist=is_mesa)
      if (is_mesa) then
         call loadmesa(path, ifirst, ilast)
      else
         call loadconv(path, ifirst, ilast)
      end if
   end subroutine load_convection

   subroutine loadmesa(dirname, ifirst, ilast)
      character(len=*), intent(in) :: dirname
      integer(int32), intent(in) :: ifirst, ilast

      integer(int32) :: iunit, iostat, nidx, i, nkeep, m, prio, pf, nthreads
      integer(int32), allocatable :: mdl(:), prof(:)
      character(len=256) :: idxfile

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
      ! each profile parses into its own data(i) slot with no shared state, so
      ! read them concurrently. schedule(dynamic) balances the uneven per-file
      ! cost (profiles differ in zone count). read_profile uses NEWUNIT units
      ! and only local storage, so it is thread-safe as written
      nthreads = 1
!$    nthreads = max(1, min(omp_get_max_threads(), MESA_MAX_THREADS))
      !$omp parallel do default(shared) private(i) schedule(dynamic) &
      !$omp num_threads(nthreads)
      do i = 1, nkeep
         call read_profile(dirname, prof(i), data(i))
         data(i)%ncyc = mdl(i)     ! index mapping is authoritative
      end do
      !$omp end parallel do
      deallocate (mdl, prof)

      call sort_models()
      print *, '[loadmesa] Loaded models', data(1)%ncyc, ' - ', &
         data(size(data))%ncyc
   end subroutine loadmesa

   ! stream a raw .kipp cell dump into convtype records.  the file is one
   ! contiguous float64 array of ncols-wide cells, cells grouped by model and
   ! (within a model) running surface -> center; the column layout is read
   ! from the sidecar header.  cells are consumed in large chunks so the 2.7 GB
   ! class files never fully reside in memory: only the current model's zones
   ! plus the finished records are held.
   subroutine loadkipp(path, ifirst, ilast)
      character(len=*), intent(in) :: path
      integer(int32), intent(in) :: ifirst, ilast

      integer(int32), parameter :: CHUNK = 65536

      character(len=512) :: hdrfile
      integer(int32) :: ncols
      integer(int32) :: c_model, c_age, c_dt, c_mass, c_radius, c_mix, c_eps
      integer(int32) :: iunit, iostat, j, m, ndata, ncap, cur, nz, zcap
      integer(int64) :: fbytes, ncells, ndone, take
      real(real64) :: age, dtsec
      logical :: stopping
      real(real64), allocatable :: buf(:, :)
      real(real64), allocatable :: am(:), ar(:), ae(:)
      integer(int32), allocatable :: amt(:)
      type(convtype), allocatable :: recs(:)

      call find_kipp_header(path, hdrfile)
      call parse_kipp_header(hdrfile, ncols, c_model, c_age, c_dt, &
                             c_mass, c_radius, c_mix, c_eps)

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
      age = 0.d0; dtsec = 0.d0
      stopping = .false.

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
               call flush_kipp(recs, ndata, ncap, cur, nz, age, dtsec, &
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
            am(nz) = buf(c_mass, j)
            ar(nz) = buf(c_radius, j)
            amt(nz) = nint(buf(c_mix, j))
            ae(nz) = buf(c_eps, j)
            age = buf(c_age, j)
            if (c_dt > 0) dtsec = buf(c_dt, j)
         end do
      end do
      call flush_kipp(recs, ndata, ncap, cur, nz, age, dtsec, &
                      am, ar, amt, ae, ifirst, ilast)
      close (iunit)
      deallocate (buf, am, ar, ae, amt)

      if (ndata < 2) &
         error stop '[loadkipp] need at least 2 models in range'

      if (allocated(data)) deallocate (data)
      allocate (data(ndata))
      data(1:ndata) = recs(1:ndata)
      deallocate (recs)

      call sort_models()
      print *, '[loadkipp] Loaded models', data(1)%ncyc, ' - ', &
         data(size(data))%ncyc
   end subroutine loadkipp

   ! turn one model's accumulated zones (surface -> center as read) into a
   ! convtype record appended to recs, growing recs as needed.  a run out of
   ! [ifirst, ilast] or with no zones produces nothing.
   subroutine flush_kipp(recs, ndata, ncap, model, nz, age, dtsec, &
                         am, ar, amt, ae, ifirst, ilast)
      type(convtype), allocatable, intent(inout) :: recs(:)
      integer(int32), intent(inout) :: ndata, ncap
      integer(int32), intent(in) :: model, nz, ifirst, ilast
      real(real64), intent(in) :: age, dtsec
      real(real64), intent(in) :: am(:), ar(:), ae(:)
      integer(int32), intent(in) :: amt(:)
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

      call build_kipp_record(recs(ndata), model, nz, age, dtsec, xm, rn, mt, eps)
      deallocate (xm, rn, eps, mt)
   end subroutine flush_kipp

   ! fill a convtype from the center -> surface arrays of one .kipp model.
   ! mass/radius arrive in cgs already (g, cm), so no unit scaling; the eps
   ! column is net (nuclear - neutrino), driving the nuc layer with both signs
   ! while the neu layer stays empty.
   subroutine build_kipp_record(cnv, model, nz, age, dtsec, xm, rn, mt, eps)
      type(convtype), intent(out) :: cnv
      integer(int32), intent(in) :: model, nz
      real(real64), intent(in) :: age, dtsec
      real(real64), intent(in) :: xm(:), rn(:), eps(:)
      integer(int32), intent(in) :: mt(:)

      cnv%nvers = MESA_NVERS
      cnv%ncyc = model
      cnv%ncoord = nz
      cnv%timesec = age*YR
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

      call build_zones(mt, nz, cnv)
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

   ! double the per-model accumulation buffers, preserving their contents
   subroutine grow_accum(am, ar, ae, amt, zcap)
      real(real64), allocatable, intent(inout) :: am(:), ar(:), ae(:)
      integer(int32), allocatable, intent(inout) :: amt(:)
      integer(int32), intent(inout) :: zcap
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

   ! locate the sidecar header for a .kipp file: first <path>.hdr next to the
   ! data file, then <basename>.hdr in the current directory (skipped when the
   ! data file already lives there, so the same spot is not checked twice).
   subroutine find_kipp_header(path, hdrfile)
      character(len=*), intent(in) :: path
      character(len=*), intent(out) :: hdrfile
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

   ! read the sidecar header: an "ncols N" line, a dtype line, a "columns:"
   ! line, then one "<index> <name>" line per column.  returns ncols and the
   ! 1-based positions of the columns kippy needs (c_dt is 0 when absent).
   subroutine parse_kipp_header(hdrfile, ncols, c_model, c_age, c_dt, &
                                c_mass, c_radius, c_mix, c_eps)
      character(len=*), intent(in) :: hdrfile
      integer(int32), intent(out) :: ncols
      integer(int32), intent(out) :: c_model, c_age, c_dt, c_mass, &
                                     c_radius, c_mix, c_eps
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

   ! map a header column name (with a few aliases) to its slot; unknown names
   ! are ignored so extra columns in the stream are simply skipped.
   subroutine assign_kipp_col(name, idx, c_model, c_age, c_dt, &
                              c_mass, c_radius, c_mix, c_eps)
      character(len=*), intent(in) :: name
      integer(int32), intent(in) :: idx
      integer(int32), intent(inout) :: c_model, c_age, c_dt, c_mass, &
                                       c_radius, c_mix, c_eps
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

   ! true when s ends with suf
   pure function has_suffix(s, suf) result(yes)
      character(len=*), intent(in) :: s, suf
      logical :: yes
      integer(int32) :: ls, lf
      ls = len_trim(s); lf = len_trim(suf)
      yes = (ls >= lf)
      if (yes) yes = (s(ls - lf + 1:ls) == suf)
   end function has_suffix

   ! parse profile<pnum>.data into one convtype record.
   subroutine read_profile(dirname, pnum, cnv)
      character(len=*), intent(in) :: dirname
      integer(int32), intent(in) :: pnum
      type(convtype), intent(out) :: cnv

      integer(int32) :: iunit, iostat, r, src, nz, k
      integer(int32) :: maxh, maxb
      integer(int32) :: c_model, c_age, c_mass_h, c_nz
      integer(int32) :: c_mass, c_logr, c_mix, c_eps, c_neu
      character(len=256) :: fname
      character(len=8192) :: hnames, bnames, hvals
      real(real64), allocatable :: hv(:), row(:)
      real(real64), allocatable :: massf(:), logrf(:), epsf(:), enuf(:)
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
      allocate (row(maxb))
      allocate (massf(nz), logrf(nz), mtf(nz), epsf(nz), enuf(nz))
      do r = 1, nz
         read (iunit, *, IOSTAT=iostat) row(1:maxb)
         if (iostat /= 0) &
            error stop '[read_profile] short profile body'
         massf(r) = row(c_mass)
         logrf(r) = row(c_logr)
         mtf(r) = nint(row(c_mix))
         epsf(r) = row(c_eps)
         enuf(r) = row(c_neu)
      end do
      close (iunit)

      allocate (xm(nz), rn(nz), mt(nz), eps(nz), enu(nz))
      do k = 1, nz
         src = nz - k + 1
         xm(k) = massf(src)*SOLMASS
         rn(k) = 10.d0**logrf(src)*SOLRAD
         mt(k) = mtf(src)
         eps(k) = epsf(src)
         enu(k) = enuf(src)
      end do
      deallocate (massf, logrf, mtf, epsf, enuf, hv, row)

      cnv%nvers = MESA_NVERS
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

      call build_zones(mt, nz, cnv)
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

   ! run-length compress the mixing_type column (all cells, radiative runs
   ! included so zones tile the whole star) into yzip type chars + iconv outer
   ! boundary indices, exactly as the kepler reader presents them.
   subroutine build_zones(mt, nz, cnv)
      integer(int32), intent(in) :: mt(:), nz
      type(convtype), intent(inout) :: cnv
      integer(int32) :: k, nconv
      character(len=1), allocatable :: yz(:)
      integer(int32), allocatable :: ic(:)

      allocate (yz(nz), ic(nz))
      nconv = 0
      do k = 1, nz
         if (k == nz) then
            nconv = nconv + 1
            yz(nconv) = type_char(mt(k))
            ic(nconv) = k
         else if (mt(k) /= mt(k + 1)) then
            nconv = nconv + 1
            yz(nconv) = type_char(mt(k))
            ic(nconv) = k
         end if
      end do

      cnv%nconv = nconv
      allocate (cnv%yzip(nconv), cnv%iconv(nconv))
      cnv%yzip = yz(1:nconv)
      cnv%iconv = int(ic(1:nconv), idx_kind)
      deallocate (yz, ic)
   end subroutine build_zones

   ! quantize a per-cell energy field (erg/g/s, ascending center->surface)
   ! into the integer level step function kipp draw_energy consumes: a
   ! (level, coordinate-index) pair at every cell where the level changes.
   ! sign is +gain / -loss; cells below the EPS_BASE floor map to level 0.
   subroutine build_energy(f, nz, n, vals, idxs)
      real(real64), intent(in) :: f(:)
      integer(int32), intent(in) :: nz
      integer(int32), intent(out) :: n
      integer(nuc_kind), allocatable, intent(out) :: vals(:)
      integer(idx_kind), allocatable, intent(out) :: idxs(:)
      integer(int32) :: k, lev, prev
      integer(int32), allocatable :: lv(:), ix(:)

      allocate (lv(nz), ix(nz))
      n = 0
      prev = huge(1_int32)     ! forces a pair at the first cell
      do k = 1, nz
         lev = level_of(f(k))
         if (lev /= prev) then
            n = n + 1
            lv(n) = lev
            ix(n) = k
            prev = lev
         end if
      end do

      allocate (vals(n), idxs(n))
      if (n > 0) then
         vals = int(lv(1:n), nuc_kind)
         idxs = int(ix(1:n), idx_kind)
      end if
      deallocate (lv, ix)
   end subroutine build_energy

   ! signed integer contour level of an energy value: nint(log10|f|) shifted
   ! so EPS_BASE is level 1, negative for losses, 0 below the floor
   pure function level_of(f) result(lev)
      real(real64), intent(in) :: f
      integer(int32) :: lev
      real(real64) :: a
      a = abs(f)
      if (a <= 0.d0) then
         lev = 0
         return
      end if
      lev = nint(log10(a)) - EPS_BASE + 1
      if (lev < 1) then
         lev = 0
      else if (f < 0.d0) then
         lev = -lev
      end if
   end function level_of

   ! allocate the layer-1 and derivative / advection arrays at size zero so
   ! size() and unconditional loops in the renderer are safe
   subroutine alloc_empty_layers(cnv)
      type(convtype), intent(inout) :: cnv
      cnv%nnuk = 0; cnv%nnucd = 0; cnv%nnukd = 0; cnv%nneud = 0
      allocate (cnv%nuk(0), cnv%inuk(0))
      allocate (cnv%nucd(0), cnv%inucd(0))
      allocate (cnv%nukd(0), cnv%inukd(0))
      allocate (cnv%neud(0), cnv%ineud(0))
      allocate (cnv%iadv(0), cnv%dmadv(0), cnv%dvadv(0))
   end subroutine alloc_empty_layers

   ! MESA mixing_types (const_def.f90) -> kipp convection type char
   ! (kipp type_of): 0 none, 1 conv, 2 overshoot, 3 semiconv, 4 thermohaline,
   ! 5 rotation, 9 leftover_convective; unknown codes fall back to neutral
   pure function type_char(m) result(c)
      integer(int32), intent(in) :: m
      character(len=1) :: c
      select case (m)
      case (0); c = ' '
      case (1); c = 'C'
      case (2); c = 'O'
      case (3); c = 'S'
      case (4); c = 'T'
      case (5); c = 'N'
      case (9); c = 'C'
      case default; c = 'N'
      end select
   end function type_char

   ! 1-based position of the whitespace-separated token equal to name, or -1
   pure function col_index(line, name) result(idx)
      character(len=*), intent(in) :: line, name
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

   ! left-justified decimal string of a non-negative integer
   function itoa(n) result(s)
      integer(int32), intent(in) :: n
      character(len=12) :: s
      write (s, '(i0)') n
   end function itoa

end module mesaload
