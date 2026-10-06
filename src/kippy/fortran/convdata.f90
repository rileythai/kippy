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

module convdata

  use typedef, only: &
       real64, int32, int16, int8

  implicit none

  integer(kind=int32), parameter :: &
       nvers=10600, &
       nadvz=4, &
       nangjd = 3, &
       nuc_kind_len=2, &
       idx_kind_len=4, &
       nhiz = 20, &
       idx_kind = SELECTED_INT_KIND(idx_kind_len), &
       nuc_kind = SELECTED_INT_KIND(nuc_kind_len)

  ! one arbitrary scalar column quantized into contour levels, stored the
  ! same run-length way as the nuc/neu energy layers: lev(k) is the bin
  ! (1..FIELD_NBINS) reached at coordinate index idx(k).  drives the generic
  ! colour field so any column in a .kipp/MESA source can be plotted.
  type fieldlayer
     integer(kind=int32) :: n = 0
     integer(kind=nuc_kind), dimension(:), allocatable :: lev
     integer(kind=idx_kind), dimension(:), allocatable :: idx
  end type fieldlayer

  type convtype
     integer(kind=int32) :: &
          nvers, ncyc, &
          nconv, &
          nnuc, nnuk, nneu, nnucd, nnukd, nneud, &
          ncoord, &
          idx_kind_len, &
          nuc_kind_len, &
          ladv, nadv, &
          levcnv, &
          minloss, mingain, minnucl, minnucg, minneul, minneug, &
          minlossd,mingaind,minnucld,minnucgd,minneuld,minneugd

     ! generic per-column colour fields (empty for the kepler .cnv reader)
     integer(kind=int32) :: nfld = 0
     type(fieldlayer), dimension(:), allocatable :: fld

     REAL(kind=real64), dimension(nangjd) :: &
         aw, angltv

     real(kind=real64) :: &
          timesec, dt, toffset, &
          eni,enk,enp,ent,epro,enn,enr, &
          ensc,enes,enc,enpist,enid,enkd, &
          enpd,entd,eprod,xlumn,enrd,enscd, &
          enesd,encd,enpistd,xlum,xlum0, &
          entloss,eniloss,enkloss,enploss, &
          enrloss,angit,xmacc, &
          tc,dc,pc,ec,sc,ye,ab, &
          et,sn,su,g1,g2,s1,s2, &
          summ0,radius0,an

     real(kind=real64), dimension(nhiz) :: &
          abun

     real(kind=real64), dimension(:), allocatable :: &
          xmcoord, rncoord, &
          dmadv, dvadv

     character(len=1), dimension(:), allocatable :: &
          yzip

     ! these may be replaced by pointers in the future
     integer(KIND=nuc_kind), dimension(:), allocatable :: &
          nuc, nuk, neu, &
          nucd, nukd, neud
     integer(KIND=idx_kind), dimension(:), allocatable :: &
          inuc,inuk,ineu, &
          inucd,inukd,ineud, &
          iadv, &
          iconv

  end type convtype


  type(convtype), dimension(:), allocatable :: &
       data

  ! generic colour-field registry, shared by every record in `data`.  the
  ! readers populate it once from the source header/body columns; the
  ! renderer resolves a `color <name>` against field_names and reads the
  ! matching fld() layer.  vmin/vmax bound the colorbar (min/max across the
  ! whole model sequence), field_log selects log vs linear binning.
  integer(kind=int32), parameter :: FIELD_NBINS = 24
  integer(kind=int32) :: nfields = 0
  character(len=32), dimension(:), allocatable :: field_names
  real(kind=real64), dimension(:), allocatable :: field_vmin, field_vmax
  logical, dimension(:), allocatable :: field_log

  ! TODO - allow multiple convection files?

end module convdata
