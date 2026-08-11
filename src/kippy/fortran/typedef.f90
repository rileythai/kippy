module typedef

  implicit none

  integer, parameter :: int8 = selected_int_kind(2)
  integer, parameter :: int16 = selected_int_kind(4)
  integer, parameter :: int32 = selected_int_kind(8)
  integer, parameter :: int64 = selected_int_kind(16)
  integer, parameter :: real64 = selected_real_kind(15)

end module typedef
