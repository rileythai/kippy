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

! typedef.f90 -- integer and real kinds
module typedef
  !! Integer and real kinds used by every kippy module.
  !!
  !! Each kind is selected by its decimal range.

  implicit none

  integer, parameter :: int8 = selected_int_kind(2)
     !! 1-byte integer, at least 2 decimal digits.
  integer, parameter :: int16 = selected_int_kind(4)
     !! 2-byte integer, at least 4 decimal digits.
  integer, parameter :: int32 = selected_int_kind(8)
     !! 4-byte integer, at least 8 decimal digits.
  integer, parameter :: int64 = selected_int_kind(16)
     !! 8-byte integer, at least 16 decimal digits.
  integer, parameter :: real64 = selected_real_kind(15)
     !! Double-precision real, at least 15 significant digits.

end module typedef
