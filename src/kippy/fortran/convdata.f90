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

  ! TODO - allow multiple convection files?

end module convdata
