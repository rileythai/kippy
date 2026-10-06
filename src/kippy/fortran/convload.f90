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

module convload

  use typedef, only: &
       int32, real64

  implicit none

  character(len=*), parameter :: &
       convert = 'big_endian'

  integer(kind=int32), parameter :: &
       cnv_start = 1024
  real(kind=real64), parameter :: &
       cnv_fac = 0.5d0 * (sqrt(5.d0) + 1.d0)

contains

  subroutine loadconv(namecnv, ifirst, ilast)

    use convdata, only: &
         convtype, data

    implicit none

    character(len=*), intent(in):: &
         namecnv
    integer(kind=int32), intent(IN) :: &
         ifirst, ilast

    integer(kind=int32):: &
         iunit, n, i, &
         nvers, nmodel, &
         iostat
    type(convtype) :: &
         cnv
    type(convtype), dimension(:), allocatable :: &
         data1

    if (allocated(data)) &
         deallocate(data)
    n = cnv_start
    allocate(data(n))

    open(NEWUNIT=iunit, &
         FILE=namecnv, &
         STATUS='OLD', &
         POSITION='REWIND', &
         FORM='UNFORMATTED', &
         CONVERT=convert)

    ! call fseek(UNIT=iunit, OFFSET=ifirst, WHENCE=0)

    do while (.True.)
       READ(iunit,IOSTAT=iostat) nvers, nmodel
       if (IS_IOSTAT_END(iostat)) &
           exit
       if (iostat /= 0) &
            error stop '[loadconv] Error finding record'
       if (nmodel >= ifirst) then
            backspace(iunit)
            exit
         endif
    enddo

    do i = 1, 2**30
       cnv = loadconv_record(iunit)
       if (cnv%nvers == 0) &
          exit
       if (cnv%ncyc > ilast) &
          exit
       if (i > n) then
          n = int(n * cnv_fac)
          allocate(data1(n))
          data1(1:i-1) = data(1:i-1)
          deallocate(data)
          call move_alloc(data1, data)
       endif
       data(i) = cnv
    enddo
    close(UNIT=iunit, STATUS='keep')

    n = i-1
    allocate(data1(n))
    data1(1:n) = data(1:n)
    deallocate(data)
    call move_alloc(data1, data)

    call sort_models()
    n = int(size(data), int32)

    print*, '[loadconv] Loaded models', data(1)%ncyc, ' - ', data(n)%ncyc

  end subroutine loadconv


  ! kepler appends records when a run is restarted from an earlier dump,
  ! so a file can contain overlapping model ranges (model number and time
  ! jump backwards mid-file).  keep only the last record per model number,
  ! in ascending model order.  downstream consumers (band tracing, strip
  ! edges, bisection) rely on the record sequence increasing strictly.
  subroutine sort_models()

    use convdata, only: &
         convtype, data

    implicit none

    type(convtype), dimension(:), allocatable :: &
         data1
    integer(kind=int32), dimension(:), allocatable :: &
         idx, tmp
    integer(kind=int32) :: &
         n, i, k, m, w, l, r, la, lb

    n = int(size(data), int32)
    if (n <= 1) return

    ! fast path: model numbers already strictly increasing
    do i = 2, n
       if (data(i)%ncyc <= data(i-1)%ncyc) exit
    enddo
    if (i > n) return

    ! stable bottom-up merge sort of record indices by model number, so
    ! records sharing a ncyc stay in file order and the last one wins
    allocate(idx(n), tmp(n))
    do i = 1, n
       idx(i) = i
    enddo
    w = 1
    do while (w < n)
       do l = 1, n - w, 2 * w
          m = l + w - 1
          r = min(l + 2 * w - 1, n)
          tmp(l:r) = idx(l:r)
          la = l
          lb = m + 1
          do k = l, r
             if (lb > r) then
                idx(k) = tmp(la); la = la + 1
             else if (la > m) then
                idx(k) = tmp(lb); lb = lb + 1
             else if (data(tmp(lb))%ncyc < data(tmp(la))%ncyc) then
                idx(k) = tmp(lb); lb = lb + 1
             else
                idx(k) = tmp(la); la = la + 1
             endif
          enddo
       enddo
       w = 2 * w
    enddo

    ! keep the last record of each run of equal model numbers
    m = 0
    do i = 1, n
       if (i < n) then
          if (data(idx(i))%ncyc == data(idx(i+1))%ncyc) cycle
       endif
       m = m + 1
       idx(m) = idx(i)
    enddo

    if (m < n) &
         print*, '[loadconv] Removed', n - m, &
         'superseded model(s) (restart overlap)'

    allocate(data1(m))
    do i = 1, m
       data1(i) = data(idx(i))
    enddo
    deallocate(data)
    call move_alloc(data1, data)
    deallocate(idx, tmp)

  end subroutine sort_models


  ! Peek the record version and dispatch to the matching decoder.
  ! Supported layouts:
  !   * versions 10600-10699 share one record layout (aw/anglt 3-vectors,
  !     ladv read after rncoord, no toffset)
  !   * version 10700+ adds toffset (after dt) and moves ladv into the early
  !     header (after ncoord, before idx_kind_len/nuc_kind_len)
  ! Versions < 10600 are not supported (no fixtures).
  function loadconv_record(iunit) result(cnv)

    use typedef, only: &
         int32

    use convdata, only: &
         convtype

    integer(kind=int32), intent(IN) :: &
         iunit

    type(convtype) :: &
         cnv

    integer(kind=int32) :: &
         nvers, ncyc, iostat

    read(iunit, IOSTAT=iostat) nvers, ncyc
    if (IS_IOSTAT_END(iostat)) then
       cnv%nvers = 0
       return
    endif
    if (iostat /= 0) &
         error stop '[loadconv_record] Error reading record header'
    backspace(iunit)

    if (nvers >= 10700) then
       cnv = loadconv_10700(iunit)
    else if (nvers >= 10600) then
       cnv = loadconv_10600(iunit)
    else
       print*, '[loadconv_record] unsupported record version', nvers
       error stop '[loadconv_record] record version < 10600 not supported'
    endif

  end function loadconv_record


  function loadconv_10600(iunit) result(cnv)

    use typedef, only: &
         int32

    use convdata, only: &
         convtype, &
         nuc_kind_len, idx_kind_len

    integer(kind=int32), intent(IN):: &
         iunit

    type(convtype) :: &
         cnv

    integer(kind=int32) :: &
         iostat

    read(iunit, IOSTAT=iostat) &
         cnv%nvers, &
         cnv%ncyc,&
         cnv%timesec, &
         cnv%dt, &
         cnv%nconv, &
         cnv%nnuc, &
         cnv%nnuk, &
         cnv%nneu, &
         cnv%nnucd, &
         cnv%nnukd, &
         cnv%nneud, &
         cnv%ncoord, &
         cnv%idx_kind_len, &
         cnv%nuc_kind_len

    if (cnv%nvers < 10600 .or. cnv%nvers >= 10700) &
         error stop '[loadconv_10600] version out of range (expects 10600-10699)'
    if (cnv%idx_kind_len /= idx_kind_len) error stop 'idx_kind_len mismatch'
    if (cnv%nuc_kind_len /= nuc_kind_len) error stop 'nuc_kind_len mismatch'

    if (IS_IOSTAT_END(iostat)) then
       cnv%nvers = 0
       return
    endif

    allocate(&
         cnv%nuc(cnv%nnuc), &
         cnv%nuk(cnv%nnuk), &
         cnv%neu(cnv%nneu), &
         cnv%nucd(cnv%nnucd), &
         cnv%nukd(cnv%nnukd), &
         cnv%neud(cnv%nneud), &
         cnv%yzip(cnv%nconv), &
         cnv%xmcoord(cnv%ncoord), &
         cnv%rncoord(cnv%ncoord), &
         cnv%inuc(cnv%nnuc), &
         cnv%inuk(cnv%nnuk), &
         cnv%ineu(cnv%nneu), &
         cnv%inucd(cnv%nnucd), &
         cnv%inukd(cnv%nnukd), &
         cnv%ineud(cnv%nneud), &
         cnv%iconv(cnv%nconv))

    backspace(iunit)

    read(iunit) &
         cnv%nvers, &
         cnv%ncyc,&
         cnv%timesec, &
         cnv%dt, &
         cnv%nconv, &
         cnv%nnuc, &
         cnv%nnuk, &
         cnv%nneu, &
         cnv%nnucd, &
         cnv%nnukd, &
         cnv%nneud, &
         cnv%ncoord, &
         cnv%idx_kind_len, &
         cnv%nuc_kind_len, &
         cnv%nuc, &
         cnv%nuk, &
         cnv%neu, &
         cnv%nucd, &
         cnv%nukd, &
         cnv%neud, &
         cnv%yzip, &
         cnv%xmcoord, &
         cnv%rncoord, &
         cnv%ladv

    cnv%nadv = popcnt(cnv%ladv)

    backspace(iunit)

    allocate(&
         cnv%iadv(cnv%nadv), &
         cnv%dmadv(cnv%nadv), &
         cnv%dvadv(cnv%nadv))

    read(iunit) &
         cnv%nvers, &
         cnv%ncyc,&
         cnv%timesec, &
         cnv%dt, &
         cnv%nconv, &
         cnv%nnuc, &
         cnv%nnuk, &
         cnv%nneu, &
         cnv%nnucd, &
         cnv%nnukd, &
         cnv%nneud, &
         cnv%ncoord, &
         cnv%idx_kind_len, &
         cnv%nuc_kind_len, &
         cnv%nuc, &
         cnv%nuk, &
         cnv%neu, &
         cnv%nucd, &
         cnv%nukd, &
         cnv%neud, &
         cnv%yzip, &
         cnv%xmcoord, &
         cnv%rncoord, &
         cnv%ladv, &
         cnv%iadv, &
         cnv%dmadv, &
         cnv%dvadv, &
         cnv%inuc, &
         cnv%inuk, &
         cnv%ineu, &
         cnv%inucd, &
         cnv%inukd, &
         cnv%ineud, &
         cnv%iconv, &
         cnv%levcnv, &
         cnv%minloss, &
         cnv%mingain, &
         cnv%minnucl, &
         cnv%minnucg, &
         cnv%minneul, &
         cnv%minneug, &
         cnv%minlossd, &
         cnv%mingaind, &
         cnv%minnucld, &
         cnv%minnucgd, &
         cnv%minneuld, &
         cnv%minneugd, &
         cnv%tc, &
         cnv%dc, &
         cnv%pc, &
         cnv%ec, &
         cnv%sc, &
         cnv%ye, &
         cnv%ab, &
         cnv%et, &
         cnv%sn, &
         cnv%su, &
         cnv%g1, &
         cnv%g2, &
         cnv%s1, &
         cnv%s2, &
         cnv%aw, &
         cnv%summ0, &
         cnv%radius0, &
         cnv%an, &
         cnv%abun, &
         cnv%eni    , &
         cnv%enk    , &
         cnv%enp    , &
         cnv%ent    , &
         cnv%epro   , &
         cnv%enn    , &
         cnv%enr    , &
         cnv%ensc   , &
         cnv%enes   , &
         cnv%enc    , &
         cnv%enpist , &
         cnv%enid   , &
         cnv%enkd   , &
         cnv%enpd   , &
         cnv%entd   , &
         cnv%eprod  , &
         cnv%xlumn  , &
         cnv%enrd   , &
         cnv%enscd  , &
         cnv%enesd  , &
         cnv%encd   , &
         cnv%enpistd, &
         cnv%xlum   , &
         cnv%xlum0  , &
         cnv%entloss, &
         cnv%eniloss, &
         cnv%enkloss, &
         cnv%enploss, &
         cnv%enrloss, &
         cnv%angit  , &
         cnv%angltv , &
         cnv%xmacc

    return

  end function loadconv_10600


  function loadconv_10700(iunit) result(cnv)

    use typedef, only: &
         int32

    use convdata, only: &
         convtype, &
         nuc_kind_len, idx_kind_len

    integer(kind=int32), intent(IN):: &
         iunit

    type(convtype) :: &
         cnv

    integer(kind=int32) :: &
         iostat

    ! Stage 1: read the leading header to learn every array size.  For
    ! version 10700 the header carries toffset (right after dt) and ladv
    ! (right after ncoord), so nadv = popcnt(ladv) is known here as well and
    ! the advection arrays can be allocated in a single pass (no second
    ! size-probe read is needed, unlike loadconv_10600).
    read(iunit, IOSTAT=iostat) &
         cnv%nvers, &
         cnv%ncyc, &
         cnv%timesec, &
         cnv%dt, &
         cnv%toffset, &
         cnv%nconv, &
         cnv%nnuc, &
         cnv%nnuk, &
         cnv%nneu, &
         cnv%nnucd, &
         cnv%nnukd, &
         cnv%nneud, &
         cnv%ncoord, &
         cnv%ladv, &
         cnv%idx_kind_len, &
         cnv%nuc_kind_len

    if (IS_IOSTAT_END(iostat)) then
       cnv%nvers = 0
       return
    endif

    if (cnv%nvers < 10700) &
         error stop '[loadconv_10700] version out of range (expects >= 10700)'
    if (cnv%idx_kind_len /= idx_kind_len) error stop 'idx_kind_len mismatch'
    if (cnv%nuc_kind_len /= nuc_kind_len) error stop 'nuc_kind_len mismatch'

    cnv%nadv = popcnt(cnv%ladv)

    allocate( &
         cnv%nuc(cnv%nnuc), &
         cnv%nuk(cnv%nnuk), &
         cnv%neu(cnv%nneu), &
         cnv%nucd(cnv%nnucd), &
         cnv%nukd(cnv%nnukd), &
         cnv%neud(cnv%nneud), &
         cnv%yzip(cnv%nconv), &
         cnv%xmcoord(cnv%ncoord), &
         cnv%rncoord(cnv%ncoord), &
         cnv%inuc(cnv%nnuc), &
         cnv%inuk(cnv%nnuk), &
         cnv%ineu(cnv%nneu), &
         cnv%inucd(cnv%nnucd), &
         cnv%inukd(cnv%nnukd), &
         cnv%ineud(cnv%nneud), &
         cnv%iconv(cnv%nconv), &
         cnv%iadv(cnv%nadv), &
         cnv%dmadv(cnv%nadv), &
         cnv%dvadv(cnv%nadv))

    backspace(iunit)

    ! Stage 2: full record read in version-10700 field order.  Differs from
    ! 10600 only by toffset (after dt) and ladv read in the early header
    ! (after ncoord) instead of after rncoord.
    read(iunit) &
         cnv%nvers, &
         cnv%ncyc, &
         cnv%timesec, &
         cnv%dt, &
         cnv%toffset, &
         cnv%nconv, &
         cnv%nnuc, &
         cnv%nnuk, &
         cnv%nneu, &
         cnv%nnucd, &
         cnv%nnukd, &
         cnv%nneud, &
         cnv%ncoord, &
         cnv%ladv, &
         cnv%idx_kind_len, &
         cnv%nuc_kind_len, &
         cnv%nuc, &
         cnv%nuk, &
         cnv%neu, &
         cnv%nucd, &
         cnv%nukd, &
         cnv%neud, &
         cnv%yzip, &
         cnv%xmcoord, &
         cnv%rncoord, &
         cnv%iadv, &
         cnv%dmadv, &
         cnv%dvadv, &
         cnv%inuc, &
         cnv%inuk, &
         cnv%ineu, &
         cnv%inucd, &
         cnv%inukd, &
         cnv%ineud, &
         cnv%iconv, &
         cnv%levcnv, &
         cnv%minloss, &
         cnv%mingain, &
         cnv%minnucl, &
         cnv%minnucg, &
         cnv%minneul, &
         cnv%minneug, &
         cnv%minlossd, &
         cnv%mingaind, &
         cnv%minnucld, &
         cnv%minnucgd, &
         cnv%minneuld, &
         cnv%minneugd, &
         cnv%tc, &
         cnv%dc, &
         cnv%pc, &
         cnv%ec, &
         cnv%sc, &
         cnv%ye, &
         cnv%ab, &
         cnv%et, &
         cnv%sn, &
         cnv%su, &
         cnv%g1, &
         cnv%g2, &
         cnv%s1, &
         cnv%s2, &
         cnv%aw, &
         cnv%summ0, &
         cnv%radius0, &
         cnv%an, &
         cnv%abun, &
         cnv%eni    , &
         cnv%enk    , &
         cnv%enp    , &
         cnv%ent    , &
         cnv%epro   , &
         cnv%enn    , &
         cnv%enr    , &
         cnv%ensc   , &
         cnv%enes   , &
         cnv%enc    , &
         cnv%enpist , &
         cnv%enid   , &
         cnv%enkd   , &
         cnv%enpd   , &
         cnv%entd   , &
         cnv%eprod  , &
         cnv%xlumn  , &
         cnv%enrd   , &
         cnv%enscd  , &
         cnv%enesd  , &
         cnv%encd   , &
         cnv%enpistd, &
         cnv%xlum   , &
         cnv%xlum0  , &
         cnv%entloss, &
         cnv%eniloss, &
         cnv%enkloss, &
         cnv%enploss, &
         cnv%enrloss, &
         cnv%angit  , &
         cnv%angltv , &
         cnv%xmacc

    return

  end function loadconv_10700

end module convload
