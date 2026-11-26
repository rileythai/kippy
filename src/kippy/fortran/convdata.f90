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

! convdata.f90 -- model records shared by the readers and the renderer
module convdata
  !! Model records shared by readers and renderer.
  !!
  !! One record per model in `.cnv` layout (docs/cnvfiles.md), whatever input format; convection
  !! types are codes `RADIATIVE` to `THERMOHALINE`, which renderer indexes by. Colour-field registry
  !! (`nfields`, `field_` arrays) shared by all records: readers fill it once, renderer resolves
  !! `color <name>` against `field_names` and reads each record's matching `fld` layer.

  use typedef, only: &
       real64, int32, int16, int8

  implicit none

  integer(kind=int32), parameter :: &
       nvers=10600
       !! Record version 10600, not used by kippy.
  integer(kind=int32), parameter :: &
       nadvz=4
       !! Not used by kippy.
  integer(kind=int32), parameter :: &
       nangjd = 3
       !! Length of the `aw` and `angltv` vectors.
  integer(kind=int32), parameter :: &
       nuc_kind_len=2
       !! Decimal digits of `nuc_kind`; every record must state this `nuc_kind_len`.
  integer(kind=int32), parameter :: &
       idx_kind_len=4
       !! Decimal digits of `idx_kind`; every record must state this `idx_kind_len`.
  integer(kind=int32), parameter :: &
       nhiz = 20
       !! Length of `abun`.
  integer(kind=int32), parameter :: &
       idx_kind = SELECTED_INT_KIND(idx_kind_len)
       !! Integer kind of grid indices, 16-bit.
  integer(kind=int32), parameter :: &
       nuc_kind = SELECTED_INT_KIND(nuc_kind_len)
       !! Integer kind of energy levels, 8-bit.

  integer(kind=int32), parameter :: &
       RADIATIVE = 0
       !! Radiative zone, not drawn.
  integer(kind=int32), parameter :: &
       NEUTRAL = 1
       !! Neutral zone.
  integer(kind=int32), parameter :: &
       OVERSHOOT = 2
       !! Overshoot zone.
  integer(kind=int32), parameter :: &
       SEMICONV = 3
       !! Semiconvective zone.
  integer(kind=int32), parameter :: &
       CONVECTIVE = 4
       !! Convective zone.
  integer(kind=int32), parameter :: &
       THERMOHALINE = 5
       !! Thermohaline zone.
  integer(kind=int32), parameter :: &
       NCONVTYPES = 5
       !! Number of drawn convection types, also highest type code.
  character(len=1), parameter :: &
       ZONE_CHAR(0:NCONVTYPES) = [' ', 'N', 'O', 'S', 'C', 'T']
       !! `yzip` character a `.cnv` file stores per convection type ("Convection zones",
       !! docs/cnvfiles.md).
       !!
       !! Any other character reads as radiative.

  type fieldlayer
     !! Column binned into contour levels.
     !!
     !! Run-length step function like `nuc` and `neu` energy layers: `lev(k)` is bin (1 to
     !! `FIELD_NBINS`) reached at coordinate index `idx(k)`. Drives colour fields, so any `.kipp` or
     !! MESA column can be plotted.
     integer(kind=int32) :: n = 0
        !! Number of entries.
     integer(kind=nuc_kind), dimension(:), allocatable :: lev
        !! Bin of each entry.
     integer(kind=idx_kind), dimension(:), allocatable :: idx
        !! Coordinate index where each entry starts.
  end type fieldlayer

  type convtype
     !! Model record in `.cnv` layout.
     !!
     !! Fields follow record table of docs/cnvfiles.md. kippy uses only `ncyc`, `timesec`,
     !! convection zones, coordinates, `nuc`, `nuk` and `neu` layers and first six level floors;
     !! profile readers also fill `fld`.
     integer(kind=int32) :: &
          nvers
          !! Record version.
     integer(kind=int32) :: &
          ncyc
          !! Model number.
     integer(kind=int32) :: &
          nconv
          !! Number of convection zones.
     integer(kind=int32) :: &
          nnuc, nnuk, nneu, nnucd, nnukd, nneud
          !! Number of entries in each energy layer.
     integer(kind=int32) :: &
          ncoord
          !! Number of grid points.
     integer(kind=int32) :: &
          idx_kind_len
          !! Decimal digits of grid indices, must be 4.
     integer(kind=int32) :: &
          nuc_kind_len
          !! Decimal digits of energy levels, must be 2.
     integer(kind=int32) :: &
          ladv
          !! Advection flags.
     integer(kind=int32) :: &
          nadv
          !! Number of bits set in `ladv`, length of advection arrays.
     integer(kind=int32) :: &
          levcnv
          !! Other term specific to KEPLER, not important.
     integer(kind=int32) :: &
          minloss, mingain, minnucl, minnucg, minneul, minneug
          !! Level floors, as consecutive (gain, loss) pairs of `nuc`, `nuk` and `neu` layers.
          !!
          !! Historical names do not match this meaning ("Energy layers", docs/cnvfiles.md).
     integer(kind=int32) :: &
          minlossd,mingaind,minnucld,minnucgd,minneuld,minneugd
          !! Level floors of derivative layers.

     integer(kind=int32) :: nfld = 0
        !! Number of colour-field layers, 0 for the KEPLER `.cnv` reader.
     type(fieldlayer), dimension(:, :), allocatable :: fld
        !! Colour-field layers.
        !!
        !! `fld(1, f)` binned in field `f`'s default scale, `fld(2, f)` in other.

     REAL(kind=real64), dimension(nangjd) :: &
         aw
         !! Central angular velocity vector (rad/s).
     REAL(kind=real64), dimension(nangjd) :: &
         angltv
         !! Total angular momentum vector.

     real(kind=real64) :: &
          timesec
          !! Age (s).
     real(kind=real64) :: &
          dt
          !! Time step (s).
     real(kind=real64) :: &
          toffset
          !! Record field `toffset`, in version 10700 and later only.
     real(kind=real64) :: &
          eni,enk,enp,ent,epro,enn,enr, &
          ensc,enes,enc,enpist,enid,enkd, &
          enpd,entd,eprod,xlumn,enrd,enscd, &
          enesd,encd,enpistd,xlum,xlum0, &
          entloss,eniloss,enkloss,enploss, &
          enrloss,angit
          !! Global energy totals and rates, luminosities, moment of inertia `angit`.
     real(kind=real64) :: &
          xmacc
          !! Other term specific to KEPLER, not important.
     real(kind=real64) :: &
          tc,dc,pc,ec,sc,ye,ab, &
          et,sn,su,g1,g2,s1,s2
          !! Central quantities.
          !!
          !! `convdump` prints `tc` and `dc`.
     real(kind=real64) :: &
          summ0,radius0,an
          !! Other terms specific to KEPLER, not important.
          !!
          !! `convdump` prints `summ0`, which is not added to the mass coordinate.

     real(kind=real64), dimension(nhiz) :: &
          abun
          !! Central composition (mass fractions).

     real(kind=real64), dimension(:), allocatable :: &
          xmcoord
          !! Mass coordinate of each grid point (g), centre to surface.
     real(kind=real64), dimension(:), allocatable :: &
          rncoord
          !! Radius coordinate of each grid point (cm), centre to surface.
     real(kind=real64), dimension(:), allocatable :: &
          dmadv, dvadv
          !! Advection arrays of length `nadv`, specific to KEPLER, not important.

     character(len=1), dimension(:), allocatable :: &
          yzip
          !! Type of each convection zone, a `ZONE_CHAR` character.

     ! these may be replaced by pointers in the future
     integer(KIND=nuc_kind), dimension(:), allocatable :: &
          nuc
          !! Levels of nuclear energy generation layer, drawn by `color epsnuc`.
     integer(KIND=nuc_kind), dimension(:), allocatable :: &
          nuk
          !! Levels of nuclear energy loss layer, drawn by `color nuk`.
     integer(KIND=nuc_kind), dimension(:), allocatable :: &
          neu
          !! Levels of neutrino layer, drawn by `color neu`.
     integer(KIND=nuc_kind), dimension(:), allocatable :: &
          nucd, nukd, neud
          !! Levels of derivative layers, read but not drawn.
     integer(KIND=idx_kind), dimension(:), allocatable :: &
          inuc,inuk,ineu
          !! Grid index where each level entry of `nuc`, `nuk` and `neu` starts.
     integer(KIND=idx_kind), dimension(:), allocatable :: &
          inucd,inukd,ineud
          !! Grid index where each level entry of derivative layers starts.
     integer(KIND=idx_kind), dimension(:), allocatable :: &
          iadv
          !! Advection grid indices, of length `nadv`.
     integer(KIND=idx_kind), dimension(:), allocatable :: &
          iconv
          !! Grid index of outer edge of each convection zone.

  end type convtype


  type(convtype), dimension(:), allocatable :: &
       data
       !! Loaded models, ascending model number.

  integer(kind=int32), parameter :: FIELD_NBINS = 24
     !! Number of contour bins of a colour field.
  integer(kind=int32) :: nfields = 0
     !! Number of registered colour fields.
  character(len=32), dimension(:), allocatable :: field_names
     !! Name of each field, matched by `color <name>`.
  character(len=32), dimension(:), allocatable :: field_units
     !! Unit the source states for each field, blank if none.
  real(kind=real64), dimension(:), allocatable :: field_vmin, field_vmax
     !! Range of each field over whole model sequence, its colorbar bounds.
  real(kind=real64), dimension(:), allocatable :: field_vpos
     !! Smallest positive value of each field, its log-scale floor.
  logical, dimension(:), allocatable :: field_log
     !! Default binning of each field, log when true.

  ! TODO - allow multiple convection files?

end module convdata
