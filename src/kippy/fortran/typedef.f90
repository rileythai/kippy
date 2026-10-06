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

module typedef

  implicit none

  integer, parameter :: int8 = selected_int_kind(2)
  integer, parameter :: int16 = selected_int_kind(4)
  integer, parameter :: int32 = selected_int_kind(8)
  integer, parameter :: int64 = selected_int_kind(16)
  integer, parameter :: real64 = selected_real_kind(15)

end module typedef
